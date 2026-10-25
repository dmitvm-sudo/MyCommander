// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import FileOpsKit
import Foundation

// Contract: docs/SDD/06 §6.2 layer 2 «ConflictResolver» — UI-диалог по списку
// конфликтов: превью (размеры, даты), policy-выбор per-item/all; и docs/SDD/02
// F-5 «Конфликты: диалог с превью (размер/даты), выбор per-file или all;
// отчёт по завершении (ok/skip/fail/причины)».

/// Event-driven accumulator of the operation report (ok/skip/fail + failure
/// reasons). Pure value type — testable without AppKit; the progress window
/// renders it.
public struct OperationReport: Sendable {
    public private(set) var succeeded = 0
    public private(set) var skipped = 0
    public private(set) var failed = 0
    public private(set) var canceled = false
    public private(set) var reasons: [String] = []

    public init() {}

    public mutating func record(_ event: TransferEvent) {
        switch event.phase {
        case .itemFailed(let error):
            failed += 1
            reasons.append(error.errorDescription ?? String(describing: error))
        case .finished(let summary):
            succeeded = summary.succeededItems
            skipped = summary.skippedItems
            canceled = summary.canceled
            if reasons.count < summary.failedItems {
                reasons.append(contentsOf: Array(repeating: "—", count: summary.failedItems - reasons.count))
            }
        default:
            break
        }
    }

    /// «3 ok · 1 skipped · 2 failed» (localized).
    public var summaryLine: String {
        String(localized: "report.summary \(succeeded) \(skipped) \(failed)")
    }

    /// Failure reasons, one line each (F-5 «отчёт… причины»).
    public var reasonLines: [String] {
        reasons.map { String(localized: "report.reason \($0)") }
    }
}

/// Formats one preview side: «1.2 MB · 25.10.2026 14:03».
@MainActor
func conflictPreviewText(_ item: VFSItem?) -> String {
    guard let item else { return String(localized: "conflict.preview.absent") }
    var parts: [String] = []
    if let size = item.attributes.size {
        parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }
    if let modified = item.attributes.modified {
        parts.append(DateFormatter.localizedString(from: modified, dateStyle: .short, timeStyle: .short))
    }
    if case .directory = item.kind {
        parts.insert(String(localized: "conflict.preview.folder"), at: 0)
    }
    return parts.isEmpty ? item.name : parts.joined(separator: " · ")
}

/// The conflict dialog (T-12): preview table + per-item resolution popups +
/// «apply to all» buttons. Returns the built ConflictPolicy, or `nil` when the
/// user cancelled (the operation is not started).
@MainActor
public final class ConflictDialogController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [ConflictPreviewRow]
    private var resolutions: [ConflictResolution]
    private var applyToAllChoice: ConflictResolution?
    private let tableView = NSTableView()
    private let continueButton = NSButton()

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let source = NSUserInterfaceItemIdentifier("source")
        static let target = NSUserInterfaceItemIdentifier("target")
        static let resolution = NSUserInterfaceItemIdentifier("resolution")
    }

    init(rows: [ConflictPreviewRow]) {
        self.rows = rows
        self.resolutions = Array(repeating: .keepBoth, count: rows.count)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: CGFloat(min(480, 120 + 44 * max(rows.count, 1)))),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "conflict.title")
        super.init(window: window)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        for (identifier, titleKey) in [
            (ColumnID.name, "conflict.column.name"),
            (ColumnID.source, "conflict.column.source"),
            (ColumnID.target, "conflict.column.target"),
            (ColumnID.resolution, "conflict.column.resolution"),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = String(localized: String.LocalizationValue(titleKey))
            column.width = identifier == ColumnID.name ? 180 : 150
            tableView.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // «Apply to all» (F-5): sets every row and the policy default.
        let allOverwrite = NSButton(title: String(localized: "conflict.all.overwrite"), target: self, action: #selector(allOverwriteClicked))
        allOverwrite.bezelStyle = .rounded
        let allSkip = NSButton(title: String(localized: "conflict.all.skip"), target: self, action: #selector(allSkipClicked))
        allSkip.bezelStyle = .rounded
        let allKeepBoth = NSButton(title: String(localized: "conflict.all.keepBoth"), target: self, action: #selector(allKeepBothClicked))
        allKeepBoth.bezelStyle = .rounded

        continueButton.title = String(localized: "conflict.continue")
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(continueClicked)
        let cancelButton = NSButton(title: String(localized: "conflict.cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let allRow = NSStackView(views: [
            NSStackView(views: [allOverwrite, allSkip, allKeepBoth]),
            NSView(),
        ])
        allRow.orientation = .horizontal
        let buttons = NSStackView(views: [NSView(), cancelButton, continueButton])
        buttons.orientation = .horizontal

        let layout = NSStackView(views: [scroll, allRow, buttons])
        layout.orientation = .vertical
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            layout.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(max(120, min(320, 44 * rows.count + 24)))),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ConflictDialogController is created programmatically only")
    }

    /// Runs the dialog modally (a TC-style modal window). `nil` policy =
    /// cancelled; otherwise the chosen per-item/all policy.
    @discardableResult
    public static func run(rows: [ConflictPreviewRow]) -> ConflictPolicy? {
        let controller = ConflictDialogController(rows: rows)
        guard let window = controller.window else { return nil }
        window.center()
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        NSApp.stopModal()
        guard response == .OK else { return nil }
        return controller.buildPolicy()
    }

    /// The pure decision logic (tested separately from the AppKit loop).
    func buildPolicy() -> ConflictPolicy {
        ConflictModels.buildPolicy(rows: rows, resolutions: resolutions, applyToAll: applyToAllChoice)
    }

    // MARK: actions

    @objc private func allOverwriteClicked() { applyAll(.overwrite) }
    @objc private func allSkipClicked() { applyAll(.skip) }
    @objc private func allKeepBothClicked() { applyAll(.keepBoth) }

    func applyAll(_ resolution: ConflictResolution) {
        applyToAllChoice = resolution
        for index in resolutions.indices {
            resolutions[index] = resolution
        }
        tableView.reloadData()
    }

    @objc private func continueClicked() {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelClicked() {
        NSApp.stopModal(withCode: .cancel)
    }

    // MARK: NSTableView

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowModel = rows[row]
        let identifier = tableColumn?.identifier
        switch identifier {
        case ColumnID.name:
            return textCell("\(rowModel.name)")
        case ColumnID.source:
            return textCell(conflictPreviewText(rowModel.sourceItem))
        case ColumnID.target:
            return textCell(conflictPreviewText(rowModel.targetItem))
        case ColumnID.resolution:
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 26))
            popup.addItems(withTitles: [
                String(localized: "conflict.resolution.overwrite"),
                String(localized: "conflict.resolution.skip"),
                String(localized: "conflict.resolution.keepBoth"),
            ])
            switch resolutions[row] {
            case .overwrite: popup.selectItem(at: 0)
            case .skip: popup.selectItem(at: 1)
            default: popup.selectItem(at: 2)
            }
            popup.target = self
            popup.action = #selector(resolutionChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier("popup\(row)")
            return popup
        default:
            return nil
        }
    }

    private func textCell(_ text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let row = Int(identifier.dropFirst("popup".count)),
              row < resolutions.count
        else { return }
        applyToAllChoice = nil   // a manual per-row edit cancels «apply to all»
        switch sender.indexOfSelectedItem {
        case 0: resolutions[row] = .overwrite
        case 1: resolutions[row] = .skip
        default: resolutions[row] = .keepBoth
        }
    }
}
