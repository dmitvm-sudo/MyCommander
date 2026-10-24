// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import UniformTypeIdentifiers
import DomainKit

/// A minimal main-thread LRU map (docs/SDD/06 §6.1: «Иконки … с LRU-кэшем
/// (N ≤ 500)»). Deliberately not `Sendable`: panel caches live on the main actor
/// together with AppKit, and this keeps the generic container allocation-cheap.
public final class LRUCache<Key: Hashable, Value> {
    public let capacity: Int

    private var storage: [Key: Value] = [:]
    /// Recency order, oldest first. Capacity ≤ 500 makes O(n) touches negligible.
    private var order: [Key] = []

    public init(capacity: Int = 500) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    /// Read that refreshes recency (the usual panel path).
    public func get(_ key: Key) -> Value? {
        guard storage[key] != nil else { return nil }
        touch(key)
        return storage[key]
    }

    /// Read WITHOUT touching recency (debugger/diagnostics).
    public func peek(_ key: Key) -> Value? {
        storage[key]
    }

    public func put(_ key: Key, _ value: Value) {
        if storage[key] != nil { touch(key) } else { order.append(key) }
        storage[key] = value
        evictIfNeeded()
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage[oldest] = nil
        }
    }
}

/// Icon source for file rows: real paths get their exact `NSWorkspace` icon,
/// everything else (fixtures, virtual sources) falls back to an icon looked up
/// by file extension. Both routes funnel through the same LRU (N ≤ 500, §6.1).
@MainActor
public final class ItemCache {
    private let icons: LRUCache<String, NSImage>
    private var sharedTypeIcons: [String: NSImage] = [:]

    public init(maxIcons: Int = 500) {
        self.icons = LRUCache(capacity: maxIcons)
    }

    public var cachedIconCount: Int { icons.count }

    public func clear() {
        icons.removeAll()
    }

    public func icon(for item: VFSItem) -> NSImage? {
        let filenameExtension = (item.name as NSString).pathExtension
        if let url = item.id.displayURL {
            return icon(at: url, filenameExtension: filenameExtension)
        }
        switch item.kind {
        case .directory:
            return typeIcon(UTType.folder, cacheKey: "type:folder")
        case .symlink, .file, .special:
            return extensionIcon(filenameExtension)
        }
    }

    private func icon(at url: URL, filenameExtension: String) -> NSImage? {
        let key = "url:\(url.path)"
        if let cached = icons.get(key) { return cached }
        if !FileManager.default.fileExists(atPath: url.path) {
            return extensionIcon(filenameExtension)
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let copy = image.copy() as? NSImage
        icons.put(key, copy ?? image)
        return copy ?? image
    }

    private func extensionIcon(_ filenameExtension: String) -> NSImage {
        let key = "ext:\(filenameExtension)"
        if let cached = icons.get(key) { return cached }
        let image = typeIcon(UTType(filenameExtension: filenameExtension) ?? .data, cacheKey: key)
        return image
    }

    /// `NSWorkspace.shared.icon(for:)` results are tendentially shared — every
    /// consumer gets its own mutable copy the first time a key is cached.
    private func typeIcon(_ type: UTType, cacheKey: String) -> NSImage {
        if let cached = sharedTypeIcons[cacheKey] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        let copy = image.copy() as? NSImage ?? image
        sharedTypeIcons[cacheKey] = copy
        return copy
    }
}
