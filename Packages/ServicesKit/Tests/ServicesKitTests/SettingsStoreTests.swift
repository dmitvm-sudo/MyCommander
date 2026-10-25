// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import ServicesKit

// T-18: settings store (F-21 MVP, 06 §6.9 v1) — defaults merged with the
// user JSON, live update notifications, section resets, export/import and
// the foreign schemaVersion rule. Helpers use the `st` name-space (the test
// module compiles neighbouring files together).

@MainActor
private func stStore(_ overrides: String?) -> SettingsStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("st-" + UUID().uuidString + ".json")
    if let overrides {
        try? Data(overrides.utf8).write(to: url)
    }
    return SettingsStore(url: url)
}

@MainActor
@Test func stDefaultsMergeSurvivingUserOverrides() {
    let store = stStore("""
    {
        "panelFontSize": 15.5,
        "confirmDelete": false
    }
    """)
    #expect(store.settings.panelFontSize == 15.5)
    #expect(store.settings.confirmDelete == false)
    // Unmentioned fields ride the defaults.
    #expect(store.settings.deleteConfirmThreshold == 5)
    #expect(store.settings.useMonospacedPanelFont == true)
    #expect(store.settings.schemaVersion == 1)
}

@MainActor
@Test func stForeignSchemaVersionIgnoresUserFile() {
    let store = stStore("""
    {
        "schemaVersion": 99,
        "panelFontSize": 99.99
    }
    """)
    #expect(store.settings == SettingsSchema.default)
}

@MainActor
@Test func stGarbageFileFallsBackToDefaults() {
    let store = stStore("{ not json ]]")
    #expect(store.settings == SettingsSchema.default)
}

@MainActor
@Test func stUpdatePersistsAndNotifies() throws {
    let store = stStore(nil)
    var fired: [SettingsSchema] = []
    store.onDidUpdate = { fired.append($0) }

    store.update { schema in
        schema.panelFontSize = 11
        schema.textEditorPath = "/Applications/Xcode.app"
    }
    #expect(store.settings.panelFontSize == 11)
    #expect(fired.count == 1)

    // The JSON file carries the change verbatim (the next store reads it).
    let reloaded = SettingsStore(url: store.settingsFileURL)
    #expect(reloaded.settings.panelFontSize == 11)
    #expect(reloaded.settings.textEditorPath == "/Applications/Xcode.app")
}

@MainActor
@Test func stResetSectionRestoresThoseFieldsOnly() {
    let store = stStore(nil)
    store.update { schema in
        schema.panelFontSize = 20
        schema.useMonospacedPanelFont = false
        schema.deleteConfirmThreshold = 42
        schema.textEditorPath = "/bin/ed"
    }
    store.reset(.appearance)
    #expect(store.settings.panelFontSize == 13)
    #expect(store.settings.useMonospacedPanelFont == true)
    #expect(store.settings.deleteConfirmThreshold == 42)   // another section
    #expect(store.settings.textEditorPath == "/bin/ed")

    store.reset(.deletion)
    #expect(store.settings.deleteConfirmThreshold == 5)
    store.reset(.editor)
    #expect(store.settings.textEditorPath == "")
}

@MainActor
@Test func stExportImportRoundTrip() throws {
    let source = stStore(nil)
    source.update { schema in
        schema.panelFontFamily = "SF Mono"
        schema.deleteConfirmThreshold = 9
    }

    let dumpURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("st-export-" + UUID().uuidString + ".json")
    try source.export(to: dumpURL)

    let target = stStore(nil)
    try target.importData(from: dumpURL)
    #expect(target.settings.panelFontFamily == "SF Mono")
    #expect(target.settings.deleteConfirmThreshold == 9)
    #expect(target.settings.schemaVersion == 1)
}

@MainActor
@Test func stImportRejectsGarbageAndKeepsState() throws {
    let store = stStore(nil)
    store.update { schema in
        schema.panelFontSize = 14
    }
    let badURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("st-bad-" + UUID().uuidString + ".json")
    try Data("]] garbage".utf8).write(to: badURL)

    #expect(throws: Error.self) {
        try store.importData(from: badURL)
    }
    #expect(store.settings.panelFontSize == 14)   // untouched by a failed import
}

// Test-only accessor for the injected storage path (@testable).
extension SettingsStore {
    var settingsFileURL: URL {
        fileURL
    }
}
