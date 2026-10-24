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

    /// Panel↔panel swap (⌘U «Swap Panels»): reconnect signals, reload.
    public func rebind(viewModel newViewModel: PanelViewModel) {
        viewModel.onContentsChanged = nil
        viewModel.onError = nil
        viewModel = newViewModel
        wireViewModel()
        tableView.reloadData()
        updateStatus()
    }

    // MARK: construction

    private func buildTableColumns() {
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.name.rawValue))
        nameColumn.title = String(localized: "column.name")
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.size.rawValue))
        sizeColumn.title = String(localized: "column.size")
        let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ColumnID.dateModified.rawValue))
        modifiedColumn.title = String(localized: "column.dateModified")

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(modifiedColumn)

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

        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView.onOpenRow = { [weak self] in self?.openUnderCursor() }
        tableView.onGoToParent = { [weak self] in
            guard let self else { return }
            self.onActivated?()
            Task { _ = await self.viewModel.goUp() }
        }
        tableView.target = self
        tableView.doubleAction = #selector(openDoubleClicked(_:))
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

    // MARK: status

    private func contentsChanged() {
        errorNote = nil
        tableView.reloadData()
        tableView.deselectAll(self)
        updateStatus()
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

/// NSTableView subclass; owns the panel keyboard semantics that AppKit does not
/// provide (Enter opens, ⌘↑ climbs). Everything else passes to super.
/// Public because `FileListView.listTableView` hands it to the App layer
/// (first-responder routing); its behaviours live in internal properties.
public final class PanelTableView: NSTableView {
    var onOpenRow: (() -> Void)?
    var onGoToParent: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.remove([.function, .capsLock, .numericPad, .shift])
        switch event.keyCode {
        case 36, 76:
            // Return / numeric Enter, no other modifiers.
            if modifiers.isEmpty {
                onOpenRow?()
                return
            }
        case 126:
            // ⌘↑ → parent directory.
            if modifiers == [.command] {
                onGoToParent?()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
