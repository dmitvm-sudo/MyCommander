// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.9 (SessionStore — «перенастраиваемый список табов
// к моменту выхода, restore on launch») and docs/SDD/02 F-2 acceptance
// («состояние вкладок переживает рестарт приложения»). Paths serialize via
// VFSPath Codable (docs/SDD/05 §5.1: «Codable … persistent sessions»).

/// The persisted state of one panel's tabs.
public struct PanelTabsSnapshot: Codable, Sendable, Equatable {
    public struct TabSnapshot: Codable, Sendable, Equatable {
        public var path: VFSPath
        public var isLocked: Bool
        public var selection: Set<VFSPath>
        public var historyBack: [VFSPath]
        public var historyForward: [VFSPath]

        public init(
            path: VFSPath,
            isLocked: Bool,
            selection: Set<VFSPath>,
            historyBack: [VFSPath],
            historyForward: [VFSPath]
        ) {
            self.path = path
            self.isLocked = isLocked
            self.selection = selection
            self.historyBack = historyBack
            self.historyForward = historyForward
        }
    }

    public var tabs: [TabSnapshot]
    public var activeIndex: Int

    public init(tabs: [TabSnapshot], activeIndex: Int) {
        self.tabs = tabs
        self.activeIndex = activeIndex
    }
}

/// Full application session: both panels' tab stacks. `schemaVersion` enables
/// forward migrations (docs/SDD/11: Migrations.swift governs version bumps).
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var left: PanelTabsSnapshot
    public var right: PanelTabsSnapshot

    public init(left: PanelTabsSnapshot, right: PanelTabsSnapshot) {
        self.schemaVersion = Self.schemaVersion
        self.left = left
        self.right = right
    }
}

/// File-backed session store. The storage URL is injectable so tests run
/// against a temporary directory; the default location is
/// `~/Library/Application Support/MyCommander/session.json`.
public final class SessionStore {
    private let storageURL: URL

    public static func defaultStorageURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public init(storageURL: URL = SessionStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    /// `nil` when the session is missing, unreadable, corrupted, or written by
    /// a different schema version (older sessions are not auto-migrated yet).
    public func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == SessionSnapshot.schemaVersion else { return nil }
        return snapshot
    }

    /// Atomic replace: temp file + rename (Data.write with .atomic).
    public func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    /// Removes the stored session (tests, «disable session persistence»).
    public func clear() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}
