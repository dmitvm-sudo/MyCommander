// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
import DomainKit
@testable import ListViewKit

// T-05: LRU eviction semantics (docs/SDD/06 §6.1: N ≤ 500) and the icon cache
// identity guarantees the cells rely on.

private func cacheItem(
    root: VFSInstanceID,
    name: String,
    url: URL? = nil,
    isDirectory: Bool = false
) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: [name], displayURL: url),
        instance: root,
        name: name,
        kind: isDirectory ? .directory : .file,
        attributes: VFSItemAttributes(),
        revision: 1
    )
}

@Test @MainActor func lruEvictsOldestNonTouchedEntry() {
    let cache = LRUCache<String, Int>(capacity: 3)
    cache.put("k1", 1)
    cache.put("k2", 2)
    cache.put("k3", 3)
    #expect(cache.count == 3)

    #expect(cache.get("k1") == 1)           // touch k1: it survives the eviction
    cache.put("k4", 4)                      // capacity exceeded → drop «k2» (oldest, untouched)

    #expect(cache.peek("k2") == nil)
    #expect(cache.peek("k1") == 1)
    #expect(cache.peek("k3") == 3)
    #expect(cache.peek("k4") == 4)
    #expect(cache.count == 3)
}

@Test @MainActor func lruPutExistingKeyRefreshesAndReplaces() {
    let cache = LRUCache<String, Int>(capacity: 2)
    cache.put("k1", 1)
    cache.put("k2", 2)
    cache.put("k1", 11)                     // refresh k1 → k2 becomes the oldest

    #expect(cache.peek("k1") == 11)
    cache.put("k3", 3)
    #expect(cache.peek("k2") == nil)
    #expect(cache.peek("k1") == 11)
}

@Test @MainActor func lruClearResetsEverything() {
    let cache = LRUCache<String, Int>(capacity: 2)
    cache.put("k1", 1)
    cache.put("k2", 2)
    cache.removeAll()
    #expect(cache.count == 0)
    #expect(cache.peek("k1") == nil)
}

@Test @MainActor func itemCacheReturnsStableIconPerExtension() async {
    let cache = ItemCache()
    let instance = VFSInstanceID(kind: .localDisk, specID: "icon-unit")
    let first = cacheItem(root: instance, name: "diagram.svg")
    let second = cacheItem(root: instance, name: "poster.svg")

    let firstIcon = cache.icon(for: first)
    let secondIcon = cache.icon(for: second)
    #expect(firstIcon != nil)
    // Same-extension items share one NSImage instance (static type-icon map).
    #expect(firstIcon === secondIcon)
}

@Test @MainActor func itemCacheDirectoriesUseFolderIcon() async {
    let cache = ItemCache()
    let instance = VFSInstanceID(kind: .localDisk, specID: "icon-unit")
    let directory = VFSItem(
        id: VFSPath(root: instance, components: ["docs"]),
        instance: instance,
        name: "docs",
        kind: .directory,
        attributes: VFSItemAttributes(),
        revision: 1
    )
    #expect(cache.icon(for: directory) != nil)
}

@Test @MainActor func itemCacheFallsBackToExtensionIconForMissingURL() async {
    let cache = ItemCache()
    let instance = VFSInstanceID(kind: .localDisk, specID: "icon-unit")
    let missing = cacheItem(
        root: instance,
        name: "ghost.doc",
        url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mclv-missing-\(UUID().uuidString).doc")
    )
    #expect(cache.icon(for: missing) != nil)   // no such file → ext icon
}

@Test @MainActor func itemCacheUsesExactIconForRealFiles() async throws {
    let cache = ItemCache()
    let instance = VFSInstanceID(kind: .localDisk, specID: "icon-unit")
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mclv-icon-\(UUID().uuidString).txt")
    try Data("icon fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let stored = cacheItem(root: instance, name: "stored.txt", url: url)
    let icon = cache.icon(for: stored)
    let again = cache.icon(for: stored)
    #expect(icon != nil)
    #expect(icon === again)   // URL cache hit: same instance
}
