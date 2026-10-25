// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation

// Contract: docs/SDD/02 F-12 (уточнение T-22) + 06 §6.2 — the «Pack…» dialog:
// the zip artifact name + the «method of compression» option. Honest v1
// (06 §6.2 T-22): ZIPFoundation exposes only store/deflate — there is no
// compression-level dial, so the dialog speaks of the method, not the level.
// The destination is the opposite panel's current directory (v1 fixed); the
// result enqueues through the transfer queue (background packing).

/// The dialog's answer (tested alongside the pure builders).
public struct PackChoice: Sendable, Equatable {
    public let name: String
    public let compression: ZipPackCompression

    public init(name: String, compression: ZipPackCompression) {
        self.name = name
        self.compression = compression
    }
}

@MainActor
final class PackDialogController: NSObject {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    private var nameField: NSTextField?
    private var compressionPopup: NSPopUpButton?

    init(defaultName: String) {
        super.init()
        window.title = String(localized: "pack.title")

        let nameLabel = NSTextField(labelWithString: String(localized: "pack.name"))
        let field = NSTextField(string: defaultName)
        field.placeholderString = String(localized: "pack.name.placeholder")
        nameField = field

        let methodLabel = NSTextField(labelWithString: String(localized: "pack.compression"))
        let popup = NSPopUpButton()
        popup.addItem(withTitle: String(localized: "pack.compression.deflate"))
        popup.addItem(withTitle: String(localized: "pack.compression.store"))
        compressionPopup = popup

        let okButton = NSButton(title: String(localized: "pack.ok"), target: self, action: #selector(continueClicked))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: String(localized: "pack.cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let nameRow = NSStackView(views: [nameLabel, field])
        nameRow.orientation = .horizontal
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let methodRow = NSStackView(views: [methodLabel, popup])
        methodRow.orientation = .horizontal

        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.orientation = .horizontal

        let layout = NSStackView(views: [nameRow, methodRow, buttons])
        layout.orientation = .vertical
        layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -14),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14),
            layout.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PackDialogController is created programmatically only")
    }

    /// Pure answer building (the AppKit modal loop is not testable).
    func buildChoice() -> PackChoice {
        let raw = nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = raw.isEmpty ? "pack.zip" : raw
        let store = compressionPopup?.indexOfSelectedItem == 1
        return PackChoice(name: name, compression: store ? .store : .deflate)
    }

    // MARK: actions

    @objc private func continueClicked() {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelClicked() {
        NSApp.stopModal(withCode: .cancel)
    }
}

@MainActor
public enum PackDialog {
    /// Runs the dialog modally; returns `nil` on cancel.
    public static func run(defaultName: String) -> PackChoice? {
        let controller = PackDialogController(defaultName: defaultName)
        let window = controller.window
        window.center()
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        NSApp.stopModal()
        guard response == .OK else { return nil }
        return controller.buildChoice()
    }
}
