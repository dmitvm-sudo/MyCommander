// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServicesKit

// Contract: docs/SDD/06 §6.9 «Контракт v1 (T-18)» — the settings window is
// non-modal and reusable (⌘, / menu.openSettings); every change goes through
// `SettingsStore.update` (persist + onDidUpdate → consumers apply live);
// export/import ride NSSavePanel/NSOpenPanel; each section resets only its
// own fields (07 §7.3: delete-confirm respects the ≥ N threshold).

@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore

    // Section: appearance.
    private let monoCheck = NSButton(checkboxWithTitle: String(localized: "settings.appearance.mono"), target: nil, action: nil)
    private let sizeField = SettingsStepperField(min: 9, max: 24)
    // Section: deletion.
    private let confirmDeleteCheck = NSButton(checkboxWithTitle: String(localized: "settings.deletion.confirm"), target: nil, action: nil)
    private let thresholdField = SettingsStepperField(min: 1, max: 100)
    // Section: editor.
    private let editorField = NSTextField()

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "settings.title")
        super.init(window: window)
        guard let contentView = window.contentView else { return }
        build(contentView: contentView)
        refreshFields()
        store.onDidUpdate = { [weak self] _ in self?.refreshFields() }
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created programmatically only")
    }

    func activate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: build

    private func build(contentView: NSView) {
        monoCheck.target = self
        monoCheck.action = #selector(monoChanged(_:))

        sizeField.onValueChanged = { [weak self] value in
            self?.store.update { $0.panelFontSize = value }
        }

        confirmDeleteCheck.target = self
        confirmDeleteCheck.action = #selector(confirmDeleteChanged(_:))

        thresholdField.onValueChanged = { [weak self] value in
            let clamped = max(1, min(100, Int(value)))
            self?.store.update { $0.deleteConfirmThreshold = clamped }
        }

        editorField.placeholderString = String(localized: "settings.editor.placeholder")
        editorField.target = self
        editorField.action = #selector(editorPathChanged(_:))
        editorField.translatesAutoresizingMaskIntoConstraints = false
        let browseButton = NSButton(title: String(localized: "settings.editor.browse"), target: self, action: #selector(browseEditor(_:)))
        browseButton.controlSize = .small

        let appearanceReset = SettingsWindowController.resetButton(target: self, action: #selector(resetAppearance(_:)))
        let deletionReset = SettingsWindowController.resetButton(target: self, action: #selector(resetDeletion(_:)))
        let editorReset = SettingsWindowController.resetButton(target: self, action: #selector(resetEditor(_:)))

        let appearanceSection = SettingsWindowController.section(
            title: String(localized: "settings.section.appearance"),
            rows: [monoCheck, sizeField, appearanceReset]
        )
        let deletionSection = SettingsWindowController.section(
            title: String(localized: "settings.section.deletion"),
            rows: [confirmDeleteCheck, thresholdField, deletionReset]
        )
        let editorSection = SettingsWindowController.section(
            title: String(localized: "settings.section.editor"),
            rows: [editorField, browseButton, editorReset]
        )

        let exportButton = NSButton(title: String(localized: "settings.export"), target: self, action: #selector(exportSettings(_:)))
        exportButton.controlSize = .small
        let importButton = NSButton(title: String(localized: "settings.import"), target: self, action: #selector(importSettings(_:)))
        importButton.controlSize = .small
        let footer = NSStackView(views: [exportButton, importButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [appearanceSection, deletionSection, editorSection, footer])
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
            editorField.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    private static func section(title: String, rows: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.boldSystemFont(ofSize: 12)
        let rowsStack = NSStackView(views: rows)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        let stack = NSStackView(views: [heading, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private static func resetButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: String(localized: "settings.reset"), target: target, action: action)
        button.controlSize = .small
        button.bezelStyle = .rounded
        return button
    }

    // MARK: refresh

    private func refreshFields() {
        let schema = store.settings
        monoCheck.state = schema.useMonospacedPanelFont ? .on : .off
        confirmDeleteCheck.state = schema.confirmDelete ? .on : .off
        sizeField.value = schema.panelFontSize   // fires no store update
        thresholdField.value = Double(max(1, schema.deleteConfirmThreshold))
        editorField.stringValue = schema.textEditorPath
    }

    // MARK: actions

    @objc private func monoChanged(_ sender: NSButton) {
        store.update { $0.useMonospacedPanelFont = sender.state == .on }
    }

    @objc private func confirmDeleteChanged(_ sender: NSButton) {
        store.update { $0.confirmDelete = sender.state == .on }
    }

    @objc private func editorPathChanged(_ sender: NSTextField) {
        store.update { $0.textEditorPath = sender.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    @objc private func browseEditor(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.editorField.stringValue = url.path
            self.store.update { $0.textEditorPath = url.path }
        }
    }

    @objc private func resetAppearance(_ sender: NSButton) {
        store.reset(.appearance)
    }

    @objc private func resetDeletion(_ sender: NSButton) {
        store.reset(.deletion)
    }

    @objc private func resetEditor(_ sender: NSButton) {
        store.reset(.editor)
    }

    @objc private func exportSettings(_ sender: NSButton) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mycommander-settings.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            try? self.store.export(to: url)
        }
    }

    @objc private func importSettings(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            try? self.store.importData(from: url)
        }
    }
}

/// Panel font built from the settings schema (App-side construction —
/// ServicesKit stays AppKit-free, §6.9 v1).
extension NSFont {
    static func wrappedPanelFont(from schema: SettingsSchema) -> NSFont {
        let size = max(9, min(24, schema.panelFontSize))
        let fallback = schema.useMonospacedPanelFont
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        guard !schema.panelFontFamily.isEmpty else { return fallback }
        return NSFontManager.shared.font(
            withFamily: schema.panelFontFamily,
            traits: [],
            weight: 5,
            size: size
        ) ?? fallback
    }
}

/// Small ≤value label whose `value` setter does NOT fire `onValueChanged`
/// (avoids update → notification → re-set loops when the store refreshes
/// the fields back into the UI).
@MainActor
final class SettingsStepperField: NSStackView {
    let label = NSTextField()
    let stepper = NSStepper()
    var onValueChanged: ((Double) -> Void)?
    private var intValue: Double = 0
    private let range: ClosedRange<Double>

    init(min: Double, max: Double) {
        self.range = min ... max
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        label.font = NSFont.systemFont(ofSize: 12)
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = 1
        stepper.doubleValue = min
        stepper.target = self
        stepper.action = #selector(stepChanged(_:))
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        addArrangedSubview(label)
        addArrangedSubview(stepper)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsStepperField is created programmatically only")
    }

    /// Programmatic refresh without side effects.
    var value: Double {
        get { intValue }
        set {
            intValue = max(range.lowerBound, min(range.upperBound, newValue))
            label.stringValue = String(format: "%.0f", intValue)
            stepper.doubleValue = intValue
        }
    }

    @objc private func stepChanged(_ sender: NSStepper) {
        intValue = max(range.lowerBound, min(range.upperBound, sender.doubleValue))
        label.stringValue = String(format: "%.0f", intValue)
        onValueChanged?(intValue)
    }
}
