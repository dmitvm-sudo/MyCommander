// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a listed entry is. Contract: docs/SDD/05-DataModel-VFS.md §5.2.
public enum VFSItemKind: Sendable {
    case directory
    case file
    case symlink(target: VFSPath?)
    case special
}

/// Attribute set reported by a VFS adapter. Optional fields stay `nil` until the
/// adapter (or a background scan, F-19) fills them in.
public struct VFSItemAttributes: Sendable {
    /// `nil` for directories until a directorySize query resolves it (F-19).
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var posixPermissions: Int16?
    public var owner: String?
    public var group: String?
    public var isHidden: Bool
    public var isReadOnly: Bool
    /// macOS tags (F-4 custom columns); populated by LocalVFS only.
    public var tags: [String]
    /// Extra provider-defined fields for custom columns (contract §5.2).
    public var urlResourceMeta: [String: String]

    public init(
        size: Int64? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        posixPermissions: Int16? = nil,
        owner: String? = nil,
        group: String? = nil,
        isHidden: Bool = false,
        isReadOnly: Bool = false,
        tags: [String] = [],
        urlResourceMeta: [String: String] = [:]
    ) {
        self.size = size
        self.created = created
        self.modified = modified
        self.posixPermissions = posixPermissions
        self.owner = owner
        self.group = group
        self.isHidden = isHidden
        self.isReadOnly = isReadOnly
        self.tags = tags
        self.urlResourceMeta = urlResourceMeta
    }
}

/// A concrete entry of a directory listing. Value type (Sendable); it is cached
/// and diffed by the panel without touching the disk again (docs/SDD/06 §6.1).
public struct VFSItem: Identifiable, Sendable {
    /// Stable for the depth of the session (path + source identity).
    public var id: VFSPath
    public var instance: VFSInstanceID
    /// Display name as shown in the panel (NFC).
    public var name: String
    public var kind: VFSItemKind
    public var attributes: VFSItemAttributes
    /// Revision of the directory snapshot this item came from (see §5.4).
    public var revision: UInt64

    public init(
        id: VFSPath,
        instance: VFSInstanceID,
        name: String,
        kind: VFSItemKind,
        attributes: VFSItemAttributes,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.instance = instance
        self.name = name
        self.kind = kind
        self.attributes = attributes
        self.revision = revision
    }
}
