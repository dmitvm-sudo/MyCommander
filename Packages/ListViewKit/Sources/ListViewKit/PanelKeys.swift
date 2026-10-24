// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// Keyboard semantics of one panel (docs/SDD/02 F-1/F-3/F-10, F-4 start):
// Enter opens (accepts the filter first), ⌘↑/Backspace climb, Space/Ins toggle
// the selection, Num +/−/* and Num / drive mask-based selection, printable
// keystrokes type-to-filter, ⌃1/⌃2 switch the view mode. The classifier is a
// pure function so the dispatch stays unit-testable without synthesizing
// NSEvents; `FileListView` interprets the commands against its view model.

enum PanelKeyCommand: Equatable {
    /// Enter / numeric Enter: accept the filter when active, otherwise open.
    case acceptOrOpen
    case goToParent
    case toggleSelectionAndMove
    case selectMasked
    case deselectMasked
    case invertAll
    case restoreSelection
    case filterCharacter(Character)
    case backspace
    case escape
    case viewFull
    case viewBrief
    /// Not a panel command — falls through to AppKit (arrows, copy, ...).
    case passToSuper
}

enum PanelKeys {
    private static let returnKeyCode: UInt16 = 36
    private static let numpadEnterKeyCode: UInt16 = 76
    private static let upArrowKeyCode: UInt16 = 126
    private static let spaceKeyCode: UInt16 = 49
    private static let insertKeyCode: UInt16 = 114
    private static let numpadPlusKeyCode: UInt16 = 69
    private static let numpadMinusKeyCode: UInt16 = 78
    private static let numpadAsteriskKeyCode: UInt16 = 67
    private static let numpadSlashKeyCode: UInt16 = 75
    private static let backspaceKeyCode: UInt16 = 51
    private static let escapeKeyCode: UInt16 = 53

    static func classify(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> PanelKeyCommand {
        var modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        modifiers.remove([.function, .capsLock, .shift])

        switch keyCode {
        case returnKeyCode, numpadEnterKeyCode:
            return modifiers.isEmpty ? .acceptOrOpen : .passToSuper
        case upArrowKeyCode:
            return modifiers == .command ? .goToParent : .passToSuper
        case insertKeyCode:
            return modifiers.isEmpty ? .toggleSelectionAndMove : .passToSuper
        case spaceKeyCode:
            return modifiers.isEmpty ? .toggleSelectionAndMove : .passToSuper
        case numpadPlusKeyCode:
            return modifiers.isEmpty ? .selectMasked : .passToSuper
        case numpadMinusKeyCode:
            return modifiers.isEmpty ? .deselectMasked : .passToSuper
        case numpadAsteriskKeyCode:
            return modifiers.isEmpty ? .invertAll : .passToSuper
        case numpadSlashKeyCode:
            return modifiers.isEmpty ? .restoreSelection : .passToSuper
        case backspaceKeyCode:
            return modifiers.isEmpty ? .backspace : .passToSuper
        case escapeKeyCode:
            return modifiers.isEmpty ? .escape : .passToSuper
        default:
            break
        }

        // ⌃1/⌃2 — view mode (F-4 acceptance: remap keys arrive with T-09).
        if modifiers == .control, let characters {
            switch characters {
            case "1": return .viewFull
            case "2": return .viewBrief
            default: break
            }
        }

        // Num +/−/*// typed through characters (some layouts do not deliver the
        // dedicated key codes).
        if characters?.count == 1, modifiers.isEmpty || modifiers == .numericPad {
            switch characters {
            case "+": return .selectMasked
            case "-": return .deselectMasked
            case "*": return .invertAll
            case "/": return .restoreSelection
            default: break
            }
        }

        // Type-to-filter (F-10): every remaining printable keystroke feeds the
        // quick filter (Space stays a selection key per F-3). Private-use
        // scalars (F1–F12 arrive as 0xF704… in `characters`) are not text —
        // they belong to the keymap layer, not the filter.
        if modifiers.isEmpty, let characters,
           let character = characters.first,
           character != " ",
           character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xE000 })
        {
            return .filterCharacter(character)
        }
        return .passToSuper
    }
}
