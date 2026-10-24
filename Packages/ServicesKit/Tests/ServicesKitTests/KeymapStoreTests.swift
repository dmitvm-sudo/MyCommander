// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import ServicesKit

// T-09: KeymapStore — bundled profiles decode, «карта 07 активна» (tc is the
// default), conflicts forbidden on save (§6.9), reset to profile, combo lookup.

private func keymapTempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MCKeymapTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("keymap.json")
}

private func keymapProfile(fromJSON json: String) throws -> KeymapProfile {
    try JSONDecoder().decode(KeymapProfile.self, from: Data(json.utf8))
}

private let tcJSON = """
{
  "id": "tc",
  "name": "TC/NC classic",
  "entries": [
    { "command": "goUp", "context": "global", "combo": { "keyCode": 126, "modifiers": ["command"] } },
    { "command": "reloadPanel", "context": "global", "combo": { "keyCode": 15, "modifiers": ["command"] } },
    { "command": "goUp", "context": "panelList", "combo": { "keyCode": 51, "modifiers": [] } },
    { "command": "selectMasked", "context": "panelList", "combo": { "keyCode": 69, "modifiers": [] } },
    { "command": "toggleSelectionAndMove", "context": "panelList", "combo": { "keyCode": 49, "modifiers": [] } }
  ]
}
"""

private let macosJSON = """
{
  "id": "macos",
  "name": "macOS style",
  "entries": [
    { "command": "reloadPanel", "context": "global", "combo": { "keyCode": 15, "modifiers": ["command"] } },
    { "command": "toggleSelectionAndMove", "context": "panelList", "combo": { "keyCode": 49, "modifiers": ["control"] } }
  ]
}
"""

private func keymapDefaults() throws -> [KeymapProfile] {
    [try keymapProfile(fromJSON: tcJSON), try keymapProfile(fromJSON: macosJSON)]
}

@Test func bundledProfileJSONDecodes() throws {
    let profiles = try keymapDefaults()
    #expect(profiles[0].id == "tc")
    #expect(profiles[0].entries.contains { $0.command == .selectMasked && $0.context == .panelList && $0.combo.keyCode == 69 })
    #expect(profiles[1].id == "macos")
}

@Test func activeDefaultsToFirstProfileAndSurvivesReopen() throws {
    let url = keymapTempURL("default")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)

    // «Карта 07 активна»: no user file → TC/NC classic.
    #expect(store.active().id == "tc")
    #expect(store.command(for: KeyCombo(keyCode: 51), in: .panelList) == .goUp)
    #expect(store.command(for: KeyCombo(keyCode: 15, modifiers: [.command]), in: .global) == .reloadPanel)
    #expect(store.command(for: KeyCombo(keyCode: 125), in: .panelList) == nil)

    // A fresh store (relaunch) resolves the same defaults.
    #expect(KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url).active().id == "tc")
}

@Test func saveAndReloadRoundtripThenReset() throws {
    let url = keymapTempURL("roundtrip")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)

    var remapped = store.active()
    remapped.entries.append(KeymapEntry(
        combo: KeyCombo(keyCode: 11, modifiers: [.command]),   // ⌘B
        command: .restoreSelection,
        context: .global
    ))
    try store.save(remapped)
    #expect(store.command(for: KeyCombo(keyCode: 11, modifiers: [.command]), in: .global) == .restoreSelection)

    // Relaunch reads the saved user profile.
    let reloaded = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)
    #expect(reloaded.active().entries.count == remapped.entries.count)

    // Reset → back to the bundled default, user file gone.
    reloaded.reset()
    #expect(reloaded.active().id == "tc")
    #expect(reloaded.command(for: KeyCombo(keyCode: 11, modifiers: [.command]), in: .global) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func conflictingBindingsBlockSave() throws {
    let url = keymapTempURL("conflict")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)

    // ⌘B is already bound to restoreSelection in the saved profile above —
    // build a profile that binds ⌘B to two different global commands.
    var conflicting = store.active()
    conflicting.entries.append(KeymapEntry(combo: KeyCombo(keyCode: 11, modifiers: [.command]), command: .restoreSelection, context: .global))
    conflicting.entries.append(KeymapEntry(combo: KeyCombo(keyCode: 11, modifiers: [.command]), command: .swapPanels, context: .global))
    #expect(throws: KeymapError.self) { try store.save(conflicting) }

    // The blocked save must not persist: the store still resolves the default.
    #expect(store.command(for: KeyCombo(keyCode: 11, modifiers: [.command]), in: .global) == nil)

    // The same combo in a different context is not a conflict.
    var crossContext = store.active()
    crossContext.entries.append(KeymapEntry(combo: KeyCombo(keyCode: 11, modifiers: [.command]), command: .restoreSelection, context: .panelList))
    #expect(throws: Never.self) { try store.save(crossContext) }
}

@Test func menuEntryLookupReflectsProfile() throws {
    let url = keymapTempURL("menu")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)

    // Menu key equivalents come from the global context entry (§6.10).
    #expect(store.entry(for: .reloadPanel, in: .global)?.combo.keyCode == 15)
    #expect(store.entry(for: .goUp, in: .panelList)?.combo.keyCode == 51)
    #expect(store.entry(for: .viewFull, in: .global) == nil)   // not in the test profile
}

@Test func corruptOrForeignUserFileFallsBackToDefault() throws {
    let url = keymapTempURL("corrupt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("{ broken ".utf8))
    let store = KeymapStore(defaultProfiles: try keymapDefaults(), storageURL: url)
    #expect(store.active().id == "tc")
}
