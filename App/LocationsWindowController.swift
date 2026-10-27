// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import ServicesKit

// Contract: docs/SDD/06 §6.9 (уточнение T-26) + F-11 — the non-modal Locations
// window: bookmarks (⌘D-made + manual), hotlist slots and recent folders.
// Navigation requests ride `onNavigate` (PanelsCoordinator resolves targets,
// including `.connection` → the SFTP connect flow); slot assignment and
// deletion go straight to the store, `onChanged` re-renders the menu.

@MainActor
final class LocationsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onNavigate: ((LocationTarget) -> Void)?
    var onChanged: (() -> Void)?

    private let store: LocationsStore
    private var bookmarks: [LocationBookmark] = []
    private var recents: [VFSPath] = []

    private let bookmarkTable = NSTableView()
    private let recentsTable = NSTableView()
    private let slotPopup = NSPopUpButton()

    init(store: LocationsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "locations.title")
        super.init(window: window)
        build(contentView: window.contentView ?? NSView())
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("LocationsWindowController is created programmatically only")
    }

    func activate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: build

    private func makeTable(_ table: NSTableView) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = String(localized: "locations.column.name")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func build(contentView: NSView) {
        let bookmarkScroll = makeTable(bookmarkTable)
        bookmarkTable.setAccessibilityIdentifier("locations.bookmarks")
        let recentsScroll = makeTable(recentsTable)
        recentsTable.setAccessibilityIdentifier("locations.recents")

        let goButton = NSButton(title: String(localized: "locations.go"), target: self, action: #selector(goSelected(_:)))
        goButton.keyEquivalent = "\r"
        let deleteButton = NSButton(title: String(localized: "locations.delete"), target: self, action: #selector(deleteSelected(_:)))
        let slotLabel = NSTextField(labelWithString: String(localized: "locations.slot"))
        slotPopup.addItems(withTitles: [
            String(localized: "locations.slot.none"),
            "1", "2", "3", "4", "5", "6", "7", "8", "9"
        ])
        slotPopup.target = self
        slotPopup.action = #selector(slotChanged(_:))
        let controls = NSStackView(views: [goButton, deleteButton, slotLabel, slotPopup])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let recentsHeading = NSTextField(labelWithString: String(localized: "locations.recents"))
        recentsHeading.font = NSFont.boldSystemFont(ofSize: 12)

        let stack = NSStackView(views: [bookmarkScroll, controls, recentsHeading, recentsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            bookmarkScroll.heightAnchor.constraint(equalToConstant: 150),
            recentsScroll.heightAnchor.constraint(equalToConstant: 110),
            bookmarkScroll.widthAnchor.constraint(equalTo: recentsScroll.widthAnchor)
        ])
    }

    // MARK: data

    private func reload() {
        bookmarks = store.bookmarks()
        recents = store.recentFolders()
        bookmarkTable.reloadData()
        recentsTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === bookmarkTable ? bookmarks.count : recents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === bookmarkTable {
            let bookmark = bookmarks[row]
            text = bookmark.hotSlot.map { "[\($0)] \(bookmark.name)" } ?? bookmark.name
        } else {
            text = recents[row].displayURL?.path ?? "/" + recents[row].components.joined(separator: "/")
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    /// Syncs the slot popup with the selected bookmark.
    func tableViewSelectionDidChange(_ notification: Notification) {
        syncSlotPopup()
    }

    private var selectedBookmark: LocationBookmark? {
        let row = bookmarkTable.selectedRow
        return bookmarks.indices.contains(row) ? bookmarks[row] : nil
    }

    private func syncSlotPopup() {
        let slot = selectedBookmark?.hotSlot
        slotPopup.selectItem(at: slot ?? 0)   // 0 = «no slot»
    }

    // MARK: actions

    @objc private func goSelected(_ sender: Any) {
        if let bookmark = selectedBookmark {
            onNavigate?(bookmark.target)
            return
        }
        let row = recentsTable.selectedRow
        if recents.indices.contains(row) {
            onNavigate?(.path(recents[row]))
        }
    }

    @objc private func deleteSelected(_ sender: Any) {
        guard let bookmark = selectedBookmark else { return }
        store.remove(id: bookmark.id)
        reload()
        onChanged?()
    }

    @objc private func slotChanged(_ sender: Any) {
        guard let bookmark = selectedBookmark else { return }
        let slot = slotPopup.indexOfSelectedItem
        if slot == 0 {
            if let current = bookmark.hotSlot {
                store.clearHotSlot(current)
            }
        } else {
            store.assignHotSlot(slot, for: bookmark.id)
        }
        reload()
        onChanged?()
    }
}
