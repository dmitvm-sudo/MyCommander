// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import EnginesKit

// Contract: docs/SDD/06 §6.6 (уточнение T-28) + F-14 — the multi-rename
// dialog: the rule block (template [N]/[C]/[E], replace/regex, case,
// extension, counter) + the LIVE preview table old→new (conflicts render
// red), Apply disabled while any conflict exists (acceptance: «конфликтующие
// результаты красным; отмена до commit; сухой прогон без записи» — the
// preview IS the dry run). Apply returns the built `.move` TransferPlan;
// the App executes it through the unified queue (undo rides the journal).

@MainActor
final class MultiRenameDialogController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let items: [VFSItem]
    private let occupiedNames: Set<String>

    // Rule fields.
    private let templateField = NSTextField(string: "[N]")
    private let findField = NSTextField()
    private let replacementField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: String(localized: "rename.regex"), target: nil, action: nil)
    private let casePopup = NSPopUpButton()
    private let extensionPopup = NSPopUpButton()
    private let extensionField = NSTextField()
    private let startField = NSTextField(string: "1")
    private let stepField = NSTextField(string: "1")
    private let padField = NSTextField(string: "0")

    // Preview.
    private let table = NSTableView()
    private var plan = RenamePlan(pairs: [], conflicts: [])
    private let applyButton = NSButton(title: String(localized: "rename.apply"), target: nil, action: nil)
    var applyResult: TransferPlan?
    private var modalContinuation: CheckedContinuation<Void, Never>?

    init(items: [VFSItem], occupiedNames: Set<String>) {
        self.items = items
        self.occupiedNames = occupiedNames
        super.init()
        window.title = String(localized: "rename.title")
        build()
        refreshPreview()
    }

    required init?(coder: NSCoder) {
        fatalError("MultiRenameDialogController is created programmatically only")
    }

    // MARK: build

    private func build() {
        // Rule rows.
        let templateLabel = NSTextField(labelWithString: String(localized: "rename.template"))
        templateField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let templateRow = NSStackView(views: [templateLabel, templateField])
        templateRow.orientation = .horizontal

        let findLabel = NSTextField(labelWithString: String(localized: "rename.find"))
        findField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        replacementField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let replaceRow = NSStackView(views: [findLabel, findField, replacementField, regexCheck])
        replaceRow.orientation = .horizontal

        casePopup.addItems(withTitles: [
            String(localized: "rename.case.unchanged"),
            String(localized: "rename.case.lowercase"),
            String(localized: "rename.case.uppercase"),
        ])
        let caseRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "rename.case")), casePopup])
        caseRow.orientation = .horizontal

        extensionPopup.addItems(withTitles: [
            String(localized: "rename.ext.keep"),
            String(localized: "rename.ext.replace"),
            String(localized: "rename.ext.remove"),
        ])
        extensionPopup.target = self
        extensionPopup.action = #selector(ruleChanged)
        let extensionRow = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "rename.ext")),
            extensionPopup,
            extensionField,
        ])
        extensionRow.orientation = .horizontal
        extensionField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let counterRow = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "rename.counter")),
            startField, stepField, padField,
        ])
        counterRow.orientation = .horizontal
        startField.placeholderString = String(localized: "rename.counter.start")
        stepField.placeholderString = String(localized: "rename.counter.step")
        padField.placeholderString = String(localized: "rename.counter.pad")

        // Preview table.
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("old"))
        nameColumn.title = String(localized: "rename.column.old")
        let newColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
        newColumn.title = String(localized: "rename.column.new")
        table.addTableColumn(nameColumn)
        table.addTableColumn(newColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.setAccessibilityIdentifier("multiRename.preview")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        let cancelButton = NSButton(title: String(localized: "rename.cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.orientation = .horizontal

        let layout = NSStackView(views: [templateRow, replaceRow, caseRow, extensionRow, counterRow, scroll, buttons])
        layout.orientation = .vertical
        layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -14),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14),
            layout.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -14),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])

        // Live preview on every rule edit.
        for field in [templateField, findField, replacementField, extensionField, startField, stepField, padField] {
            field.target = self
            field.action = #selector(ruleChanged)
        }
        regexCheck.target = self
        regexCheck.action = #selector(ruleChanged)
    }

    // MARK: rule → planner

    private var currentRule: RenameRule {
        let extMode: RenameExtensionMode
        switch extensionPopup.indexOfSelectedItem {
        case 1: extMode = .replace(extensionField.stringValue)
        case 2: extMode = .remove
        default: extMode = .keep
        }
        return RenameRule(
            template: templateField.stringValue,
            counterStart: Int(startField.stringValue) ?? 1,
            counterStep: Int(stepField.stringValue) ?? 1,
            counterPad: Int(padField.stringValue) ?? 0,
            find: findField.stringValue,
            replacement: replacementField.stringValue,
            isRegex: regexCheck.state == NSControl.StateValue.on,
            caseStyle: RenameCaseStyle.allCases[min(casePopup.indexOfSelectedItem, 2)],
            extensionMode: extMode
        )
    }

    @objc private func ruleChanged() {
        refreshPreview()
    }

    /// Pure planning pass (the dry run, F-14): rebuilds the plan and re-renders.
    func refreshPreview() {
        plan = RenamePlanner.plan(items: items, rule: currentRule, occupiedNames: occupiedNames)
        table.reloadData()
        applyButton.isEnabled = plan.isValid && !plan.pairs.isEmpty
    }

    // MARK: preview table

    func numberOfRows(in tableView: NSTableView) -> Int {
        plan.pairs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pair = plan.pairs[row]
        let isNew = tableColumn?.identifier.rawValue == "new"
        let text = isNew ? pair.newName : pair.item.name
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        if plan.conflicts.contains(where: { $0.index == row }) {
            cell.textColor = .systemRed   // F-14: конфликтующие результаты красным
        }
        return cell
    }

    // MARK: buttons

    @objc private func applyClicked() {
        guard plan.isValid, !plan.pairs.isEmpty, let parent = plan.pairs.first?.item.id.parent else { return }
        applyResult = RenamePlanner.buildTransferPlan(pairs: plan.pairs, in: parent)
        resumeCaller()
    }

    @objc private func cancelClicked() {
        applyResult = nil
        resumeCaller()
    }

    private func resumeCaller() {
        window.sheetParent?.endSheet(window)
        if let continuation = modalContinuation {
            modalContinuation = nil
            continuation.resume()
        }
        NSApp.stopModal()
    }
}

/// Static entry (PackDialog style): runs the dialog modally, returns the
/// committed plan or `nil` on cancel.
@MainActor
public enum MultiRenameDialog {
    public static func run(items: [VFSItem], occupiedNames: Set<String>) -> TransferPlan? {
        let controller = MultiRenameDialogController(items: items, occupiedNames: occupiedNames)
        controller.refreshPreview()
        let window = controller.window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return controller.applyResult
    }
}
