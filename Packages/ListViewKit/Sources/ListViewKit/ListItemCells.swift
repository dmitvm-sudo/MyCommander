// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit

// View-based table cells (docs/SDD/06 §6.1: NameCell «иконка + имя + бейджи:
// symlink/hidden/locked», MetaCell «размер/дата/права»). Sizes/dates use
// DomainKit formatting (ByteSizeFormat); UI strings go through String(localized:).
//
// Perf guard (§6.1 «Only-cell-reuse + rowHeight фикс»): cells lay out with
// constant frames inside a fixed rowHeight — no autoresizing rows anywhere.

final class NameCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("mc.nameCell")

    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    init() {
        iconView.imageScaling = .scaleProportionallyDown
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.usesSingleLineMode = true
        badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: FileListView.rowHeight))
        identifier = Self.reuseIdentifier
        for subview in [iconView, textLabel, badgeLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -4),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("NameCell is created programmatically only")
    }

    func render(item: VFSItem, icon: NSImage?) {
        iconView.image = icon
        textLabel.stringValue = item.name
        textLabel.textColor = item.attributes.isHidden ? .secondaryLabelColor : .labelColor
        var badge = ""
        if case .symlink = item.kind, badge.isEmpty { badge = String(localized: "cell.badge.symlink") }
        if item.attributes.isHidden { badge = String(localized: "cell.badge.hidden") }
        if item.attributes.isReadOnly { badge = String(localized: "cell.badge.locked") }
        badgeLabel.stringValue = badge
    }
}

final class MetaCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("mc.metaCell")

    private let textLabel = NSTextField(labelWithString: "")

    init() {
        textLabel.font = NSFont.systemFont(ofSize: 11)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byTruncatingTail
        super.init(frame: NSRect(x: 0, y: 0, width: 90, height: FileListView.rowHeight))
        identifier = Self.reuseIdentifier
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("MetaCell is created programmatically only")
    }

    func render(text: String, alignment: NSTextAlignment) {
        textLabel.stringValue = text
        textLabel.alignment = alignment
    }

    // Shared formatters: they are main-thread-confined together with the cells.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// «1,2 MB»-style size, DomainKit formatting (contract docs/SDD/05 §5.9).
    static func sizeText(of item: VFSItem) -> String {
        guard let size = item.attributes.size else { return "—" }
        return ByteSizeFormat.string(size)
    }

    static func modifiedText(of item: VFSItem) -> String {
        guard let modified = item.attributes.modified else { return "—" }
        return dateFormatter.string(from: modified)
    }
}
