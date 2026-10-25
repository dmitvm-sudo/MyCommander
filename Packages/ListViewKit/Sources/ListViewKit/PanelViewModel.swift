// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import DomainKit
import EnginesKit

/// Panel state (docs/SDD/06 §6.1): listing + sort + filter + selection + cursor.
/// Main-actor confined; rendering sync belongs to `FileListView` reading those
/// values, so the model itself has no AppKit dependency and stays testable
/// headless.
///
/// Contract details:
/// - `rawItems` keeps the listing as delivered, `visibleIndices` are offsets
///   into it after sort + quick filter (F-10); the visible order is what the
///   table shows, so delta batching operates on visible rows only;
/// - selection stores item identities (`VFSPath`) and lives in rawItems space:
///   re-sorting and quick filtering never remap it, refreshes keep the
///   surviving part (F-3), navigation resets it;
/// - selection/cursor updates are silent: they do not fire
///   `onContentsChanged` (the mutating view refreshes the status line itself) —
///   only listing/visibility changes notify the view.
/// - quick filter works incrementally (docs/SDD/06 §6.6): a prepared
///   (lowercased) name index is kept next to `rawItems`; a query that extends
///   the previous one re-tests only the previous result.
@MainActor
public final class PanelViewModel {
    /// Display modes (F-4 start: brief/full; custom columns and thumbnails come
    /// later per docs/SDD/02 F-4).
    public enum ViewMode: Sendable, Hashable {
        case brief
        case full
    }

    public private(set) var path: VFSPath?
    public private(set) var rawItems: [VFSItem] = []
    public private(set) var visibleIndices: [Int] = []
    public private(set) var selection: Set<VFSPath> = []
    public private(set) var cursor: Int = 0
    public var sort: SortCriteria
    public private(set) var viewMode: ViewMode = .full

    /// Quick filter state (F-10). `filterQuery` is only mutated through
    /// `setFilter`/`appendFilterCharacter`/`clearFilter`, which keep
    /// `lastFilterQuery` in sync for prefix memoization.
    public private(set) var filterQuery: String = ""
    /// Configurable matching style (F-10 «подстрока/fuzzy, настраиваемо»);
    /// the SettingsStore wiring arrives with the settings task.
    public var filterStyle: FilterStyle = .substring
    /// Selection before the last mutation — «Restore selection» (`Num /`, F-3).
    public private(set) var previousSelection: Set<VFSPath> = []

    /// Lowercased item names, index-aligned with `rawItems` (§6.6: no string
    /// recreation per filter pass).
    private var preparedNames: [String] = []
    /// Query the current `visibleIndices` were computed with (memo key).
    private var lastFilterQuery: String = ""

    /// The panel's data source; owned for `openDirectory`, `goUp` and `reload`.
    public let source: any VFS

    /// The watch engine the panel subscribes to for external changes. Set by the
    /// owner (App assembly); may be nil (headless tests keep tailoring).
    public var watchEngine: (any FileWatchEngineProtocol)? {
        didSet { restartWatch() }
    }

    /// Internal watch loop: one `engine.watch(path)` task per current directory.
    private var watchTask: Task<Void, Never>?

    /// Fires after the listing/sort/mode changed (view reloads its table).
    public var onContentsChanged: (() -> Void)?
    /// Fires for incremental updates (watch engine + filter strokes): the view
    /// applies table batches via `FileListDelta` instead of a full reload (F-1).
    public var onContentsDelta: ((FileListDelta) -> Void)?
    /// Exposed for wiring (the App layer may rewire watchers on navigation).
    public var onPathChanged: ((VFSPath?) -> Void)?
    /// Surfaces navigation failures for the status line.
    public var onError: ((MCError) -> Void)?
    /// Seated by the tab layer (F-2): return `false` to deny a navigation —
    /// the gate owner decides what happens instead (locked tabs divert the
    /// opened directory into a fresh tab). `nil` gate means always allowed.
    public var navigationGate: ((VFSPath) -> Bool)?
    /// Уточнение T-21 (06 §6.1, archive interlude): Enter on a file/special entry
    /// that is an archive container — the owner (App assembly, set for every VM)
    /// mounts the archive and swaps the tab's view model. `true` = consumed (the
    /// item is «opened» by the handler); `false`/`nil` — the previous behaviour.
    public var openEntryHandler: ((VFSItem) async -> Bool)?
    /// Уточнение T-21: ⌘↑ at the root of an ARCHIVE panel exits the interlude —
    /// App rebinds the panel view model back to the host. Only archive VMs carry
    /// it (local panels keep the historical no-op behaviour at the root).
    public var onRootExit: (() async -> Void)?
    /// Session restore (T-08): a selection applied at the next non-refresh
    /// listing (a fresh tab loading its directory).
    public func stageSelectionRestore(_ identities: Set<VFSPath>) {
        stagedSelectionRestore = identities
    }
    private var stagedSelectionRestore: Set<VFSPath>?

    public init(
        source: any VFS,
        sort: SortCriteria = SortCriteria(key: .name, order: .ascending, dirsFirst: true)
    ) {
        self.source = source
        self.sort = sort
    }

    public var visibleCount: Int { visibleIndices.count }

    public var selectedCount: Int { selection.count }

    /// F-10 «фильтр активен» indicator state.
    public var isFilterActive: Bool { !filterQuery.isEmpty }

    /// Injects a listing directly (tests, T-06 diff updates). Sorts + filters,
    /// notifies the view. Refresh semantics (F-3): when the path did not
    /// change, selection survives for still-existing identities (the dropped
    /// part is remembered in `previousSelection` for «Restore selection») and
    /// the cursor stays in context; navigation resets cursor/selection/filter.
    public func setItems(_ items: [VFSItem], at path: VFSPath?) {
        let previousPath = self.path
        let isRefresh = path == previousPath
        let oldOrder = order()
        self.path = path
        rawItems = items
        rebuildNameIndex()
        recomputeVisibility()
        if isRefresh {
            let surviving = Set(rawItems.map(\.id))
            let dropped = selection.subtracting(surviving)
            if !dropped.isEmpty {
                previousSelection = selection   // «Restore selection» source (Num /)
            }
            selection.formIntersection(surviving)
            remapCursor(after: oldOrder)
        } else {
            selection = []
            if let staged = stagedSelectionRestore {
                stagedSelectionRestore = nil
                // Session restore: only identities present in the fresh listing.
                selection = staged.intersection(Set(rawItems.map(\.id)))
            }
            previousSelection = []
            filterQuery = ""
            lastFilterQuery = ""
            cursor = 0
        }
        onContentsChanged?()
        if path != previousPath {
            onPathChanged?(path)
            restartWatch()
        }
    }

    /// Switches sorting; identities survive, so selection is preserved.
    public func setSort(_ criteria: SortCriteria) {
        sort = criteria
        recomputeVisibility()
        cursor = max(0, min(cursor, max(visibleCount - 1, 0)))
        onContentsChanged?()
    }

    /// F-4 (start): brief — names only; full — name/size/date columns.
    public func setViewMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
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

    // MARK: quick filter (F-10)

    /// Type-to-filter: extends/rewrites the query and republishes visibility as
    /// a delta. Extension strokes reuse the previous result (docs/SDD/06 §6.6
    /// «мемоизация префикса ввода»); any other edit recomputes the whole sorted
    /// pass. The cursor stays in context (remapped by identity, then clamped).
    public func setFilter(_ query: String) {
        let previous = lastFilterQuery
        let oldOrder = order()
        filterQuery = query
        lastFilterQuery = query
        let isExtension = !previous.isEmpty && query.hasPrefix(previous) && query.count > previous.count
        if isExtension {
            let prepared = FilterEngine.prepare(query)
            visibleIndices = FilterEngine.filter(
                preparedNames: preparedNames,
                query: prepared,
                style: filterStyle,
                candidates: visibleIndices
            )
        } else {
            recomputeVisibility()
        }
        remapCursor(after: oldOrder)
        publishVisibilityChange(from: oldOrder)
    }

    /// A printable keystroke appends to the active filter.
    public func appendFilterCharacter(_ character: Character) {
        setFilter(filterQuery + String(character))
    }

    public func deleteLastFilterCharacter() {
        guard !filterQuery.isEmpty else { return }
        setFilter(String(filterQuery.dropLast()))
    }

    /// Esc: reset the filter — full visibility again, cursor in context.
    public func clearFilter() {
        setFilter("")
    }

    /// Enter with an active filter: cursor jumps to the first match; the filter
    /// stays active so the narrowed view remains the panel's context.
    public func acceptFilter() {
        guard isFilterActive else { return }
        cursor = 0
    }

    // MARK: selection model (F-3)

    /// Ins/Space: toggle the row under the cursor, then move down (folder-size
    /// accounting for Space arrives with F-19's directorySize work).
    public func toggleSelectionUnderCursorAndMove() {
        guard let item = item(atVisibleIndex: cursor) else { return }
        rememberPreviousSelection()
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        setCursor(cursor + 1)
    }

    /// Num `+`: select visible rows matching a mask (default «all»).
    public func select(matching mask: FileMask) {
        rememberPreviousSelection()
        for index in visibleIndices where mask.matches(rawItems[index].name) {
            selection.insert(rawItems[index].id)
        }
    }

    /// Num `−`: deselect visible rows matching a mask.
    public func deselect(matching mask: FileMask) {
        rememberPreviousSelection()
        for index in visibleIndices where mask.matches(rawItems[index].name) {
            selection.remove(rawItems[index].id)
        }
    }

    public func selectAll() {
        select(matching: FileMask(["*"]))
    }

    public func deselectAll() {
        deselect(matching: FileMask(["*"]))
    }

    /// Num `*`: invert the selection over all visible rows.
    public func invertAll() {
        rememberPreviousSelection()
        for index in visibleIndices {
            let identity = rawItems[index].id
            if selection.contains(identity) {
                selection.remove(identity)
            } else {
                selection.insert(identity)
            }
        }
    }

    /// Num `/`: restore the previous selection (swaps with the remembered one).
    public func restoreSelection() {
        let current = selection
        selection = previousSelection
        previousSelection = current
    }

    /// Batch operations (T-09) act on this: empty selection falls back to the
    /// file under the cursor (F-3 acceptance).
    public var effectiveSelection: Set<VFSPath> {
        if !selection.isEmpty { return selection }
        if let item = item(atVisibleIndex: cursor) { return [item.id] }
        return []
    }

    private func rememberPreviousSelection() {
        previousSelection = selection
    }

    /// Loads `path` and publishes the listing. Throws `MCError` upward; callers
    /// (such as `goUp`) also get it through `onError`. A `navigationGate`
    /// returning `false` silently cancels the navigation (locked tabs, F-2);
    /// history replays bypass the gate — the lock governs new navigations only.
    public func openDirectory(at path: VFSPath, bypassingGate: Bool = false) async throws {
        guard bypassingGate || navigationGate?(path) ?? true else { return }
        try await loadAndPublish(path)
    }

    private func loadAndPublish(_ path: VFSPath) async throws {
        let items = try await source.listDirectory(at: path)
        setItems(items, at: path)
    }

    /// Return/Enter: directory rows navigate, files are ignored (returns nil).
    @discardableResult
    public func openItem(atVisibleIndex index: Int) async -> VFSPath? {
        guard let entry = item(atVisibleIndex: index) else { return nil }
        switch entry.kind {
        case .directory:
            guard navigationGate?(entry.id) ?? true else { return nil }
            do { try await loadAndPublish(entry.id); return entry.id }
            catch { onError?(normalize(error)); return nil }
        case .symlink(let target):
            guard let target, target.root == source.id else { return nil }
            guard navigationGate?(target) ?? true else { return nil }
            do { try await loadAndPublish(target); return target }
            catch { onError?(normalize(error)); return nil }
        case .file, .special:
            guard let openEntryHandler else { return nil }
            if await openEntryHandler(entry) { return entry.id }
            return nil
        }
    }

    /// ⌘↑. Inside an archive panel the root exit goes through `onRootExit`
    /// (App rebinds the host view model; 06 §6.1 T-21). `false` at the root
    /// without the hook, when denied by the gate, or on failure (failure also
    /// goes to `onError`).
    @discardableResult
    public func goUp() async -> Bool {
        guard let path, !path.components.isEmpty else {
            await onRootExit?()   // archive interlude: back to the host panel
            return false
        }
        let parent = VFSPath(
            root: path.root,
            components: Array(path.components.dropLast()),
            displayURL: path.displayURL?.deletingLastPathComponent()
        )
        guard navigationGate?(parent) ?? true else { return false }
        do {
            try await loadAndPublish(parent)
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

    /// `visibleIndices`, recomputed with the DomainKit comparator (dirsFirst
    /// etc.), then narrowed by the active quick filter (sorted order preserved).
    private func recomputeVisibility() {
        var offsetByID: [VFSPath: Int] = [:]
        offsetByID.reserveCapacity(rawItems.count)
        for (offset, item) in rawItems.enumerated() where offsetByID[item.id] == nil {
            offsetByID[item.id] = offset
        }
        // N-2 (T-19): index-sort — no 100k-item transient copy sits in the
        // malloc small zones after the recompute (footprint hardening test).
        let sortedIndices = rawItems
            .sortedIndices(by: [sort])
            .compactMap { offsetByID[rawItems[$0].id] }
        if filterQuery.isEmpty {
            visibleIndices = sortedIndices
        } else {
            visibleIndices = FilterEngine.filter(
                preparedNames: preparedNames,
                query: FilterEngine.prepare(filterQuery),
                style: filterStyle,
                candidates: sortedIndices
            )
        }
    }

    /// §6.6: the prepared (lowercased) name index lives next to `rawItems` so
    /// filter passes never re-create strings.
    private func rebuildNameIndex() {
        preparedNames.removeAll(keepingCapacity: true)
        preparedNames.reserveCapacity(rawItems.count)
        for item in rawItems {
            preparedNames.append(FilterEngine.prepare(item.name))
        }
    }

    /// Keeps the cursor in context (F-10): the element under the cursor keeps
    /// its row if it survived; otherwise the row index clamps into range.
    private func remapCursor(after oldOrder: [VFSItem]) {
        guard oldOrder.indices.contains(cursor) else {
            cursor = max(0, min(cursor, max(visibleCount - 1, 0)))
            return
        }
        let oldItem = oldOrder[cursor]
        if let newIndex = visibleIndices.firstIndex(where: { rawItems[$0].id == oldItem.id }) {
            cursor = newIndex
        } else {
            cursor = max(0, min(cursor, max(visibleCount - 1, 0)))
        }
    }

    /// Republishes a visibility change (filter strokes) as a table delta; an
    /// empty delta still notifies (the filter indicator lives in the status).
    private func publishVisibilityChange(from oldOrder: [VFSItem]) {
        let delta = DiffUpdate.diff(old: oldOrder, new: order())
        if delta.isEmpty {
            onContentsChanged?()
        } else {
            onContentsDelta?(delta)
        }
    }

    /// Consistent apply of engine-produced `DirectoryDiff` (docs/SDD/06 §6.3):
    /// merge by identity, recompute visibility, emit a row-start batch delta —
    /// NOT a full reload (F-1: «дифф-обновление списков (не полный reload)»).
    public func applyExternalDiff(_ diff: DirectoryDiff) {
        guard !diff.isEmpty else { return }
        let oldOrder = order()

        var mergedByID: [VFSPath: VFSItem] = [:]
        mergedByID.reserveCapacity(rawItems.count + diff.added.count)
        for item in rawItems where mergedByID[item.id] == nil {
            mergedByID[item.id] = item
        }
        for item in diff.removed { mergedByID.removeValue(forKey: item.id) }
        for item in diff.updated { mergedByID[item.id] = item }
        for item in diff.added { mergedByID[item.id] = item }

        rawItems = Array(mergedByID.values)
        rebuildNameIndex()
        recomputeVisibility()
        let delta = DiffUpdate.diff(old: oldOrder, new: order())

        // Cursor remaps by surviving identity; selection keeps identities and
        // prunes items vanished in the merge.
        remapCursor(after: oldOrder)
        selection.formIntersection(Set(rawItems.map(\.id)))

        if !delta.isEmpty {
            onContentsDelta?(delta)
        }
    }

    // MARK: watch loop

    private func restartWatch() {
        watchTask?.cancel()
        watchTask = nil
        guard let path, let engine = watchEngine else { return }
        let expectedPath = path
        watchTask = Task { [weak self] in
            let watchStream = engine.watch(expectedPath, options: WatchOptions())
            for await event in watchStream {
                guard let self else { return }
                guard case .itemsChanged(let diff) = event else { continue }
                guard self.path == expectedPath else { break }   // panel navigated away
                self.applyExternalDiff(diff)
            }
        }
    }

    private func order() -> [VFSItem] {
        visibleIndices.map { rawItems[$0] }
    }

    private func normalize(_ error: Error) -> MCError {
        error as? MCError ?? MCError.unexpected(underlying: error)
    }
}
