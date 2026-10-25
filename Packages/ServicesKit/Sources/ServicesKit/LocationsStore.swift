// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.9 (уточнение T-26) + 05 §5.7 (LocationBookmark) —
// F-11 bookmarks / hotlist / recent folders. `locations.json` (schemaVersion 1)
// holds no secrets; a foreign schemaVersion makes the file ignored entirely
// (по образцу ConnectionStore). `LocationTarget` is the 05 §5.7
// `Either<VFSPath, ConnectionID>` contract realized as an enum.

/// 05 §5.7: the bookmark target — a VFS path OR a saved connection.
public enum LocationTarget: Codable, Sendable, Equatable {
    case path(VFSPath)
    case connection(UUID)
}

/// The «двойная адресация» hint: which panel the bookmark opens in.
public enum LocationSide: String, Codable, Sendable {
    case left
    case right
}

public struct LocationBookmark: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var target: LocationTarget
    public var panelHint: LocationSide?
    public var hotSlot: Int?   // 1...9

    public init(
        id: UUID = UUID(),
        name: String,
        target: LocationTarget,
        panelHint: LocationSide? = nil,
        hotSlot: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.panelHint = panelHint
        self.hotSlot = hotSlot
    }
}

public struct LocationsSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var bookmarks: [LocationBookmark]
    public var recentFolders: [VFSPath]

    public init(bookmarks: [LocationBookmark] = [], recentFolders: [VFSPath] = []) {
        self.schemaVersion = Self.schemaVersion
        self.bookmarks = bookmarks
        self.recentFolders = recentFolders
    }
}

/// F-11 store: bookmarks, 9 hotlist slots, recent folders (06 §6.9).
public final class LocationsStore: @unchecked Sendable {
    public static let hotSlotCount = 9
    static let recentFolderLimit = 20

    private let storageURL: URL

    public static func defaultStorageURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("locations.json")
    }

    public init(storageURL: URL = LocationsStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    // MARK: bookmarks

    /// Empty on a missing/corrupted/foreign-version file.
    public func bookmarks() -> [LocationBookmark] {
        load().bookmarks
    }

    /// ⌘D: appends a bookmark (no hot slot by default) and persists.
    @discardableResult
    public func addBookmark(
        name: String, target: LocationTarget, panelHint: LocationSide? = nil
    ) -> LocationBookmark {
        var snapshot = load()
        let bookmark = LocationBookmark(name: name, target: target, panelHint: panelHint)
        snapshot.bookmarks.append(bookmark)
        persist(snapshot)
        return bookmark
    }

    public func remove(id: UUID) {
        var snapshot = load()
        snapshot.bookmarks.removeAll { $0.id == id }
        persist(snapshot)
    }

    // MARK: hotlist (9 slots, F-11)

    public func hotSlot(_ slot: Int) -> LocationBookmark? {
        guard (1 ... Self.hotSlotCount).contains(slot) else { return nil }
        return load().bookmarks.first { $0.hotSlot == slot }
    }

    /// Assigns the slot; a previous occupant loses it (one bookmark per slot).
    public func assignHotSlot(_ slot: Int, for id: UUID) {
        guard (1 ... Self.hotSlotCount).contains(slot) else { return }
        var snapshot = load()
        for index in snapshot.bookmarks.indices {
            snapshot.bookmarks[index].hotSlot = snapshot.bookmarks[index].id == id ? slot : nil
        }
        persist(snapshot)
    }

    public func clearHotSlot(_ slot: Int) {
        guard (1 ... Self.hotSlotCount).contains(slot) else { return }
        var snapshot = load()
        for index in snapshot.bookmarks.indices where snapshot.bookmarks[index].hotSlot == slot {
            snapshot.bookmarks[index].hotSlot = nil
        }
        persist(snapshot)
    }

    // MARK: recent folders (ring, F-11)

    public func recentFolders() -> [VFSPath] {
        load().recentFolders
    }

    /// Dedupe (move-to-front), capped at 20 entries.
    public func noteVisit(_ path: VFSPath) {
        var snapshot = load()
        snapshot.recentFolders.removeAll { $0 == path }
        snapshot.recentFolders.insert(path, at: 0)
        if snapshot.recentFolders.count > Self.recentFolderLimit {
            snapshot.recentFolders.removeLast(snapshot.recentFolders.count - Self.recentFolderLimit)
        }
        persist(snapshot)
    }

    // MARK: persistence

    private func load() -> LocationsSnapshot {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let snapshot = try? JSONDecoder().decode(LocationsSnapshot.self, from: data),
              snapshot.schemaVersion == LocationsSnapshot.schemaVersion
        else { return LocationsSnapshot() }
        return snapshot
    }

    private func persist(_ snapshot: LocationsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
