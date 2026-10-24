// SPDX-License-Identifier: GPL-3.0-or-later

// Contract: docs/SDD/05-DataModel-VFS.md §5.3 — what an adapter can honestly do.

public struct VFSCapabilities: Sendable, Hashable {
    public var canWrite: Bool
    public var canDelete: Bool
    public var canRename: Bool
    public var canWatch: Bool
    public var canRandomSeek: Bool
    public var preservesDates: Bool
    public var symlinkSupport: Bool
    /// `nil` = no practical limit known to the adapter.
    public var maxPathLength: Int?

    public init(
        canWrite: Bool = false,
        canDelete: Bool = false,
        canRename: Bool = false,
        canWatch: Bool = false,
        canRandomSeek: Bool = false,
        preservesDates: Bool = false,
        symlinkSupport: Bool = false,
        maxPathLength: Int? = nil
    ) {
        self.canWrite = canWrite
        self.canDelete = canDelete
        self.canRename = canRename
        self.canWatch = canWatch
        self.canRandomSeek = canRandomSeek
        self.preservesDates = preservesDates
        self.symlinkSupport = symlinkSupport
        self.maxPathLength = maxPathLength
    }

    /// Read-only source (e.g., zip outside pack flow): seekable listing only.
    public static let readOnly = VFSCapabilities(canRandomSeek: true)

    /// Local disk profile (LocalVFS, T-04): everything except explicit trash.
    public static let localDiskRW = VFSCapabilities(
        canWrite: true,
        canDelete: true,
        canRename: true,
        canWatch: true,
        canRandomSeek: true,
        preservesDates: true,
        symlinkSupport: true
    )

    /// In-memory test fake profile: full read/write, no watch/dates/symlinks.
    public static let inMemoryRW = VFSCapabilities(
        canWrite: true,
        canDelete: true,
        canRename: true,
        canRandomSeek: true
    )
}
