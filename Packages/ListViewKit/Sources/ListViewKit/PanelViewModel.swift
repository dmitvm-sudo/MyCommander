// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import DomainKit

/// Panel state (docs/SDD/06 §6.1): listing + sort + selection + cursor. Main-actor
/// confined; rendering sync belongs to `FileListView` reading those values, so the
/// model itself has no AppKit dependency and stays testable headless.
///
/// Contract details:
/// - `rawItems` keeps the listing as delivered, `visibleIndices` are offsets into
///   it after sort (filter support arrives with T-07);
/// - selection stores item identities (`VFSPath`), so re-sorting never remaps it;
/// - selection/cursor updates are silent: they do not fire
///   `onContentsChanged` (the mutating view refreshes the status line itself) —
///   only listing changes trigger a table reload.
@MainActor
public final class PanelViewModel {
    public private(set) var path: VFSPath?
    public private(set) var rawItems: [VFSItem] = []
    public private(set) var visibleIndices: [Int] = []
    public private(set) var selection: Set<VFSPath> = []
    public private(set) var cursor: Int = 0
    public var sort: SortCriteria

    /// The panel's data source; owned for `openDirectory`, `goUp` and `reload`.
    public let source: any VFS

    /// Fires after the listing/sort changed (view reloads its table).
    public var onContentsChanged: (() -> Void)?
    /// Surfaces navigation failures for the status line.
    public var onError: ((MCError) -> Void)?

    public init(
        source: any VFS,
        sort: SortCriteria = SortCriteria(key: .name, order: .ascending, dirsFirst: true)
    ) {
        self.source = source
        self.sort = sort
    }

    public var visibleCount: Int { visibleIndices.count }

    public var selectedCount: Int { selection.count }

    /// Injects a listing directly (tests, T-06 diff updates). Sorts, resets
    /// cursor/selection (item identities may no longer exist), notifies the view.
    public func setItems(_ items: [VFSItem], at path: VFSPath?) {
        self.path = path
        rawItems = items
        recomputeVisibility()
        selection = []
        cursor = 0
        onContentsChanged?()
    }

    /// Switches sorting; identities survive, so selection is preserved.
    public func setSort(_ criteria: SortCriteria) {
        sort = criteria
        recomputeVisibility()
        cursor = max(0, min(cursor, max(visibleCount - 1, 0)))
        onContentsChanged?()
    }

    public func item(atVisibleIndex index: Int) -> VFSItem? {
        guard visibleIndices.indices.contains(index) else { return nil }
        return rawItems[visibleIndices[index]]
    }

    public func setCursor(_ index: Int) {
        cursor = max(0, min(index, max(visibleCount - 1, 0)))
    }

    /// Replaces the whole selection (view maps its `selectedRowIndexes` here).
    public func setSelection(_ paths: Set<VFSPath>) {
        selection = paths
    }

    /// Loads `path` and publishes the listing. Throws `MCError` upward; callers
    /// (such as `goUp`) also get it through `onError`.
    public func openDirectory(at path: VFSPath) async throws {
        let items = try await source.listDirectory(at: path)
        setItems(items, at: path)
    }

    /// Return/Enter: directory rows navigate, files are ignored (returns nil).
    @discardableResult
    public func openItem(atVisibleIndex index: Int) async -> VFSPath? {
        guard let entry = item(atVisibleIndex: index) else { return nil }
        switch entry.kind {
        case .directory:
            do { try await openDirectory(at: entry.id); return entry.id }
            catch { onError?(normalize(error)); return nil }
        case .symlink(let target):
            guard let target, target.root == source.id else { return nil }
            do { try await openDirectory(at: target); return target }
            catch { onError?(normalize(error)); return nil }
        case .file, .special:
            return nil
        }
    }

    /// ⌘↑. `false` at the root or on failure (failure also goes to `onError`).
    @discardableResult
    public func goUp() async -> Bool {
        guard let path, !path.components.isEmpty else { return false }
        let parent = VFSPath(
            root: path.root,
            components: Array(path.components.dropLast()),
            displayURL: path.displayURL?.deletingLastPathComponent()
        )
        do {
            try await openDirectory(at: parent)
            return true
        } catch {
            onError?(normalize(error))
            return false
        }
    }

    /// Re-lists the current path (no-op before the very first listing).
    public func reload() async {
        guard let path else { return }
        do { try await openDirectory(at: path) }
        catch { onError?(normalize(error)) }
    }

    /// `visibleIndices`, recomputed with the DomainKit comparator (dirsFirst etc.).
    private func recomputeVisibility() {
        var offsetByID: [VFSPath: Int] = [:]
        offsetByID.reserveCapacity(rawItems.count)
        for (offset, item) in rawItems.enumerated() where offsetByID[item.id] == nil {
            offsetByID[item.id] = offset
        }
        visibleIndices = rawItems
            .sortedItems(by: [sort])
            .compactMap { offsetByID[$0.id] }
    }

    private func normalize(_ error: Error) -> MCError {
        error as? MCError ?? MCError.unexpected(underlying: error)
    }
}
