// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.9 «Контракт v1 (T-18)» + «Уточнение T-32 (F-21
// «полные» v1)» — the settings store: defaults merged with the user JSON
// file, live application through `onDidUpdate` (AppKit consumers are wired in
// the App layer), section resets and export/import. `schemaVersion` stays 1
// for the T-32 additions (additive fields; a user file without the new keys
// decodes through the optional-merge path). A foreign version makes the user
// file ignored (migration comes later). Scope boundaries (§6.9 T-32): theme
// → T-33 (F-23), the keymap editor → v1.x, network profiles → the Connections
// window (F-13).

/// Sections for the settings window and `reset(_:)`.
public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance
    case deletion
    case editor
    case view
    case archive
    case terminal
}

/// The full persisted settings set (docs/SDD/07 §7.3: «подтверждение ≥ N»
/// default 5).
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

    // MARK: view (F-4 full / T-32)

    /// Columns of the `columns` display mode (⌃3): order = rendering order,
    /// `name` is always the first column (§5.9). Default = the full-mode trio.
    /// Renderable set only — `gitStatus` arrives with F-27 providers.
    public var columns: [ColumnID]

    /// F-10 configurable matching style: "substring" / "fuzzy"; anything else
    /// decodes back to substring (App maps to EnginesKit.FilterStyle).
    public var filterStyleRaw: String

    // MARK: archive (F-12/T-21)

    /// false = Enter on an archive container does not mount it as a folder —
    /// the App driver skips the §6.1 `openEntryHandler` wiring for the VM.
    public var archiveAutoMount: Bool

    // MARK: terminal (F-17/T-31)

    /// 06 §6.8 «опция off»: the shell child does not follow panel navigation
    /// (the auto-CD feed is filtered out in the App coordinator).
    public var terminalAutoCd: Bool

    public static let `default` = SettingsSchema(
        schemaVersion: schemaVersion,
        panelFontFamily: "",
        panelFontSize: 13,
        useMonospacedPanelFont: true,
        confirmDelete: true,
        deleteConfirmThreshold: 5,
        textEditorPath: "",
        columns: [.name, .size, .dateModified],
        filterStyleRaw: "substring",
        archiveAutoMount: true,
        terminalAutoCd: true
    )

    public init() {
        self = Self.default
    }

    public init(
        schemaVersion: Int = SettingsSchema.schemaVersion,
        panelFontFamily: String,
        panelFontSize: Double,
        useMonospacedPanelFont: Bool,
        confirmDelete: Bool,
        deleteConfirmThreshold: Int,
        textEditorPath: String,
        columns: [ColumnID],
        filterStyleRaw: String,
        archiveAutoMount: Bool,
        terminalAutoCd: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.panelFontFamily = panelFontFamily
        self.panelFontSize = panelFontSize
        self.useMonospacedPanelFont = useMonospacedPanelFont
        self.confirmDelete = confirmDelete
        self.deleteConfirmThreshold = deleteConfirmThreshold
        self.textEditorPath = textEditorPath
        self.columns = columns
        self.filterStyleRaw = filterStyleRaw
        self.archiveAutoMount = archiveAutoMount
        self.terminalAutoCd = terminalAutoCd
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
    var columns: [ColumnID]?
    var filterStyleRaw: String?
    var archiveAutoMount: Bool?
    var terminalAutoCd: Bool?
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
            let schemaDefault = SettingsSchema.default
            switch section {
            case .appearance:
                schema.panelFontFamily = schemaDefault.panelFontFamily
                schema.panelFontSize = schemaDefault.panelFontSize
                schema.useMonospacedPanelFont = schemaDefault.useMonospacedPanelFont
            case .deletion:
                schema.confirmDelete = schemaDefault.confirmDelete
                schema.deleteConfirmThreshold = schemaDefault.deleteConfirmThreshold
            case .editor:
                schema.textEditorPath = schemaDefault.textEditorPath
            case .view:
                schema.columns = schemaDefault.columns
                schema.filterStyleRaw = schemaDefault.filterStyleRaw
            case .archive:
                schema.archiveAutoMount = schemaDefault.archiveAutoMount
            case .terminal:
                schema.terminalAutoCd = schemaDefault.terminalAutoCd
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
        if let value = overrides.columns { schema.columns = SettingsStore.sanitizedColumns(value) }
        if let value = overrides.filterStyleRaw { schema.filterStyleRaw = value }
        if let value = overrides.archiveAutoMount { schema.archiveAutoMount = value }
        if let value = overrides.terminalAutoCd { schema.terminalAutoCd = value }
        return schema
    }

    /// §5.9: `name` is always the first column; duplicates collapse; the
    /// renderable set only (`gitStatus` awaits the F-27 provider).
    public static func sanitizedColumns(_ values: [ColumnID]) -> [ColumnID] {
        var seen = Set<ColumnID>()
        var result: [ColumnID] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        result.removeAll { $0 == .gitStatus }
        result.removeAll { $0 == .name }
        return [.name] + result
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
