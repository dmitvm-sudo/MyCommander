// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import ServicesKit

// T-08: SessionStore (docs/SDD/06 §6.9) — roundtrip through a temporary
// directory, graceful nil on corruption/version mismatch, atomic save, clear.

private func sessionTempURL(_ testName: String) -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MCSessionStoreTests-\(testName)-\(UUID().uuidString)", isDirectory: true)
    return directory.appendingPathComponent("session.json")
}

@Test func sessionRoundtripsThroughFile() {
    let url = sessionTempURL("roundtrip")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SessionStore(storageURL: url)

    let root = VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"))
    let alpha = VFSPath(root: root.root, components: ["alpha"])
    let file = VFSPath(root: root.root, components: ["alpha", "one.txt"])
    let snapshot = SessionSnapshot(
        left: PanelTabsSnapshot(
            tabs: [
                PanelTabsSnapshot.TabSnapshot(
                    path: alpha,
                    isLocked: true,
                    selection: [file],
                    historyBack: [root],
                    historyForward: []
                )
            ],
            activeIndex: 0
        ),
        right: PanelTabsSnapshot(tabs: [], activeIndex: 0)
    )

    store.save(snapshot)
    let restored = store.load()
    #expect(restored == snapshot)
}

@Test func loadReturnsNilWhenSessionIsMissing() {
    let store = SessionStore(storageURL: sessionTempURL("missing"))
    #expect(store.load() == nil)
}

@Test func loadReturnsNilOnCorruptedJSON() {
    let url = sessionTempURL("corrupt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SessionStore(storageURL: url)

    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("{ not json ".utf8))
    #expect(store.load() == nil)
}

@Test func loadReturnsNilOnForeignSchemaVersion() throws {
    let url = sessionTempURL("version")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SessionStore(storageURL: url)

    let root = VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"))
    let snapshot = SessionSnapshot(
        left: PanelTabsSnapshot(
            tabs: [PanelTabsSnapshot.TabSnapshot(path: root, isLocked: false, selection: [], historyBack: [], historyForward: [])],
            activeIndex: 0
        ),
        right: PanelTabsSnapshot(tabs: [], activeIndex: 0)
    )
    store.save(snapshot)

    // Rewrite the file with a future schema version.
    var encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["schemaVersion"] = SessionSnapshot.schemaVersion + 1
    encoded = try JSONSerialization.data(withJSONObject: object)
    try encoded.write(to: url)

    #expect(store.load() == nil)
}

@Test func saveCreatesMissingDirectoryAtomicallyAndClearRemoves() {
    let url = sessionTempURL("atomic")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SessionStore(storageURL: url)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

    let root = VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"))
    store.save(SessionSnapshot(
        left: PanelTabsSnapshot(
            tabs: [PanelTabsSnapshot.TabSnapshot(path: root, isLocked: false, selection: [], historyBack: [], historyForward: [])],
            activeIndex: 0
        ),
        right: PanelTabsSnapshot(tabs: [], activeIndex: 0)
    ))
    #expect(FileManager.default.fileExists(atPath: url.path))

    store.clear()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(store.load() == nil)
}
