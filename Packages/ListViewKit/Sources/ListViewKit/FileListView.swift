// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit

/// One panel (docs/SDD/06 §6.1 structure without the tabs page, which arrives
/// with T-08): an `NSTableView` (view-based, constant rowHeight, cell reuse) over
/// `PanelViewModel` plus a status line (path · «n of m selected» · last error).
///
/// Perf contract (§6.1): no autoresizing rows; `NameCell`/`MetaCell` reuse via
/// `makeView`; icons funnel through `ItemCache`'s LRU. Listing changes come in
/// via `onContentsChanged` and reload wholesale; diff batching is T-06.
@MainActor
public final class FileListView: NSView {
    public static let rowHeight: CGFloat = 22
    /// Thumbnails mode (⌃4) carries a 40×40 image inside a taller row (06
    /// §6.1 «Уточнение T-32»).
    public static let thumbnailRowHeight: CGFloat = 56

    public private(set) var viewModel: PanelViewModel
    private let iconCache: ItemCache
    private let scrollView = NSScrollView()
    private let tableView = PanelTableView()
    private let statusLine = NSTextField(labelWithString: "")
    private var errorNote: String?
    /// Columns are pre-built once; the view mode (F-4) only attaches/detaches
    /// the meta columns to the table. T-32 adds the custom-column set (⌃3) and
    /// the thumbnail column (⌃4) — 06 §6.1 «Уточнение T-32».
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.name.rawValue))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.size.rawValue))
    private let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.dateModified.rawValue))
    private let createdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.dateCreated.rawValue))
    private let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.kind.rawValue))
    private let tagsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.tags.rawValue))
    private let permissionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.permissions.rawValue))
    private let ownerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.owner.rawValue))
    /// The thumbnails column is NOT a `ColumnID` case — the mode itself (⌃4)
    /// decides when it appears; the settings columns[] presets never list it.
    private let thumbnailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumbnail"))

    /// Escalated for the owner only: first-responder routing and focus visuals.
    public var listTableView: PanelTableView {
        tableView
    }

    /// User interaction happened in this panel (click/keys) — the owner uses it
    /// to route active-panel focus (`FocusController`).
    public var onActivated: (() -> Void)?

    /// DnD source hook (§6.1 v1 — T-16, F-18): the App layer builds the
    /// `NSPasteboardItem` for one dragged row (file URL + VFSPath payload);
    /// returning `nil` drops the row out of the drag (non-local sources).
    public var onPasteboardWriterForRow: (@MainActor (Int) -> (any NSPasteboardWriting)?)?

    /// DnD destination hook: the panel accepted a drop. `isInternal` = the
    /// source was a FileListView of this app (panel↔panel), `wantsCopy`
    /// honours the ⌥ modifier for internal drags; Finder drags are always
    /// copy (the App planner decides from the payload kinds).
    public var onDropReceived: (@MainActor (
        _ urls: [URL],
        _ paths: [VFSPath],
        _ isInternal: Bool,
        _ wantsCopy: Bool
    ) -> Void)?

    /// Access-mode badge (F-20 / T-17): nil hides the row; otherwise the App
    /// passes a localized short label («FDA» / «SAFE …») appended to the
    /// status line.
    public var accessBadge: String? {
        didSet { updateStatus() }
    }

    /// Current status line text (path · selection · filter · error · badge) —
    /// exposed for tests and observable status assertions.
    public var statusText: String {
        statusLine.stringValue
    }

    public init(viewModel: PanelViewModel, iconCache: ItemCache = ItemCache()) {
        self.viewModel = viewModel
        self.iconCache = iconCache
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        wantsLayer = true
        buildTableColumns()
        buildLayout()
        wireViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("FileListView is created programmatically only")
    }

    /// Panel↔panel swap (⌘U «Swap Panels») and tab switching (F-2):
    /// reconnect signals, reload, restore the tab's row selection and scroll
    /// the cursor back into view.
    public func rebind(viewModel newViewModel: PanelViewModel) {
        viewModel.onContentsChanged = nil
        viewModel.onContentsDelta = nil
        viewModel.onError = nil
        viewModel = newViewModel
        wireViewModel()
        tableView.reloadData()
        applyViewMode(animating: false)
        syncTableSelection()
        if viewModel.visibleCount > 0 {
            tableView.scrollRowToVisible(min(viewModel.cursor, viewModel.visibleCount - 1))
        }
        updateStatus()
    }

    // MARK: construction

    private func buildTableColumns() {
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true

        nameColumn.title = String(localized: "column.name")
        sizeColumn.title = String(localized: "column.size")
        modifiedColumn.title = String(localized: "column.dateModified")
        createdColumn.title = String(localized: "column.dateCreated")
        kindColumn.title = String(localized: "column.kind")
        tagsColumn.title = String(localized: "column.tags")
        permissionsColumn.title = String(localized: "column.permissions")
        ownerColumn.title = String(localized: "column.owner")
        thumbnailColumn.title = String(localized: "column.thumbnails")

        nameColumn.width = 320
        nameColumn.minWidth = 120
        nameColumn.maxWidth = 900
        nameColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        sizeColumn.width = 90
        sizeColumn.minWidth = 60
        sizeColumn.resizingMask = [.userResizingMask]
        modifiedColumn.width = 156
        modifiedColumn.minWidth = 110
        modifiedColumn.resizingMask = [.userResizingMask]
        createdColumn.width = 156
        createdColumn.minWidth = 110
        createdColumn.resizingMask = [.userResizingMask]
        kindColumn.width = 130
        kindColumn.minWidth = 70
        kindColumn.resizingMask = [.userResizingMask]
        tagsColumn.width = 120
        tagsColumn.minWidth = 60
        tagsColumn.resizingMask = [.userResizingMask]
        permissionsColumn.width = 70
        permissionsColumn.minWidth = 50
        permissionsColumn.resizingMask = [.userResizingMask]
        ownerColumn.width = 90
        ownerColumn.minWidth = 50
        ownerColumn.resizingMask = [.userResizingMask]
        thumbnailColumn.width = 56
        thumbnailColumn.minWidth = 40

        tableView.addTableColumn(nameColumn)
        applyViewMode(animating: false)

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView.onKeyCommand = { [weak self] in self?.handleKeyCommand($0) }
        tableView.target = self
        tableView.doubleAction = #selector(openDoubleClicked(_:))

        // F-18 (T-16): the whole panel is the drop target («домашняя панель —
        // дефолт-цель»), the row drag goes through the data-source writer.
        registerForDraggedTypes(DragBridge.acceptedTypes)
    }

    // MARK: view modes (F-4 — 06 §6.1 «Уточнение T-32»)

    /// The columns-mode preset (⌃3), fed live from the settings store through
    /// `applyColumnPreset`. `name` is always the first rendered column; only
    /// renderable `ColumnID`s survive (`gitStatus` awaits F-27 providers).
    private var columnPreset: [ColumnID] = [.name, .size, .dateModified]

    /// A change of the configured set (F-21 live apply): sanitize, remember,
    /// and re-run the columns mode if it is active.
    public func applyColumnPreset(_ preset: [ColumnID]) {
        var sanitized: [ColumnID] = []
        for column in preset where column != .gitStatus && !sanitized.contains(column) {
            sanitized.append(column)
        }
        sanitized.removeAll { $0 == .name }
        columnPreset = [.name] + sanitized
        if viewModel.viewMode == .columns {
            applyViewMode(animating: false)
        }
    }

    /// Attach/detach columns per view mode — pre-built only, no rebuild
    /// costs: a mode change is the `setDisplayedColumns` diff.
    private func applyViewMode(animating: Bool) {
        let identifiers: [String]
        switch viewModel.viewMode {
        case .brief:
            identifiers = [ColumnID.name.rawValue]
        case .full:
            identifiers = [ColumnID.name.rawValue, ColumnID.size.rawValue, ColumnID.dateModified.rawValue]
        case .columns:
            identifiers = columnPreset.map(\.rawValue)
        case .thumbnails:
            identifiers = [ColumnID.name.rawValue, "thumbnail"]
        }
        setDisplayedColumns(identifiers)
        let rowHeight: CGFloat = viewModel.viewMode == .thumbnails
            ? Self.thumbnailRowHeight
            : Self.rowHeight
        if tableView.rowHeight != rowHeight {
            tableView.rowHeight = rowHeight
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0 ..< tableView.numberOfRows)
            )
        }
        // Leaving the thumbnails mode drops the in-flight generation list so
        // a hidden store cannot keep generating for an unseen table.
        if viewModel.viewMode != .thumbnails {
            thumbnailStore?.cancelPending()
        }
    }

    /// The desired identifier order diffed against the live table: extras are
    /// removed, missing ones attached, then the order fixed with
    /// `moveTableColumn(_:to:)` (all columns pre-built, docs/SDD/06 §6.1).
    private func setDisplayedColumns(_ identifiers: [String]) {
        let live = tableView.tableColumns
        for column in live
        where !identifiers.contains(column.identifier.rawValue) {
            tableView.removeTableColumn(column)
        }
        for identifier in identifiers
        where tableView.tableColumns.allSatisfy({ $0.identifier.rawValue != identifier }) {
            guard let column = column(for: identifier) else { continue }
            tableView.addTableColumn(column)
        }
        for (targetIndex, identifier) in identifiers.enumerated() {
            guard let liveColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == identifier
            }) else { continue }
            let currentIndex = tableView.column(withIdentifier: liveColumn.identifier)
            if currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }
    }

    private func column(for identifier: String) -> NSTableColumn? {
        switch identifier {
        case ColumnID.name.rawValue: return nameColumn
        case ColumnID.size.rawValue: return sizeColumn
        case ColumnID.dateModified.rawValue: return modifiedColumn
        case ColumnID.dateCreated.rawValue: return createdColumn
        case ColumnID.kind.rawValue: return kindColumn
        case ColumnID.tags.rawValue: return tagsColumn
        case ColumnID.permissions.rawValue: return permissionsColumn
        case ColumnID.owner.rawValue: return ownerColumn
        case "thumbnail": return thumbnailColumn
        default: return nil
        }
    }

    // MARK: thumbnails (⌃4 — T-32)

    private var thumbnailStore: ThumbnailStore?

    /// The store materialises at the first thumbnails request; the callback
    /// re-renders the matching cacheKey-holder row.
    private func thumbnailStoreIfNeeded() -> ThumbnailStore {
        if let thumbnailStore { return thumbnailStore }
        let store = ThumbnailStore()
        store.onThumbnailUpdated = { [weak self] key in
            self?.reloadRow(forThumbnailKey: key)
        }
        thumbnailStore = store
        return store
    }

    /// The async generation for `key` finished → find the visible row that
    /// displays exactly this item (identity guard via the requested cacheKey)
    /// and reload only its thumbnail column. Mode/identity drift (row reused
    /// for another item, mode left) renders the update a no-op.
    private func reloadRow(forThumbnailKey key: String) {
        guard viewModel.viewMode == .thumbnails else { return }
        let visibleRows = Range(tableView.rows(in: tableView.visibleRect))
        guard let range = visibleRows else { return }
        for row in range {
            guard let item = viewModel.item(atVisibleIndex: row),
                  item.id.root.kind == .localDisk,
                  ThumbnailStore.cacheKey(for: item.id, pixelSize: thumbnailPixelSize) == key
            else { continue }
            if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "thumbnail" }) {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: IndexSet(integer: tableView.column(withIdentifier: column.identifier))
                )
            }
            return
        }
    }

    private var thumbnailPixelSize: CGSize {
        CGSize(width: 40, height: 40)
    }

    private func buildLayout() {
        statusLine.font = NSFont.systemFont(ofSize: 11)
        statusLine.textColor = .secondaryLabelColor
        statusLine.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [scrollView, statusLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func wireViewModel() {
        viewModel.onContentsChanged = { [weak self] in self?.contentsChanged() }
        viewModel.onContentsDelta = { [weak self] delta in self?.contentsDelta(delta) }
        viewModel.onError = { [weak self] error in
            guard let self else { return }
            self.errorNote = (error as LocalizedError).errorDescription ?? String(describing: error)
            self.updateStatus()
        }
        updateStatus()
    }

    // MARK: actions

    private func openUnderCursor() {
        onActivated?()
        let row = tableView.selectedRow == -1 ? viewModel.cursor : tableView.selectedRow
        openUnderRow(row)
    }

    private func openUnderRow(_ row: Int) {
        guard row != -1 else { return }
        Task { await viewModel.openItem(atVisibleIndex: row) }
    }

    @objc private func openDoubleClicked(_ sender: Any?) {
        openUnderRow(tableView.clickedRow)
    }

    /// Single interpretation point of the panel keyboard (F-1/F-3/F-10, F-4):
    /// the classifier produced the intent, the view model executes it, and the
    /// table selection mirrors back through `syncTableSelection`.
    private func handleKeyCommand(_ command: PanelKeyCommand) {
        switch command {
        case .acceptOrOpen:
            if viewModel.isFilterActive {
                onActivated?()
                viewModel.acceptFilter()
                syncTableSelection()
                updateStatus()
            } else {
                openUnderCursor()
            }
        case .goToParent:
            onActivated?()
            Task { _ = await viewModel.goUp() }
        case .toggleSelectionAndMove:
            onActivated?()
            viewModel.toggleSelectionUnderCursorAndMove()
            syncTableSelection()
            updateStatus()
        case .selectMasked:
            onActivated?()
            viewModel.selectAll()
            syncTableSelection()
            updateStatus()
        case .deselectMasked:
            onActivated?()
            viewModel.deselectAll()
            syncTableSelection()
            updateStatus()
        case .invertAll:
            onActivated?()
            viewModel.invertAll()
            syncTableSelection()
            updateStatus()
        case .restoreSelection:
            onActivated?()
            viewModel.restoreSelection()
            syncTableSelection()
            updateStatus()
        case .filterCharacter(let character):
            onActivated?()
            viewModel.appendFilterCharacter(character)
        case .backspace:
            onActivated?()
            if viewModel.isFilterActive {
                viewModel.deleteLastFilterCharacter()
            } else {
                Task { _ = await viewModel.goUp() }
            }
        case .escape:
            guard viewModel.isFilterActive else { return }
            viewModel.clearFilter()
        case .viewFull:
            onActivated?()
            viewModel.setViewMode(.full)
        case .viewBrief:
            onActivated?()
            viewModel.setViewMode(.brief)
        case .viewColumns:
            onActivated?()
            viewModel.setViewMode(.columns)
        case .viewThumbnails:
            onActivated?()
            viewModel.setViewMode(.thumbnails)
        case .passToSuper:
            break   // unreachable: the table already filtered these out
        }
    }

    // MARK: status

    private func contentsChanged() {
        errorNote = nil
        applyViewMode(animating: false)
        tableView.reloadData()
        tableView.deselectAll(self)
        updateStatus()
    }

    /// Batch application of a watch-engine delta (docs/SDD/06 §6.1): begin →
    /// remove (old positions) → insert (new positions) → reload → end. Falls
    /// back to a full reload if the table's row count no longer matches `oldCount`.
    private func contentsDelta(_ delta: FileListDelta) {
        errorNote = nil
        guard delta.isValidAgainst(rowCount: tableView.numberOfRows) else {
            contentsChanged()
            return
        }
        if !delta.isEmpty {
            tableView.beginUpdates()
            if !delta.removed.isEmpty {
                tableView.removeRows(at: IndexSet(delta.removed), withAnimation: .effectFade)
            }
            if !delta.inserted.isEmpty {
                tableView.insertRows(at: IndexSet(delta.inserted), withAnimation: .effectFade)
            }
            if !delta.updated.isEmpty {
                tableView.reloadData(
                    forRowIndexes: IndexSet(delta.updated),
                    columnIndexes: IndexSet(integersIn: 0 ..< max(tableView.numberOfColumns, 1))
                )
            }
            tableView.endUpdates()
        }
        syncTableSelection()
        updateStatus()
    }

    /// Restores the view's row-level selection from identity-based vm.selection
    /// (after inserts/removes the previous indexes no longer match).
    private func syncTableSelection() {
        var indexes = IndexSet()
        for row in 0 ..< viewModel.visibleCount {
            if let item = viewModel.item(atVisibleIndex: row), viewModel.selection.contains(item.id) {
                indexes.insert(row)
            }
        }
        guard indexes != tableView.selectedRowIndexes else { return }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func updateStatus() {
        var pathText = "/"
        if let components = viewModel.path?.components, !components.isEmpty {
            pathText = "/" + components.joined(separator: "/")
        }
        let selectionText = String(
            localized: "\(viewModel.selectedCount) of \(viewModel.visibleCount) selected"
        )
        var parts = [pathText, selectionText]
        // F-10: the active filter is always visible in the status line.
        if viewModel.isFilterActive {
            parts.append(String(localized: "panel.status.filter \(viewModel.filterQuery)"))
        }
        if let errorNote {
            parts.append(String(localized: "panel.status.error \(errorNote)"))
        }
        // F-20 (T-17): the access mode is always visible in the status line.
        if let accessBadge {
            parts.append(accessBadge)
        }
        statusLine.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: settings live-apply (§6.9 v1, T-18)

    /// Current panel font (from the settings); `nil` = module defaults.
    private var panelFont: NSFont?

    /// Panel font from the settings (F-21 MVP): nil = module defaults. The
    /// visible rows re-render (reused cells take the new face).
    public func applyPanelFont(_ font: NSFont?) {
        guard panelFont != font else { return }
        panelFont = font
        let visibleRows = Range(tableView.rows(in: tableView.visibleRect)).map { IndexSet(integersIn: $0) } ?? IndexSet()
        let allColumns = IndexSet(integersIn: 0 ..< max(tableView.numberOfColumns, 1))
        tableView.reloadData(forRowIndexes: visibleRows, columnIndexes: allColumns)
    }
}

// MARK: NSTableView plumbing

extension FileListView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.visibleCount
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = viewModel.item(atVisibleIndex: row), let column = tableColumn else { return nil }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.name.rawValue) {
            let cell = tableView.makeView(withIdentifier: NameCell.reuseIdentifier, owner: self) as? NameCell
                ?? NameCell()
            cell.render(item: item, icon: iconCache.icon(for: item))
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.size.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.sizeText(of: item), alignment: .right)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.dateModified.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.modifiedText(of: item), alignment: .left)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.dateCreated.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.createdText(of: item), alignment: .left)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.kind.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.kindText(of: item), alignment: .left)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.tags.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.tagsText(of: item), alignment: .left)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.permissions.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.permissionsText(of: item), alignment: .right)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.owner.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.ownerText(of: item), alignment: .left)
            cell.applyPanelFont(panelFont)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier("thumbnail") {
            let cell = tableView.makeView(withIdentifier: ThumbnailCell.reuseIdentifier, owner: self)
                as? ThumbnailCell ?? ThumbnailCell()
            let key = ThumbnailStore.cacheKey(for: item.id, pixelSize: thumbnailPixelSize)
            let image = thumbnailStoreIfNeeded().thumbnail(for: item, pixelSize: thumbnailPixelSize)
            cell.render(image: image, key: key)
            return cell
        }
        return nil
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        onActivated?()
        let paths = Set(tableView.selectedRowIndexes.compactMap { viewModel.item(atVisibleIndex: $0)?.id })
        viewModel.setCursor(tableView.selectedRow)
        viewModel.setSelection(paths)
        updateStatus()
    }

    /// Modern drag source: per-row `NSPasteboardWriting` from the App hook
    /// (`onPasteboardWriterForRow`). Rows without a writer are skipped; if no
    /// row produces one, NSTableView does not start a drag at all.
    public func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow rowIndex: Int
    ) -> (any NSPasteboardWriting)? {
        onPasteboardWriterForRow?(rowIndex)
    }
}

// MARK: Drag destination (T-16 / F-18 — §6.1 v1)

/// держится в `NSApp.currentEvent` (NSDraggingInfo не отдаёт событие).
extension FileListView {
    /// Self-drop (drag started in this very panel) is refused; a drag from
    /// *another* panel proposes move (⌥ = copy); Finder drags are copy.
    private func dragOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        if let source = info.draggingSource as? FileListView, source === self {
            return NSDragOperation()
        }
        let isInternal = info.draggingSource is FileListView
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(NSEvent.ModifierFlags.option) == true
        let proposed: NSDragOperation = isInternal
            ? (optionHeld ? .copy : .move)
            : .copy
        // Keep the panel-item/fileURL contract: only genuinely accepted kinds.
        let pasteboard = info.draggingPasteboard
        let isPanelPayload = pasteboard.data(forType: DragBridge.itemType) != nil
        let isFileURLPayload = pasteboard.data(forType: .fileURL) != nil
        if !isPanelPayload, !isFileURLPayload {
            return NSDragOperation()
        }
        return proposed
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let operation = dragOperation(for: sender)
        guard operation != NSDragOperation() else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = DragBridge.readURLs(pasteboard)
        let paths = DragBridge.readPaths(pasteboard)
        guard !urls.isEmpty || !paths.isEmpty else { return false }
        let isInternal = sender.draggingSource is FileListView
        let wantsCopy = isInternal && operation == .copy
        onDropReceived?(urls, paths, isInternal, wantsCopy)
        return true
    }
}

/// NSTableView subclass; routes keys through the testable classifier
/// (`PanelKeys`) — everything unclaimed falls through to AppKit.
/// Public because `FileListView.listTableView` hands it to the App layer
/// (first-responder routing); its behaviours live in internal properties.
public final class PanelTableView: NSTableView {
    var onKeyCommand: ((PanelKeyCommand) -> Void)?

    public override func keyDown(with event: NSEvent) {
        let command = PanelKeys.classify(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters
        )
        if case .passToSuper = command {
            super.keyDown(with: event)
        } else {
            onKeyCommand?(command)
        }
    }
}
