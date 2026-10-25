// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contracts: docs/SDD/05 §5.7 (KeymapEntry { combo, command, context }), §6.9
// (KeymapStore: profiles TC-style / macOS-style / user, KeyCombo = keyCode +
// modifiers, conflicts forbidden on save), docs/SDD/07 (the keyboard map that
// the default «TC/NC classic» profile mirrors). Storage: keymap.json in
// ~/Library/Application Support/MyCommander/ (§5.7), schema-versioned like
// SessionSnapshot. AppKit-free: modifiers are token sets, the App layer maps
// them to/from NSEvent.ModifierFlags.

/// Every user-visible action (docs/SDD/07 §7.3 «100 % действий доступны
/// клавиатурой» — each entry here is remappable). Commands without a handler
/// yet (operations arrive with T-10+, M3 features later) are still part of the
/// map so profiles stay forward-compatible.
public enum CommandID: String, Codable, Sendable, CaseIterable, Hashable {
    // Navigation (07 §7.3 «Навигация»).
    case cursorUp
    case cursorDown
    case pageUp
    case pageDown
    case firstItem
    case lastItem
    case openItem
    case goUp
    case goHome
    case swapPanels
    case nextTab
    case previousTab
    case newTab
    case closeTab
    case reopenClosedTab
    case reloadPanel
    case focusCommandBar
    case goToFolder

    // Selection (07 §7.3 «Выделение»).
    case toggleSelectionAndMove
    case selectMasked
    case deselectMasked
    case invertAll
    case restoreSelection
    case selectAll

    // Operations (07 §7.3 «Операции»; handlers arrive with T-10+ / M3).
    case viewFile
    case quickLook
    case editFile
    case copyFiles
    case pasteIntoTargetPanel
    case moveRenameFiles
    case makeDirectory
    case deleteFiles
    // Info/properties (F-19, ⌃A / ремап).
    case itemInfo
    case openSettings
    case multiRename
    case comparePanels
    case searchFiles
    case toggleTerminal

    // Display / focus.
    case viewFull
    case viewBrief
    case focusLeft
    case focusRight
}

/// Where a binding is interpreted (docs/SDD/05 §5.7 `CommandContext`).
/// `panelList` = the file table has focus; `global` = menu-level dispatch.
public enum CommandContext: String, Codable, Sendable, CaseIterable, Hashable {
    case global
    case panelList
    case commandBar
    case lister
    case terminal
}

/// AppKit-free modifier token (mapped to/from NSEvent.ModifierFlags in App).
public enum ModifierToken: String, Codable, Sendable, CaseIterable, Hashable {
    case command
    case control
    case option
    case shift
    case function
    case numericPad
}

/// A physical key binding: HID keycode + modifier token set (§6.9 KeyCombo).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Set<ModifierToken>

    public init(keyCode: UInt16, modifiers: Set<ModifierToken> = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// One binding (docs/SDD/05 §5.7): combo → command in a context.
public struct KeymapEntry: Codable, Hashable, Sendable {
    public var combo: KeyCombo
    public var command: CommandID
    public var context: CommandContext

    public init(combo: KeyCombo, command: CommandID, context: CommandContext) {
        self.combo = combo
        self.command = command
        self.context = context
    }
}

/// A named binding set (bundled defaults: «tc» / «macos»; the user profile is
/// a full saved entry list over its chosen base).
public struct KeymapProfile: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var entries: [KeymapEntry]

    public init(id: String, name: String, entries: [KeymapEntry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

public enum KeymapError: Error, LocalizedError, Equatable {
    /// «Конфликты forbidden при сохранении» (§6.9): the same (context, combo)
    /// is bound to two different commands.
    case conflictingBinding(KeyCombo, CommandContext, CommandID, CommandID)

    public var errorDescription: String? {
        switch self {
        case let .conflictingBinding(combo, context, first, second):
            return String(
                localized: "keymap.error.conflict \(combo.keyCode) \(first.rawValue) \(second.rawValue) \(context.rawValue)"
            )
        }
    }
}

/// Persisted user overrides: `keymap.json` (docs/SDD/05 §5.7, schema-versioned).
private struct UserKeymapFile: Codable {
    var schemaVersion: Int
    var profile: KeymapProfile
}

/// Profile store (§6.9). Defaults are handed in as decoded `KeymapProfile`s —
/// the App layer reads the bundled `Resources/keymap-*.json` files; tests pass
/// inline JSON. The active profile persists to `keymap.json` (user remaps);
/// `reset()` clears the file and returns to the bundled default.
public final class KeymapStore: @unchecked Sendable {
    public static let schemaVersion = 1

    public static func defaultStorageURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("keymap.json")
    }

    /// Bundled profiles in priority order; the first is the active default
    /// (docs/SDD/12 T-09: «карта 07 активна» — the TC/NC classic map).
    private let defaultProfiles: [KeymapProfile]
    private let storageURL: URL
    private let lock = NSLock()
    private var cachedActive: KeymapProfile?

    public init(defaultProfiles: [KeymapProfile], storageURL: URL = KeymapStore.defaultStorageURL()) {
        self.defaultProfiles = defaultProfiles
        self.storageURL = storageURL
    }

    /// The active profile: the saved user profile, or the first bundled
    /// default. A missing, corrupt, or foreign-version file is not an error —
    /// the default map just stays active (T-08 SessionStore semantics).
    public func active() -> KeymapProfile {
        lock.lock()
        defer { lock.unlock() }
        if let cachedActive { return cachedActive }
        let profile = loadFromDisk() ?? (defaultProfiles.first ?? KeymapProfile(id: "tc", name: "TC/NC classic", entries: []))
        cachedActive = profile
        return profile
    }

    private func loadFromDisk() -> KeymapProfile? {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let file = try? JSONDecoder().decode(UserKeymapFile.self, from: data),
              file.schemaVersion == Self.schemaVersion
        else { return nil }
        return file.profile
    }

    /// Saves a user profile. Conflicting bindings (same context + combo on two
    /// different commands) are forbidden — the save is blocked (§6.9).
    public func save(_ profile: KeymapProfile) throws {
        if let conflict = Self.firstConflict(in: profile.entries) {
            throw KeymapError.conflictingBinding(
                conflict.combo,
                conflict.context,
                conflict.first,
                conflict.second
            )
        }
        let file = UserKeymapFile(schemaVersion: Self.schemaVersion, profile: profile)
        let data = try JSONEncoder().encode(file)
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        lock.lock()
        cachedActive = profile
        lock.unlock()
    }

    /// «Сброс к дефолту — одной кнопкой» (F-7): drops user overrides.
    public func reset() {
        try? FileManager.default.removeItem(at: storageURL)
        lock.lock()
        cachedActive = nil
        lock.unlock()
    }

    /// Combo lookup: which command fires in `context` (exact match; modifiers
    /// must be equal — no fuzzy modifier logic in the каркас).
    public func command(for combo: KeyCombo, in context: CommandContext) -> CommandID? {
        active().entries.first { $0.context == context && $0.combo == combo }?.command
    }

    /// Reverse lookup for the menu: the global binding of a command (menu
    /// key equivalents reflect the active profile — docs/SDD/06 §6.10).
    public func entry(for command: CommandID, in context: CommandContext) -> KeymapEntry? {
        active().entries.first { $0.command == command && $0.context == context }
    }

    // MARK: conflicts

    public struct Conflict {
        public let combo: KeyCombo
        public let context: CommandContext
        public let first: CommandID
        public let second: CommandID
    }

    /// First duplicate (context, combo) pair across entries bound to different
    /// commands. The same command re-entered is harmless.
    public static func firstConflict(in entries: [KeymapEntry]) -> Conflict? {
        var owner: [KeyCombo: [CommandContext: CommandID]] = [:]
        for entry in entries {
            if let existing = owner[entry.combo]?[entry.context], existing != entry.command {
                return Conflict(
                    combo: entry.combo,
                    context: entry.context,
                    first: existing,
                    second: entry.command
                )
            }
            owner[entry.combo, default: [:]][entry.context] = entry.command
        }
        return nil
    }
}
