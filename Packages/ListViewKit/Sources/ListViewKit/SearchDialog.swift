// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import EnginesKit

// Contract: docs/SDD/06 §6.6 (уточнение T-30) + F-16 — the search dialog:
// mask / content (literal or regex) / case / size / date fields, LIVE hits
// while the engine walks (progress label), instant cancel (the engine checks
// task cancellation per directory and per chunk), a result LIMIT, and
// «В панель» (the App turns the accepted hits into a SearchResultVFS and
// swaps it into the active panel). The engine task runs DETACHED — the modal
// loop keeps pumping the main queue, so live updates and cancel stay alive.

@MainActor
final class SearchDialogController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let source: any VFS
    private let root: VFSPath
    var applyResult: [SearchHit]?

    private let maskField = NSTextField()
    private let contentField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: String(localized: "search.regex"), target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: String(localized: "search.caseSensitive"), target: nil, action: nil)
    private let minSizeField = NSTextField()
    private let maxSizeField = NSTextField()
    private let limitField = NSTextField(string: "1000")
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let searchButton = NSButton(title: String(localized: "search.start"), target: nil, action: nil)
    private let panelButton = NSButton(title: String(localized: "search.toPanel"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "search.close"), target: nil, action: nil)

    private var hits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?
    private var finished = false

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let matches = NSUserInterfaceItemIdentifier("matches")
        static let size = NSUserInterfaceItemIdentifier("size")
    }

    init(source: any VFS, at root: VFSPath) {
        self.source = source
        self.root = root
        super.init()
        window.title = String(localized: "search.title")
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SearchDialogController is created programmatically only")
    }

    private func build() {
        let maskLabel = NSTextField(labelWithString: String(localized: "search.mask"))
        maskField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let contentLabel = NSTextField(labelWithString: String(localized: "search.content"))
        contentField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let filterRow = NSStackView(views: [maskLabel, maskField, contentLabel, contentField, regexCheck, caseCheck])
        filterRow.orientation = .horizontal

        let sizeLabel = NSTextField(labelWithString: String(localized: "search.size"))
        minSizeField.placeholderString = String(localized: "search.size.min")
        maxSizeField.placeholderString = String(localized: "search.size.max")
        minSizeField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        maxSizeField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        limitField.placeholderString = String(localized: "search.limit")
        limitField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let sizeRow = NSStackView(views: [sizeLabel, minSizeField, maxSizeField, limitField])
        sizeRow.orientation = .horizontal

        statusLabel.stringValue = String(localized: "search.status.idle")

        for (identifier, title, width) in [
            (ColumnID.name, "search.column.name", 320),
            (ColumnID.matches, "search.column.matches", 90),
            (ColumnID.size, "search.column.size", 110)
        ] as [(NSUserInterfaceItemIdentifier, String, CGFloat)] {
            let column = NSTableColumn(identifier: identifier)
            column.title = String(localized: String.LocalizationValue(title))
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.setAccessibilityIdentifier("search.results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        searchButton.bezelStyle = .rounded
        searchButton.keyEquivalent = "\r"
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        panelButton.bezelStyle = .rounded
        panelButton.target = self
        panelButton.action = #selector(panelClicked)
        panelButton.isEnabled = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let buttons = NSStackView(views: [NSView(), closeButton, panelButton, searchButton])
        buttons.orientation = .horizontal

        let layout = NSStackView(views: [filterRow, sizeRow, statusLabel, scroll, buttons])
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

    // MARK: query → engine

    private var currentQuery: SearchQuery {
        let mask = maskField.stringValue.trimmingCharacters(in: .whitespaces)
        return SearchQuery(
            nameMask: mask.isEmpty ? nil : FileMask(mask.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }),
            content: contentField.stringValue,
            contentIsRegex: regexCheck.state == NSControl.StateValue.on,
            caseSensitive: caseCheck.state == NSControl.StateValue.on,
            minSize: Int64(minSizeField.stringValue) ?? nil,
            maxSize: Int64(maxSizeField.stringValue) ?? nil,
            maxFileSize: 32 << 20,
            resultLimit: Int(limitField.stringValue) ?? 1000
        )
    }

    @objc private func searchClicked() {
        searchTask?.cancel()
        hits = []
        table.reloadData()
        panelButton.isEnabled = false
        finished = false
        statusLabel.stringValue = String(localized: "search.status.running")
        let query = currentQuery
        let source = source
        let root = root
        searchTask = Task.detached { [weak self] in
            do {
                let result = try await SearchEngine.search(in: source, at: root, query: query, onHit: { hit in
                    Task { @MainActor in
                        self?.hits.append(hit)
                        self?.table.reloadData()
                        self?.statusLabel.stringValue = String(localized: "search.status.hits \(self?.hits.count ?? 0)")
                    }
                })
                await MainActor.run {
                    self?.hits = result.hits
                    self?.finished = true
                    self?.table.reloadData()
                    let truncated = result.truncated ? String(localized: "search.status.truncated") : ""
                    self?.statusLabel.stringValue = String(localized: "search.status.done \(result.hits.count) \(truncated)")
                    self?.panelButton.isEnabled = !result.hits.isEmpty
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finished = true
                    self?.statusLabel.stringValue = String(localized: "search.status.canceled \(self?.hits.count ?? 0)")
                    self?.panelButton.isEnabled = !(self?.hits.isEmpty ?? true)
                }
            } catch {
                await MainActor.run {
                    self?.finished = true
                    self?.statusLabel.stringValue = String(localized: "search.status.failed")
                }
            }
        }
    }

    @objc private func panelClicked() {
        guard finished, !hits.isEmpty else { return }
        applyResult = hits
        window.orderOut(nil)
        NSApp.stopModal()
    }

    @objc private func closeClicked() {
        if searchTask != nil, !finished {
            searchTask?.cancel()   // instant cancel (F-16 acceptance)
            return
        }
        applyResult = nil
        window.orderOut(nil)
        NSApp.stopModal()
    }

    // MARK: results table

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row]
        let text: String
        switch tableColumn?.identifier {
        case ColumnID.matches:
            text = hit.contentMatches.map(String.init) ?? "—"
        case ColumnID.size:
            text = hit.item.attributes.size.map { ByteSizeFormat.string($0) } ?? "—"
        default:
            text = hit.item.name
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
}

/// Static entry: runs the dialog modally; returns the hits accepted by the
/// engine (the App turns them into a `SearchResultVFS` panel) or `nil`.
@MainActor
public enum SearchDialog {
    public static func run(source: any VFS, at root: VFSPath) -> [SearchHit]? {
        let controller = SearchDialogController(source: source, at: root)
        controller.window.center()
        NSApp.runModal(for: controller.window)
        return controller.applyResult
    }
}
