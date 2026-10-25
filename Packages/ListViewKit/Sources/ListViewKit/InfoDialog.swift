// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.11 v1 (T-15) — non-modal item info card (F-19,
// `⌃A` / remap). The window is reusable (a second call rewrites it); the
// recursive directory size arrives later through `update(size:)`, so UI never
// blocks on the walk. Pure builders (fields/bytes/formatting) are separated
// from the window for tests.

// MARK: - Pure model

/// Field semantics: the App/updates replace the size entry by `kind`.
public enum InfoKind: Sendable, Equatable {
    case name
    case kind
    case size
    case created
    case modified
    case permissions
    case owner
    case group
    case tags
}

public struct InfoField: Sendable, Equatable {
    public let kind: InfoKind
    public let label: String
    public let value: String

    public init(kind: InfoKind, label: String, value: String) {
        self.kind = kind
        self.label = label
        self.value = value
    }
}

public enum InfoFieldBuilder {
    /// One row per attribute; absent values render as «—» (the background
    /// directory-size pass replaces the size row via InfoDisplay).
    public static func fields(for item: VFSItem) -> [InfoField] {
        var fields: [InfoField] = []
        fields.append(InfoField(
            kind: .name,
            label: String(localized: "info.field.name"),
            value: item.name
        ))

        let kindLabel: String
        switch item.kind {
        case .directory:
            kindLabel = String(localized: "info.kind.directory")
        case .file:
            kindLabel = String(localized: "info.kind.file")
        case .symlink(let target):
            kindLabel = target.map { String(localized: "info.kind.symlink \(posixPath($0)))") }
                ?? String(localized: "info.kind.symlinkDangling")
        case .special:
            kindLabel = String(localized: "info.kind.special")
        }
        fields.append(InfoField(kind: .kind, label: String(localized: "info.field.kind"), value: kindLabel))

        fields.append(InfoField(
            kind: .size,
            label: String(localized: "info.field.size"),
            value: item.attributes.size.map { InfoBytes.format($0) } ?? "—"
        ))
        fields.append(InfoField(
            kind: .created,
            label: String(localized: "info.field.created"),
            value: InfoDates.format(item.attributes.created)
        ))
        fields.append(InfoField(
            kind: .modified,
            label: String(localized: "info.field.modified"),
            value: InfoDates.format(item.attributes.modified)
        ))
        fields.append(InfoField(
            kind: .permissions,
            label: String(localized: "info.field.permissions"),
            value: item.attributes.posixPermissions.map { InfoPermissions.format($0) } ?? "—"
        ))
        fields.append(InfoField(
            kind: .owner,
            label: String(localized: "info.field.owner"),
            value: item.attributes.owner ?? "—"
        ))
        fields.append(InfoField(
            kind: .group,
            label: String(localized: "info.field.group"),
            value: item.attributes.group ?? "—"
        ))
        fields.append(InfoField(
            kind: .tags,
            label: String(localized: "info.field.tags"),
            value: item.attributes.tags.isEmpty ? "—" : item.attributes.tags.joined(separator: ", ")
        ))
        return fields
    }

    private static func posixPath(_ path: VFSPath) -> String {
        path.components.isEmpty ? "/" : "/" + path.components.joined(separator: "/")
    }
}

/// Stable byte-size rendering (1024 base, like ByteCountFormatter.memory but
/// locale-invariant for tests): «0 B», «2 KB», «1.5 MB».
public enum InfoBytes {
    public static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        // One decimal, trailing zero trimmed: 2 KB, 1.5 MB.
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text == "-0" ? "0 B" : text + " " + units[unitIndex]
    }
}

/// Stable permission rendering: `rw-r--r-- (644)` (the ls type byte stays
/// with the kind row, 06 §6.11).
public enum InfoPermissions {
    public static func format(_ posix: Int16) -> String {
        let mode = posix & 0o777
        // owner / group / other via explicit shifts (no ls type byte — the
        // kind row carries directory/file).
        func triplet(_ offset: Int16) -> String {
            let r = (mode >> offset) & 4 != 0 ? "r" : "-"
            let w = (mode >> offset) & 2 != 0 ? "w" : "-"
            let x = (mode >> offset) & 1 != 0 ? "x" : "-"
            return r + w + x
        }
        let octal = String(mode, radix: 8)
        return "\(triplet(6))\(triplet(3))\(triplet(0)) (\(octal))"
    }
}

/// Stable date rendering «YYYY-MM-DD HH:MM» in the current time zone (no
/// locale variations, tests assert exact strings).
public enum InfoDates {
    public static func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        let hour = String(format: "%02d", components.hour ?? 0)
        let minute = String(format: "%02d", components.minute ?? 0)
        return "\(year)-\(month)-\(day) \(hour):\(minute)"
    }
}

public enum InfoDisplay {
    /// The card text — one «label: value» row per field.
    public static func compose(_ fields: [InfoField]) -> String {
        fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    /// Replaces the size row (background directorySize final, 06 §6.11).
    public static func updatingSize(_ fields: [InfoField], size: Int64) -> [InfoField] {
        fields.map { field in
            field.kind == .size
                ? InfoField(kind: .size, label: field.label, value: InfoBytes.format(size))
                : field
        }
    }
}

// MARK: - Window

/// The info card window (F-19): non-modal, one reusable instance in the App.
/// Contains a Selectable plain-text card (fields list), a Copy button
/// (acceptance: «копирование списка полей») and the standard close.
@MainActor
public final class InfoWindowController: NSWindowController {
    private var fields: [InfoField]
    private let cardView = NSTextView()

    public init(item: VFSItem) {
        fields = InfoFieldBuilder.fields(for: item)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "info.title \(item.name)")
        super.init(window: window)

        cardView.isEditable = false
        cardView.isSelectable = true
        cardView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = cardView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: String(localized: "info.copy"), target: self, action: #selector(copyClicked(_:)))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [copyButton])
        row.orientation = .horizontal
        row.alignment = .leading
        let stack = NSStackView(views: [scroll, row])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            copyButton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("InfoWindowController is created programmatically only")
    }

    /// The reusable window: a second `⌃A` rewrite (Lister reset pattern).
    public func reset(to item: VFSItem) {
        fields = InfoFieldBuilder.fields(for: item)
        window?.title = String(localized: "info.title \(item.name)")
        refresh()
    }

    /// Final of the background directory-size walk.
    public func update(size: Int64) {
        fields = InfoDisplay.updatingSize(fields, size: size)
        refresh()
    }

    public func activate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Acceptance: the whole card text goes into the Clipboard as plain text.
    public func copyToClipboard() {
        let text = InfoDisplay.compose(fields)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func copyClicked(_ sender: NSButton) {
        copyToClipboard()
    }

    private func refresh() {
        cardView.string = InfoDisplay.compose(fields)
        cardView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}
