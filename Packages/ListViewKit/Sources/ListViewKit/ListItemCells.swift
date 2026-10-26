// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import UniformTypeIdentifiers

// View-based table cells (docs/SDD/06 §6.1: NameCell «иконка + имя + бейджи:
// symlink/hidden/locked», MetaCell «размер/дата/права»). Sizes/dates use
// DomainKit formatting (ByteSizeFormat); UI strings go through String(localized:).
// T-32 (F-4 «Уточнение» in §6.1): the meta statics cover the custom-column
// rendering (created/permissions/owner/tags/kind), ThumbnailCell hosts the
// QLThumbnailGenerator output of the thumbnails mode (⌃4).
//
// Perf guard (§6.1 «Only-cell-reuse + rowHeight фикс»): cells lay out with
// constant frames inside a fixed rowHeight — no autoresizing rows anywhere.

final class NameCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("mc.nameCell")

    private let iconView = NSImageView()
    let textLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    /// Theme color token (F-23 T-33): nil = system label colors.
    private var themeTexts: (text: NSColor, secondary: NSColor)?

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
        textLabel.textColor = item.attributes.isHidden
            ? (themeTexts?.secondary ?? .secondaryLabelColor)
            : (themeTexts?.text ?? .labelColor)
        var badge = ""
        if case .symlink = item.kind, badge.isEmpty { badge = String(localized: "cell.badge.symlink") }
        if item.attributes.isHidden { badge = String(localized: "cell.badge.hidden") }
        if item.attributes.isReadOnly { badge = String(localized: "cell.badge.locked") }
        badgeLabel.stringValue = badge
    }

    /// Settings live-apply (§6.9 v1, T-18): nil restores the default face.
    func applyPanelFont(_ font: NSFont?) {
        textLabel.font = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// Theme token apply (F-23 T-33; badge polish T-36): nil = system label
    /// colors; consulted again on every subsequent `render`. The badge tag
    /// rides the same secondary token — a hardcoded dark badge would be
    /// illegible on the ncBlue surface.
    func applyThemeColors(text: NSColor?, secondary: NSColor?) {
        if let text, let secondary {
            themeTexts = (text, secondary)
            badgeLabel.textColor = secondary
        } else {
            themeTexts = nil
            badgeLabel.textColor = .secondaryLabelColor
        }
    }

    // Test seam (T-36): the headless tests assert badge content/color without
    // digging into private storage.
    var badgeText: String { badgeLabel.stringValue }
    var badgeTextColor: NSColor { badgeLabel.textColor ?? .secondaryLabelColor }
}

final class MetaCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("mc.metaCell")

    let textLabel = NSTextField(labelWithString: "")

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

    /// Settings live-apply (§6.9 v1, T-18): nil restores the default face.
    func applyPanelFont(_ font: NSFont?) {
        textLabel.font = font ?? NSFont.systemFont(ofSize: 11)
    }

    /// Theme token apply (F-23 T-33): nil restores the system secondary color.
    func applyThemeColor(_ color: NSColor?) {
        textLabel.textColor = color ?? .secondaryLabelColor
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

    // MARK: T-32 custom columns (06 §6.1 «Уточнение T-32»)

    static func createdText(of item: VFSItem) -> String {
        guard let created = item.attributes.created else { return "—" }
        return dateFormatter.string(from: created)
    }

    /// POSIX octal (« 0644») — the stat-mode short form, contract §5.1.
    static func permissionsText(of item: VFSItem) -> String {
        guard let permissions = item.attributes.posixPermissions else { return "—" }
        return String(format: "%o", permissions)
    }

    static func ownerText(of item: VFSItem) -> String {
        item.attributes.owner ?? "—"
    }

    static func tagsText(of item: VFSItem) -> String {
        item.attributes.tags.isEmpty ? "—" : item.attributes.tags.joined(separator: ", ")
    }

    /// Kind display name: directory by key, the UTType of the filename
    /// extension everywhere else (NSWorkspace.localizedDescription(forFile:)
    /// was removed from the SDK — UTType.localizedDescription is the
    /// replacement).
    static func kindText(of item: VFSItem) -> String {
        if case .directory = item.kind {
            return String(localized: "cell.kind.folder")
        }
        if let type = UTType(filenameExtension: (item.name as NSString).pathExtension) {
            return type.localizedDescription ?? type.identifier
        }
        return "—"
    }
}

/// Thumbnails mode cell (⌃4, T-32): a fixed 40×40 image inside the 56-point
/// row; `renderedKey` mirrors the requested `ThumbnailStore.cacheKey` so the
/// row-reload listener can refuse stale async updates made against a reused
/// cell (identity/mode guard, docs/SDD/06 §6.1 «Уточнение T-32»).
final class ThumbnailCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("mc.thumbnailCell")

    /// NOT named `imageView`: NSTableCellView owns that property (an open
    /// optional) — a private storage with the same name is illegal.
    private let thumbView = NSImageView()
    /// The cache key the cell was last rendered with (stale-update guard).
    var renderedKey: String?

    init() {
        super.init(
            frame: NSRect(x: 0, y: 0, width: 56, height: FileListView.thumbnailRowHeight)
        )
        identifier = Self.reuseIdentifier
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.centerXAnchor.constraint(equalTo: centerXAnchor),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 40),
            thumbView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ThumbnailCell is created programmatically only")
    }

    func render(image: NSImage?, key: String) {
        renderedKey = key
        thumbView.image = image
    }
}
