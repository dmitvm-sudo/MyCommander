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

    public private(set) var viewModel: PanelViewModel
    private let iconCache: ItemCache
    private let scrollView = NSScrollView()
    private let tableView = PanelTableView()
    private let statusLine = NSTextField(labelWithString: "")
    private var errorNote: String?
    /// Columns are pre-built once; the view mode (F-4) only attaches/detaches
    /// the meta columns to the table.
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.name.rawValue))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.size.rawValue))
    private let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.dateModified.rawValue))

    /// Escalated for the owner only: first-responder routing and focus visuals.
    public var listTableView: PanelTableView {
        tableView
    }

    /// User interaction happened in this panel (click/keys) — the owner uses it
    /// to route active-panel focus (`FocusController`).
    public var onActivated: (() -> Void)?

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
    }

    /// F-4 (start): full — name + size + date columns; brief — names only
    /// (maximum density). No column rebuild costs: pre-built columns are
    /// attached/detached.
    private func applyViewMode(animating: Bool) {
        let isFull = viewModel.viewMode == .full
        let metaColumns = [sizeColumn, modifiedColumn]
        if isFull {
            for column in metaColumns where tableView.tableColumns.firstIndex(of: column) == nil {
                tableView.addTableColumn(column)
            }
        } else {
            for column in metaColumns where tableView.tableColumns.firstIndex(of: column) != nil {
                tableView.removeTableColumn(column)
            }
        }
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
        statusLine.stringValue = parts.joined(separator: "   ·   ")
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
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.size.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.sizeText(of: item), alignment: .right)
            return cell
        }
        if column.identifier == NSUserInterfaceItemIdentifier(ColumnID.dateModified.rawValue) {
            let cell = tableView.makeView(withIdentifier: MetaCell.reuseIdentifier, owner: self) as? MetaCell
                ?? MetaCell()
            cell.render(text: MetaCell.modifiedText(of: item), alignment: .left)
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
