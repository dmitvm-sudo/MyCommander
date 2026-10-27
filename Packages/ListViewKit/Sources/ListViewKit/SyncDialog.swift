// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import EnginesKit

// Contract: docs/SDD/06 §6.6 (уточнение T-29) + F-15 — the sync dialog.
// DRY-RUN BY DEFAULT: the table IS the action-script log («действие → путь»),
// nothing is written until the user hits Apply AND confirms the NSAlert
// (acceptance: «подтверждение перед изменениями; лог скрипта действий»).
// Direction + mirror options recompute the script live via
// SyncReporter.actionScript; the App executes the returned script through
// the unified queue (per-run panel pairs, 05 §5.6 T-27).

@MainActor
final class SyncDialogController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let report: SyncReport
    private let nameA: String
    private let nameB: String
    private var actions: [SyncAction] = []
    var applyResult: [SyncAction]?

    private let directionPopup = NSPopUpButton()
    private let mirrorCheck = NSButton(checkboxWithTitle: String(localized: "sync.mirror"), target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()

    private enum ColumnID {
        static let action = NSUserInterfaceItemIdentifier("action")
        static let path = NSUserInterfaceItemIdentifier("path")
    }

    init(report: SyncReport, nameA: String, nameB: String) {
        self.report = report
        self.nameA = nameA
        self.nameB = nameB
        super.init()
        window.title = String(localized: "sync.title")
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("SyncDialogController is created programmatically only")
    }

    private func build() {
        directionPopup.addItems(withTitles: [
            String(localized: "sync.direction.aToB"),
            String(localized: "sync.direction.bToA")
        ])
        directionPopup.target = self
        directionPopup.action = #selector(optionChanged)
        mirrorCheck.target = self
        mirrorCheck.action = #selector(optionChanged)

        let summaryCounts = String(
            format: String(localized: "sync.countFormat"),
            report.count(.onlyA), report.count(.onlyB),
            report.count(.differing), report.count(.equal)
        )
        summaryLabel.stringValue = String(localized: "sync.summary \(summaryCounts)")

        let actionColumn = NSTableColumn(identifier: ColumnID.action)
        actionColumn.title = String(localized: "sync.column.action")
        actionColumn.width = 120
        let pathColumn = NSTableColumn(identifier: ColumnID.path)
        pathColumn.title = String(localized: "sync.column.path")
        pathColumn.width = 440
        table.addTableColumn(actionColumn)
        table.addTableColumn(pathColumn)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.setAccessibilityIdentifier("sync.script")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let applyButton = NSButton(title: String(localized: "sync.apply"), target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: String(localized: "sync.cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.orientation = .horizontal

        let optionsRow = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "sync.direction")),
            directionPopup,
            mirrorCheck,
            NSView()
        ])
        optionsRow.orientation = .horizontal

        let layout = NSStackView(views: [summaryLabel, optionsRow, scroll, buttons])
        layout.orientation = .vertical
        layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            layout.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: 300)
        ])
    }

    private var currentDirection: SyncDirection {
        directionPopup.indexOfSelectedItem == 1 ? .bToA : .aToB
    }

    /// Live recompute of the script (the dry run) — nothing writes here.
    private func refresh() {
        actions = SyncReporter.actionScript(from: report, direction: currentDirection, mirror: mirrorCheck.state == NSControl.StateValue.on)
        table.reloadData()
    }

    @objc private func optionChanged() {
        refresh()
    }

    // MARK: script table (the log)

    func numberOfRows(in tableView: NSTableView) -> Int {
        actions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = actions[row]
        let isPath = tableColumn?.identifier == ColumnID.path
        let text: String
        if isPath {
            text = action.relativePath
        } else {
            switch action.kind {
            case .copyAToB: text = String(localized: "sync.action.copyAToB")
            case .copyBToA: text = String(localized: "sync.action.copyBToA")
            case .deleteInA: text = String(localized: "sync.action.deleteInA")
            case .deleteInB: text = String(localized: "sync.action.deleteInB")
            }
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        switch action.kind {
        case .deleteInA, .deleteInB:
            cell.textColor = .systemRed   // mirror deletions must stand out
        default:
            break
        }
        return cell
    }

    // MARK: buttons

    @objc private func applyClicked() {
        guard !actions.isEmpty else { return }
        // F-15 acceptance: confirmation BEFORE any change touches the disks.
        let direction = currentDirection == .aToB ? nameA : nameB
        let target = currentDirection == .aToB ? nameB : nameA
        let alert = NSAlert()
        alert.messageText = String(localized: "sync.confirm.title")
        alert.informativeText = String(localized: "sync.confirm.body \(actions.count) \(direction) \(target)")
        alert.addButton(withTitle: String(localized: "sync.apply"))
        alert.addButton(withTitle: String(localized: "sync.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyResult = actions
        window.orderOut(nil)
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        applyResult = nil
        window.orderOut(nil)
        NSApp.stopModal()
    }
}

/// Static entry (ConflictDialog style): runs the dialog modally; returns the
/// confirmed action script or `nil` on cancel (dry run leaves everything).
@MainActor
public enum SyncDialog {
    public static func run(report: SyncReport, nameA: String, nameB: String) -> [SyncAction]? {
        let controller = SyncDialogController(report: report, nameA: nameA, nameB: nameB)
        controller.window.center()
        NSApp.runModal(for: controller.window)
        return controller.applyResult
    }
}
