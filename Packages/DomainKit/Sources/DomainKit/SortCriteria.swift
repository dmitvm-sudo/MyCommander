// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

// Contract: docs/SDD/05-DataModel-VFS.md §5.9 — presets and sorting.

public enum SortKey: Codable, Sendable, Hashable {
    case name
    case `extension`
    case size
    case modified
    case created
    case kind
}

public enum SortOrder: Codable, Sendable, Hashable {
    case ascending
    case descending
}

public struct SortCriteria: Codable, Sendable, Hashable {
    public var key: SortKey
    public var order: SortOrder
    public var dirsFirst: Bool = true

    public init(key: SortKey, order: SortOrder = .ascending, dirsFirst: Bool = true) {
        self.key = key
        self.order = order
        self.dirsFirst = dirsFirst
    }
}

/// Column identifiers for file lists. `gitStatus` is reserved for v1.x providers
/// (F-24); provider-specific columns arrive in v1.x and will extend this enum
/// (see docs/SDD/12, T-02 «Уточнение»).
public enum ColumnID: String, Codable, Sendable, CaseIterable {
    case name
    case size
    case dateModified
    case dateCreated
    case kind
    case tags
    case permissions
    case owner
    case gitStatus   // v1.x (plugin contract F-27, dogfood F-24)
}

/// Display preset of a panel (brief/full modes belong to F-4; this struct carries
/// custom-columns configuration and sorting).
public struct ViewPreset: Codable, Sendable {
    public var columns: [ColumnID]
    public var widths: [Int: CGFloat]
    public var sort: SortCriteria

    public init(columns: [ColumnID], widths: [Int: CGFloat], sort: SortCriteria) {
        self.columns = columns
        self.widths = widths
        self.sort = sort
    }
}

/// Extension of a display name, the classic-manager way: what follows the last "."
/// when the name does not BEGIN with a dot ("makefile" -> nil, ".hidden" -> nil,
/// "a.tar.gz" -> "gz").
func vfsFileExtension(of name: String) -> String? {
    guard let lastDot = name.lastIndex(of: "."),
          lastDot != name.startIndex,
          lastDot < name.index(before: name.endIndex)
    else { return nil }
    return String(name[name.index(after: lastDot)...])
}

public extension Array where Element == VFSItem {
    /// Sorts a listing under one or more criteria (primary first).
    /// - Names compare locale-aware, standard (Finder-like, "numbers ordered").
    /// - Directories precede other kinds when ANY `dirsFirst` criterion is present,
    ///   regardless of key/order.
    /// - Ties keep input order (Swift's `sorted` is stable).
    func sortedItems(by criteria: [SortCriteria]) -> [Element] {
        sorted { itemLess($0, $1, by: criteria) }
    }

    /// Same semantics as `sortedItems(by:)` over the INDICES of the listing —
    /// without copying the items themselves (N-2 hardening T-19: a 100k-panel
    /// sort carries a 0.8 MB [Int] transient, not a 100k-item snapshot copy).
    /// Stable, so it reproduces `sortedItems` row-for-row.
    func sortedIndices(by criteria: [SortCriteria]) -> [Int] {
        var indices = Array<Int>(self.indices)
        indices.sort { itemLess(self[$0], self[$1], by: criteria) }
        return indices
    }
}

/// Shared stable comparator (dirsFirst first, then per-criterion order).
private func itemLess(_ a: VFSItem, _ b: VFSItem, by criteria: [SortCriteria]) -> Bool {
    if a.isDirectory != b.isDirectory, criteria.contains(where: { $0.dirsFirst }) {
        return a.isDirectory
    }
    for criterion in criteria {
        let result = itemCompare(a, b, by: criterion.key) * orderSign(of: criterion.order)
        if result != 0 { return result < 0 }
    }
    return false
}

extension VFSItem {
    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }
}

private func orderSign(of order: SortOrder) -> Int {
    switch order {
    case .ascending: return 1
    case .descending: return -1
    }
}

private func comparisonValue(_ result: ComparisonResult) -> Int {
    switch result {
    case .orderedSame: return 0
    case .orderedAscending: return -1
    case .orderedDescending: return 1
    @unknown default: return 0
    }
}

private func itemCompare(_ a: VFSItem, _ b: VFSItem, by key: SortKey) -> Int {
    switch key {
    case .name:
        return comparisonValue(a.name.localizedStandardCompare(b.name))
    case .`extension`:
        let aExt = vfsFileExtension(of: a.name)
        let bExt = vfsFileExtension(of: b.name)
        let result = comparisonValue((aExt ?? "").caseInsensitiveCompare(bExt ?? ""))
        return result != 0 ? result : comparisonValue(a.name.localizedStandardCompare(b.name))
    case .size:
        let aSize = a.attributes.size ?? -1
        let bSize = b.attributes.size ?? -1
        return aSize < bSize ? -1 : (aSize > bSize ? 1 : 0)
    case .modified:
        return compareDates(a.attributes.modified, b.attributes.modified)
    case .created:
        return compareDates(a.attributes.created, b.attributes.created)
    case .kind:
        return kindRank(a.kind) - kindRank(b.kind)
    }
}

private func compareDates(_ a: Date?, _ b: Date?) -> Int {
    let aDate = a ?? .distantPast
    let bDate = b ?? .distantPast
    return aDate < bDate ? -1 : (aDate > bDate ? 1 : 0)
}

private func kindRank(_ kind: VFSItemKind) -> Int {
    switch kind {
    case .directory: return 0
    case .symlink: return 1
    case .file: return 2
    case .special: return 3
    }
}
