// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
@testable import ListViewKit

// T-16: DragBridge pasteboard transport (06 §6.1 v1, F-18) — one dragged row
// = one NSPasteboardItem with the Finder `.fileURL` type plus the JSON
// `VFSPath` panel payload; the readers rebuild both sides. Helpers use the
// `db` name-space (the test module compiles neighbouring files together).

/// Private pasteboard per test (no cross-test bleed on the general one).
private func dbPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("db-\(UUID().uuidString)"))
}

private func dbPath(dir: String = "Docs", name: String = "notes.md") -> VFSPath {
    VFSPath(
        root: VFSInstanceID(kind: .localDisk, specID: "unknown"),
        components: [dir, name],
        displayURL: URL(fileURLWithPath: "/Users/dmit/\(dir)/\(name)")
    )
}

@Test func dbEntryRoundTripKeepsURLAndPath() throws {
    let pasteboard = dbPasteboard()
    let path = dbPath()
    guard let item = DragBridge.entry(fileURL: path.displayURL, path: path) else {
        Issue.record("entry must exist")
        return
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    let urls = DragBridge.readURLs(pasteboard)
    #expect(urls.map(\.standardizedFileURL.path) == ["/Users/dmit/Docs/notes.md"])
    let paths = DragBridge.readPaths(pasteboard)
    #expect(paths == [path])
}

@Test func dbEntryAcceptsURLlessPanelPayload() throws {
    let pasteboard = dbPasteboard()
    let path = dbPath(name: "virtual.txt")
    guard let item = DragBridge.entry(fileURL: nil, path: path) else {
        Issue.record("payload-only entry must exist")
        return
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    // No Finder URL — the planners still see the panel item.
    #expect(DragBridge.readURLs(pasteboard).isEmpty)
    #expect(DragBridge.readPaths(pasteboard) == [path])
}

@Test func dbEntryRejectsEmptyContent() {
    #expect(DragBridge.entry(fileURL: nil, path: nil) == nil)
}

@Test func dbPathsReaderSkipsForeignItems() throws {
    let pasteboard = dbPasteboard()
    let good = dbPath(name: "good.txt")
    guard let panelItem = DragBridge.entry(fileURL: nil, path: good) else {
        Issue.record("panel item must exist")
        return
    }
    // A foreign pasteboard item (plain string) — no payload → skipped, not a
    // decode crash.
    let junkItem = NSPasteboardItem()
    junkItem.setString("just a note", forType: .string)
    pasteboard.clearContents()
    pasteboard.writeObjects([junkItem, panelItem])

    #expect(DragBridge.readPaths(pasteboard) == [good])
}

@Test func dbMultiRowDragCarriesEveryPath() throws {
    let pasteboard = dbPasteboard()
    let first = dbPath(dir: "Docs", name: "a.txt")
    let second = dbPath(dir: "Docs", name: "b c.txt")
    guard let firstItem = DragBridge.entry(fileURL: first.displayURL, path: first),
          let secondItem = DragBridge.entry(fileURL: second.displayURL, path: second)
    else {
        Issue.record("items must exist")
        return
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([firstItem, secondItem])

    // Two dragged rows = two items (Finder copies both, planner moves both).
    #expect(DragBridge.readURLs(pasteboard).count == 2)
    #expect(DragBridge.readPaths(pasteboard) == [first, second])
}

@MainActor
@Test func dbAcceptedTypesRegisteredOnView() {
    let path = dbPath()
    guard let item = DragBridge.entry(fileURL: path.displayURL, path: path) else {
        Issue.record("entry must exist")
        return
    }
    let pasteboard = dbPasteboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    // The destination contract: a view registered for DragBridge.acceptedTypes
    // accepts both transport kinds of one bridge item.
    let registered = Set(DragBridge.acceptedTypes)
    let urlData = item.data(forType: .fileURL)
    let payloadData = item.data(forType: DragBridge.itemType)
    #expect(!urlData!.isEmpty)
    #expect(!payloadData!.isEmpty)
    #expect(registered.contains(.fileURL) && registered.contains(DragBridge.itemType))
}
