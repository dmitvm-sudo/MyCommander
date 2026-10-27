// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServicesKit

// Contract: docs/SDD/06 §6.9 (уточнение T-24) + F-13 — the non-modal reusable
// Connections window: list of records + editor form. Secrets never sit in
// fields that persist anywhere — the password/passphrase go straight into the
// ConnectionStore (Keychain). The App layer owns UI only; connection setup and
// host-key decisions live in PanelsCoordinator (via `onConnect`).

@MainActor
final class ConnectionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Fired by the «Connect» button; PanelsCoordinator performs the SFTP
    /// mount (host-key dialogs included).
    var onConnect: ((ConnectionRecord) -> Void)?

    private let store: ConnectionStore
    private var records: [ConnectionRecord] = []
    private var selectedID: UUID?

    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let authPopup = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let keyPathField = NSTextField()
    private let passphraseField = NSSecureTextField()
    private weak var keyRowStack: NSStackView?

    init(store: ConnectionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "connections.title")
        super.init(window: window)
        build(contentView: window.contentView ?? NSView())
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("ConnectionsWindowController is created programmatically only")
    }

    func activate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: build

    private func build(contentView: NSView) {
        // Records table.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = String(localized: "connections.column.name")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.setAccessibilityIdentifier("connections.list")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let addButton = NSButton(title: String(localized: "connections.add"), target: self, action: #selector(addRecord(_:)))
        addButton.controlSize = .small
        let deleteButton = NSButton(title: String(localized: "connections.delete"), target: self, action: #selector(deleteRecord(_:)))
        deleteButton.controlSize = .small
        let listRow = NSStackView(views: [scroll, NSStackView(views: [addButton, deleteButton])])
        listRow.orientation = .horizontal
        listRow.alignment = .top
        listRow.spacing = 8
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(equalToConstant: 130)])

        // Editor form.
        let nameRow = labeled(String(localized: "connections.name"), nameField)
        let hostRow = labeled(String(localized: "connections.host"), hostField)
        let portRow = labeled(String(localized: "connections.port"), portField)
        let userRow = labeled(String(localized: "connections.username"), userField)
        let authRow = labeled(String(localized: "connections.auth"), authPopup)
        authPopup.addItems(withTitles: [
            String(localized: "connections.auth.password"),
            String(localized: "connections.auth.privateKey")
        ])
        authPopup.target = self
        authPopup.action = #selector(authChanged(_:))

        passwordField.placeholderString = String(localized: "connections.password.placeholder")
        let keyBrowse = NSButton(title: String(localized: "connections.key.browse"), target: self, action: #selector(browseKey(_:)))
        keyBrowse.controlSize = .small
        let keyRow = labeled(String(localized: "connections.key"), keyPathField)
        keyRowStack = keyRow
        keyRow.arrangedSubviews.forEach { $0.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        keyRow.addArrangedSubview(keyBrowse)
        passphraseField.placeholderString = String(localized: "connections.passphrase.placeholder")
        let secretRows = NSStackView(views: [passwordField, keyRow, passphraseField])
        secretRows.orientation = .vertical
        secretRows.alignment = .leading
        secretRows.spacing = 6

        let editorStack = NSStackView(views: [nameRow, hostRow, portRow, userRow, authRow, secretRows])
        editorStack.orientation = .vertical
        editorStack.alignment = .leading
        editorStack.spacing = 6

        // Footer.
        let saveButton = NSButton(title: String(localized: "connections.save"), target: self, action: #selector(saveRecord(_:)))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        let connectButton = NSButton(title: String(localized: "connections.connect"), target: self, action: #selector(connectRecord(_:)))
        connectButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [saveButton, connectButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [listRow, editorStack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            nameField.widthAnchor.constraint(equalToConstant: 200),
            hostField.widthAnchor.constraint(equalToConstant: 200),
            portField.widthAnchor.constraint(equalToConstant: 70),
            userField.widthAnchor.constraint(equalToConstant: 200),
            keyPathField.widthAnchor.constraint(equalToConstant: 210)
        ])
        applyAuthVisibility()
    }

    private func labeled(_ title: String, _ field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: records list

    private func reload(selecting id: UUID? = nil) {
        records = store.records()
        tableView.reloadData()
        let target = id ?? selectedID
        if let target, let index = records.firstIndex(where: { $0.id == target }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            populate(record: records[index])
        } else {
            selectedID = nil
            clearForm()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: records[row].name)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard records.indices.contains(row) else { return }
        selectedID = records[row].id
        populate(record: records[row])
    }

    // MARK: form

    private func populate(record: ConnectionRecord) {
        nameField.stringValue = record.name
        hostField.stringValue = record.host
        portField.stringValue = String(record.port)
        userField.stringValue = record.username
        switch record.auth {
        case .password:
            authPopup.selectItem(at: 0)
        case .privateKey:
            authPopup.selectItem(at: 1)
        }
        applyAuthVisibility()
        // Secrets are not echoed back (Keychain-only by contract 06 §6.9).
        passwordField.stringValue = ""
        passphraseField.stringValue = ""
        keyPathField.stringValue = recordKeyPath(record)
    }

    private func recordKeyPath(_ record: ConnectionRecord) -> String {
        if case .privateKey(let path, _) = record.auth { return path }
        return ""
    }

    private func clearForm() {
        nameField.stringValue = ""
        hostField.stringValue = ""
        portField.stringValue = "22"
        userField.stringValue = ""
        authPopup.selectItem(at: 0)
        passwordField.stringValue = ""
        keyPathField.stringValue = ""
        passphraseField.stringValue = ""
        applyAuthVisibility()
    }

    private func applyAuthVisibility() {
        let isKey = authPopup.indexOfSelectedItem == 1
        passwordField.isHidden = isKey
        keyRowStack?.isHidden = !isKey
        passphraseField.isHidden = !isKey
    }

    /// The record assembled from the current form; `nil` on invalid input.
    private func formRecord(existing: ConnectionRecord?) -> ConnectionRecord? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !host.isEmpty, !user.isEmpty,
              let port = Int(portField.stringValue), (1 ... 65_535).contains(port)
        else { return nil }
        var record = existing ?? ConnectionRecord(name: name, host: host, username: user)
        record.name = name
        record.host = host
        record.port = port
        record.username = user
        switch authPopup.indexOfSelectedItem {
        case 1:
            let path = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            record.auth = .privateKey(
                path: path,
                passphraseRef: passphraseField.stringValue.isEmpty ? nil : record.id.uuidString
            )
        default:
            record.auth = .password(keychainRef: record.id.uuidString)
        }
        return record
    }

    // MARK: actions

    @objc private func addRecord(_ sender: Any) {
        let record = ConnectionRecord(
            name: String(localized: "connections.untitled"),
            host: "",
            username: ""
        )
        store.save(record)
        selectedID = record.id
        reload(selecting: record.id)
    }

    @objc private func deleteRecord(_ sender: Any) {
        guard let id = selectedID else { return }
        store.delete(id: id)
        selectedID = nil
        reload()
    }

    @objc private func saveRecord(_ sender: Any) {
        guard let existing = selectedID.flatMap({ store.record(id: $0) }) else { return }
        guard let record = formRecord(existing: existing) else { return }
        store.save(record)
        // Secrets update only when the user typed something (no echo policy).
        if !passwordField.stringValue.isEmpty { store.setPassword(passwordField.stringValue, for: record.id) }
        if !passphraseField.stringValue.isEmpty { store.setPassphrase(passphraseField.stringValue, for: record.id) }
        reload(selecting: record.id)
    }

    @objc private func connectRecord(_ sender: Any) {
        guard let existing = selectedID.flatMap({ store.record(id: $0) }) else { return }
        guard let record = formRecord(existing: existing) else { return }
        store.save(record)
        onConnect?(record)
    }

    @objc private func authChanged(_ sender: Any) {
        applyAuthVisibility()
    }

    @objc private func browseKey(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyPathField.stringValue = url.path
    }
}
