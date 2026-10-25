// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import ServicesKit

// T-26 acceptance (F-11, docs/SDD/12): the locations store — bookmark CRUD,
// 9 hotlist slots (one bookmark per slot), the recent-folders ring and the
// persistence contract (schemaVersion guard, atomic replace).

private func tempURL(_ label: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("locstore-\(label)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("locations.json")
}

private func samplePath(_ component: String) -> VFSPath {
    VFSPath.local(URL(fileURLWithPath: "/" + component, isDirectory: true))
}

@Suite("LocationsStore (F-11, T-26)")
struct LocationsStoreTests {

    @Test func bookmarkCrudRoundTrip() {
        let store = LocationsStore(storageURL: tempURL("crud"))
        let bookmark = store.addBookmark(name: "Projects", target: .path(samplePath("Users/me/Projects")))
        #expect(store.bookmarks().count == 1)
        #expect(store.bookmarks().first?.name == "Projects")

        store.remove(id: bookmark.id)
        #expect(store.bookmarks().isEmpty)
    }

    @Test func hotSlotsAreExclusiveAndClearable() {
        let store = LocationsStore(storageURL: tempURL("slots"))
        let a = store.addBookmark(name: "A", target: .path(samplePath("a")))
        let b = store.addBookmark(name: "B", target: .path(samplePath("b")))

        store.assignHotSlot(3, for: a.id)
        #expect(store.hotSlot(3)?.id == a.id)

        // Re-assigning the slot to another bookmark evicts the first one.
        store.assignHotSlot(3, for: b.id)
        #expect(store.hotSlot(3)?.id == b.id)
        #expect(store.bookmarks().first { $0.id == a.id }?.hotSlot == nil)

        store.clearHotSlot(3)
        #expect(store.hotSlot(3) == nil)
        #expect(store.bookmarks().count == 2)   // bookmarks survive slot clears

        // Out-of-range slots are ignored (contract: exactly 9 slots).
        store.assignHotSlot(10, for: a.id)
        store.assignHotSlot(0, for: a.id)
        #expect(a.hotSlot == nil)
    }

    @Test func recentFoldersDedupeMoveToFrontAndCap() {
        let store = LocationsStore(storageURL: tempURL("recents"))
        let alpha = samplePath("alpha")
        let beta = samplePath("beta")
        store.noteVisit(alpha)
        store.noteVisit(beta)
        store.noteVisit(alpha)
        let recents = store.recentFolders()
        #expect(recents.count == 2)
        #expect(recents.first == alpha)   // re-visit moves to front, no dupe

        for index in 0 ..< 25 {
            store.noteVisit(samplePath("deep-\(index)"))
        }
        #expect(store.recentFolders().count == 20)   // ring depth
        #expect(store.recentFolders().first?.components.last == "deep-24")
    }

    @Test func persistenceRoundTripAcrossInstances() {
        let url = tempURL("persist")
        let store = LocationsStore(storageURL: url)
        let bookmark = store.addBookmark(
            name: "Docs",
            target: .path(samplePath("docs")),
            panelHint: .left
        )
        store.assignHotSlot(7, for: bookmark.id)
        store.noteVisit(samplePath("visited"))

        let reloaded = LocationsStore(storageURL: url)
        #expect(reloaded.bookmarks().first?.name == "Docs")
        #expect(reloaded.bookmarks().first?.panelHint == .left)
        #expect(reloaded.hotSlot(7)?.id == bookmark.id)
        #expect(reloaded.recentFolders().first?.components.last == "visited")
    }

    @Test func foreignSchemaVersionIsIgnored() throws {
        let url = tempURL("schema")
        let store = LocationsStore(storageURL: url)
        store.addBookmark(name: "old", target: .path(samplePath("x")))
        #expect(store.bookmarks().count == 1)

        let raw = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        #expect(store.bookmarks().isEmpty)
        #expect(store.recentFolders().isEmpty)
    }

    @Test func missingFileStartsEmpty() {
        let store = LocationsStore(storageURL: tempURL("empty"))
        #expect(store.bookmarks().isEmpty)
        #expect(store.hotSlot(1) == nil)
        #expect(store.recentFolders().isEmpty)
    }
}
