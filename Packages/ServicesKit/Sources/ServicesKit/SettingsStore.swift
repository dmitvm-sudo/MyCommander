// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.9 «Контракт v1 (T-18)» — the settings store of
// F-21 MVP: defaults merged with the user JSON file, live application through
// `onDidUpdate` (AppKit consumers are wired in the App layer), section resets
// and export/import. `schemaVersion` mirrors SessionSnapshot's contract:
// a foreign version makes the user file ignored (migration comes later).

/// Sections for the settings window and `reset(_:)`.
public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance
    case deletion
    case editor
}

/// The full persisted settings set (docs/SDD/07 §7.3: «подтверждение ≥ N»
/// default 5; F-21 MVP: appearance/deletion/editor only).
public struct SettingsSchema: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// Always authored as 1 (`init`/`init-default`); imports go through the
    /// optional-overrides decode path which rejects foreign versions.
    public var schemaVersion: Int

    // MARK: appearance (panel font; family empty = system default face)

    public var panelFontFamily: String
    public var panelFontSize: Double
    public var useMonospacedPanelFont: Bool

    // MARK: deletion (07 §7.3: confirm at ≥ N items)

    public var confirmDelete: Bool
    public var deleteConfirmThreshold: Int

    // MARK: editor (F-4; empty = the system-default application)

    public var textEditorPath: String

    public static let `default` = SettingsSchema(
        schemaVersion: schemaVersion,
        panelFontFamily: "",
        panelFontSize: 13,
        useMonospacedPanelFont: true,
        confirmDelete: true,
        deleteConfirmThreshold: 5,
        textEditorPath: ""
    )

    public init() {
        self.schemaVersion = Self.schemaVersion
        self.panelFontFamily = ""
        self.panelFontSize = 13
        self.useMonospacedPanelFont = true
        self.confirmDelete = true
        self.deleteConfirmThreshold = 5
        self.textEditorPath = ""
    }

    public init(
        schemaVersion: Int = SettingsSchema.schemaVersion,
        panelFontFamily: String,
        panelFontSize: Double,
        useMonospacedPanelFont: Bool,
        confirmDelete: Bool,
        deleteConfirmThreshold: Int,
        textEditorPath: String
    ) {
        self.schemaVersion = schemaVersion
        self.panelFontFamily = panelFontFamily
        self.panelFontSize = panelFontSize
        self.useMonospacedPanelFont = useMonospacedPanelFont
        self.confirmDelete = confirmDelete
        self.deleteConfirmThreshold = deleteConfirmThreshold
        self.textEditorPath = textEditorPath
    }
}

/// User-JSON merge shape: every field optional over the defaults.
private struct SettingsOverrides: Codable {
    var schemaVersion: Int?
    var panelFontFamily: String?
    var panelFontSize: Double?
    var useMonospacedPanelFont: Bool?
    var confirmDelete: Bool?
    var deleteConfirmThreshold: Int?
    var textEditorPath: String?
}

/// File-backed settings store (Application Support «settings.json» by
/// default). The storage URL is injectable for tests (SessionStore pattern).
@MainActor
public final class SettingsStore {
    /// Fires on every effective change (update/import/reset/first load).
    public var onDidUpdate: (@MainActor (SettingsSchema) -> Void)?

    public private(set) var settings: SettingsSchema

    internal let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// True while a mutation is being fed back from persistence (no re-save).
    private var loading = false

    public init(url: URL? = nil) {
        self.fileURL = url ?? SettingsStore.defaultURL()
        self.settings = Self.loadUserSettings(from: self.fileURL)
    }

    /// Default storage path: `Application Support/MyCommander/settings.json`
    /// (SessionStore pattern; the directory is created on save).
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Live change: apply → persist → notify. The snapshot semantics match
    /// §6.9: consumers re-apply without a restart.
    public func update(_ mutate: (inout SettingsSchema) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
        persist(settings)
        onDidUpdate?(settings)
    }

    /// Section reset: fills the section's fields back into defaults.
    public func reset(_ section: SettingsSection) {
        update { schema in
            switch section {
            case .appearance:
                let appearance = SettingsSchema.default
                schema.panelFontFamily = appearance.panelFontFamily
                schema.panelFontSize = appearance.panelFontSize
                schema.useMonospacedPanelFont = appearance.useMonospacedPanelFont
            case .deletion:
                let deletion = SettingsSchema.default
                schema.confirmDelete = deletion.confirmDelete
                schema.deleteConfirmThreshold = deletion.deleteConfirmThreshold
            case .editor:
                schema.textEditorPath = SettingsSchema.default.textEditorPath
            }
        }
    }

    /// Pretty JSON dump of the current effective settings.
    public func export(to url: URL) throws {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    /// Import: decodes overrides over defaults (foreign schemaVersion →
    /// defaults, §6.9), persists and notifies; store state stays intact on
    /// decode errors.
    public func importData(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let imported = try SettingsStore.decodeSchema(from: data)
        settings = imported
        persist(settings)
        onDidUpdate?(settings)
    }

    // MARK: persistence

    /// Defaults plus surviving user overrides (missing file / foreign
    /// schemaVersion → pure defaults).
    private static func loadUserSettings(from url: URL) -> SettingsSchema {
        guard let data = try? Data(contentsOf: url) else {
            return .default
        }
        return (try? Self.decodeSchema(from: data)) ?? .default
    }

    private static func decodeSchema(from data: Data) throws -> SettingsSchema {
        let overrides = try JSONDecoder().decode(SettingsOverrides.self, from: data)
        guard overrides.schemaVersion == nil || overrides.schemaVersion == SettingsSchema.schemaVersion else {
            return .default
        }
        var schema = SettingsSchema.default
        if let value = overrides.panelFontFamily { schema.panelFontFamily = value }
        if let value = overrides.panelFontSize { schema.panelFontSize = value }
        if let value = overrides.useMonospacedPanelFont { schema.useMonospacedPanelFont = value }
        if let value = overrides.confirmDelete { schema.confirmDelete = value }
        if let value = overrides.deleteConfirmThreshold { schema.deleteConfirmThreshold = value }
        if let value = overrides.textEditorPath { schema.textEditorPath = value }
        return schema
    }

    private func persist(_ schema: SettingsSchema) {
        guard !loading, !fileURL.path.isEmpty else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(schema)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure never blocks the live consumer update.
        }
    }
}
