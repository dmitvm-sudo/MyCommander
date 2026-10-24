// SPDX-License-Identifier: GPL-3.0-or-later

// Contract: docs/SDD/05-DataModel-VFS.md §5.4 (observation) and
// docs/SDD/06-Subsystems-Design.md §6.3 (FSEventsWatcher, self-suppression, diff).

/// knobs of one watch stream. Coalescing default mirrors LocalVFS (300 ms, §6.3).
public struct WatchOptions: Sendable, Hashable {
    /// Window in which successive changes collapse into one `itemsChanged` diff.
    public var coalescingMilliseconds: Int

    public init(coalescingMilliseconds: Int = 300) {
        self.coalescingMilliseconds = coalescingMilliseconds
    }
}

/// Snapshot comparison result (06 §6.3: lstat snapshot vs fresh listDirectory).
public struct DirectoryDiff: Sendable {
    public var added: [VFSItem]
    public var removed: [VFSItem]
    public var updated: [VFSItem]

    public init(added: [VFSItem] = [], removed: [VFSItem] = [], updated: [VFSItem] = []) {
        self.added = added
        self.removed = removed
        self.updated = updated
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty }

    /// Helper for panel diff-batching (ListViewKit/DiffUpdate): union of all entries.
    public var touchedItems: [VFSItem] { added + removed + updated }
}

public enum WatchEvent: Sendable {
    case itemsChanged(diff: DirectoryDiff)
    case volumeEvent(volume: VFSInstanceID, mounted: Bool)
}

public extension VFSItem {
    /// Content-equivalence for watcher diffs and panel delta-batching:
    /// every displayed field is compared, `revision` is NOT (each re-list
    /// renumbers snapshots and would flood panels with phantom updates).
    func isContentEquivalent(to other: VFSItem) -> Bool {
        if name != other.name { return false }
        switch (kind, other.kind) {
        case (.directory, .directory), (.file, .file), (.special, .special):
            break
        case (.symlink(let a), .symlink(let b)):
            if a != b { return false }
        default:
            return false
        }
        let lhs = attributes
        let rhs = other.attributes
        return lhs.size == rhs.size
            && lhs.created == rhs.created
            && lhs.modified == rhs.modified
            && lhs.posixPermissions == rhs.posixPermissions
            && lhs.isHidden == rhs.isHidden
            && lhs.isReadOnly == rhs.isReadOnly
            && lhs.tags == rhs.tags
            && lhs.urlResourceMeta == rhs.urlResourceMeta
    }
}

/// One engine serves many watches (LocalVFS: single FSEventStream for all watched
/// dirs, §6.3). Non-watchable providers yield a stream that finishes immediately —
/// the panel then refreshes on foreground return instead of events.
public protocol FileWatchEngineProtocol: Sendable {
    func watch(_ path: VFSPath, options: WatchOptions) -> AsyncStream<WatchEvent>
}
