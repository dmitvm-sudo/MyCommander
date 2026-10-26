// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServicesKit

/// Main menu = reflection of the active keymap profile (docs/SDD/11:
/// «главное меню = отражение keymap-профиля», docs/SDD/06 §6.10: «пользователь
/// в меню видит хоткеи реального профиля»). Declarative: a section/item spec
/// lists CommandIDs, the router decides what is reachable (only commands with
/// registered handlers appear), the keymap supplies key equivalents.
@MainActor
enum MenuBuilder {
    private struct ItemSpec {
        let titleKey: String
        let command: CommandID
    }

    private struct SectionSpec {
        let titleKey: String
        let items: [ItemSpec]
    }

    private static let sections: [SectionSpec] = [
        SectionSpec(titleKey: "menu.go", items: [
            ItemSpec(titleKey: "menu.parentDirectory", command: .goUp),
            ItemSpec(titleKey: "menu.home", command: .goHome),
            ItemSpec(titleKey: "menu.reload", command: .reloadPanel),
            ItemSpec(titleKey: "menu.connectSftp", command: .connectSftp),
            ItemSpec(titleKey: "menu.openSettings", command: .openSettings),
        ]),
        SectionSpec(titleKey: "menu.tabs", items: [
            ItemSpec(titleKey: "menu.newTab", command: .newTab),
            ItemSpec(titleKey: "menu.closeTab", command: .closeTab),
            ItemSpec(titleKey: "menu.reopenClosedTab", command: .reopenClosedTab),
            ItemSpec(titleKey: "menu.nextTab", command: .nextTab),
            ItemSpec(titleKey: "menu.previousTab", command: .previousTab),
        ]),
        SectionSpec(titleKey: "menu.view", items: [
            ItemSpec(titleKey: "menu.focusLeft", command: .focusLeft),
            ItemSpec(titleKey: "menu.focusRight", command: .focusRight),
            ItemSpec(titleKey: "menu.swapPanels", command: .swapPanels),
            ItemSpec(titleKey: "menu.viewFull", command: .viewFull),
            ItemSpec(titleKey: "menu.viewBrief", command: .viewBrief),
            // F-17а (T-14): ⌘L command bar focus.
            ItemSpec(titleKey: "menu.commandBar", command: .focusCommandBar),
        ]),
        SectionSpec(titleKey: "menu.selection", items: [
            ItemSpec(titleKey: "menu.selectAll", command: .selectAll),
            ItemSpec(titleKey: "menu.invertSelection", command: .invertAll),
            ItemSpec(titleKey: "menu.restoreSelection", command: .restoreSelection),
            ItemSpec(titleKey: "menu.selectMasked", command: .selectMasked),
            ItemSpec(titleKey: "menu.deselectMasked", command: .deselectMasked),
        ]),
        // Operations (T-11/T-13): F-5 file engine menu surface; items appear
        // only when their handler is registered (MenuBuilder contract).
        SectionSpec(titleKey: "menu.operations", items: [
            ItemSpec(titleKey: "menu.viewFile", command: .viewFile),
            ItemSpec(titleKey: "menu.quickLook", command: .quickLook),
            ItemSpec(titleKey: "menu.editFile", command: .editFile),
            ItemSpec(titleKey: "menu.copyFiles", command: .copyFiles),
            ItemSpec(titleKey: "menu.moveFiles", command: .moveRenameFiles),
            ItemSpec(titleKey: "menu.deleteFiles", command: .deleteFiles),
            ItemSpec(titleKey: "menu.packFiles", command: .packFiles),
            ItemSpec(titleKey: "menu.multiRename", command: .multiRename),
            ItemSpec(titleKey: "menu.comparePanels", command: .comparePanels),
            ItemSpec(titleKey: "menu.searchFiles", command: .searchFiles),
            ItemSpec(titleKey: "menu.undo", command: .undo),
            ItemSpec(titleKey: "menu.itemInfo", command: .itemInfo),
            // F-17 (T-31): embedded terminal (⌃`) and the path paste (⌃⇧V).
            ItemSpec(titleKey: "menu.terminal", command: .toggleTerminal),
            ItemSpec(titleKey: "menu.insertPath", command: .pastePath),
        ]),
    ]

    static func build(router: CommandRouter, keymap: KeymapStore, locations: LocationsStore? = nil) -> NSMenu {
        let main = NSMenu()

        // Application menu (nil-target responder chain item).
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: String(localized: "menu.appName"))
        appMenu.addItem(withTitle: String(localized: "menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        for section in sections {
            let item = NSMenuItem()
            let menu = NSMenu(title: String(localized: String.LocalizationValue(section.titleKey)))
            for spec in section.items where router.isRegistered(spec.command) {
                menu.addItem(Self.makeItem(spec.command, titleKey: spec.titleKey, router: router, keymap: keymap))
            }
            item.submenu = menu
            main.addItem(item)
        }

        // T-26 (F-11): the Locations section — Add bookmark / history / the
        // 9 hotlist slots with their live bookmark names (no hotlist → «Slot N»).
        if let locations {
            let item = NSMenuItem()
            let menu = NSMenu(title: String(localized: "menu.locations"))
            for (command, titleKey) in [
                (CommandID.bookmarkAdd, "menu.bookmarkAdd"),
                (CommandID.openLocations, "menu.openLocations"),
                (CommandID.navigateBack, "menu.navigateBack"),
                (CommandID.navigateForward, "menu.navigateForward"),
            ] where router.isRegistered(command) {
                menu.addItem(Self.makeItem(command, titleKey: titleKey, router: router, keymap: keymap))
            }
            let hotSlotCommands: [(CommandID, Int)] = [
                (.hotSlot1, 1), (.hotSlot2, 2), (.hotSlot3, 3),
                (.hotSlot4, 4), (.hotSlot5, 5), (.hotSlot6, 6),
                (.hotSlot7, 7), (.hotSlot8, 8), (.hotSlot9, 9),
            ]
            for (command, slot) in hotSlotCommands where router.isRegistered(command) {
                let title: String
                if let bookmark = locations.hotSlot(slot) {
                    title = "[\(slot)] \(bookmark.name)"
                } else {
                    title = String(format: String(localized: "menu.hotSlotFormat"), slot)
                }
                let entry = keymap.entry(for: command, in: .global)
                    ?? keymap.entry(for: command, in: .panelList)
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(CommandRouter.dispatchMenuItem(_:)),
                    keyEquivalent: entry.flatMap { keyEquivalent(for: $0.combo.keyCode) } ?? ""
                )
                if let entry {
                    menuItem.keyEquivalentModifierMask = modifierMask(for: entry.combo.modifiers)
                }
                menuItem.target = router
                menuItem.representedObject = command.rawValue
                menu.addItem(menuItem)
            }
            item.submenu = menu
            main.addItem(item)
        }

    // Window (nil-target responder chain actions).
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "menu.window"))
        windowMenu.addItem(withTitle: String(localized: "menu.miniaturize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    /// One routed menu item (keymap-driven key equivalent; T-13 contract).
    private static func makeItem(
        _ command: CommandID, titleKey: String, router: CommandRouter, keymap: KeymapStore
    ) -> NSMenuItem {
        // T-13: panel-list commands (F3–F8 in the 07 map) surface their
        // profile binding in the menu too — the menu is the only
        // keyboard path that fires them (MenuBuilder contract 06 §6.10).
        let entry = keymap.entry(for: command, in: .global)
            ?? keymap.entry(for: command, in: .panelList)
        let menuItem = NSMenuItem(
            title: String(localized: String.LocalizationValue(titleKey)),
            action: #selector(CommandRouter.dispatchMenuItem(_:)),
            keyEquivalent: entry.flatMap { keyEquivalent(for: $0.combo.keyCode) } ?? ""
        )
        if let entry {
            menuItem.keyEquivalentModifierMask = modifierMask(for: entry.combo.modifiers)
        }
        menuItem.target = router
        menuItem.representedObject = command.rawValue
        return menuItem
    }

    // MARK: ANSI-US keycode → menu key equivalent

    /// Menu display for the ANSI-US mapping of 07 §7.3; F-keys render as «F3»
    /// etc. through the NSFunctionKey scalars (T-13: panelList entries reached
    /// the menu).
    static func keyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 99: return String(UnicodeScalar(NSF3FunctionKey)!)         // F3
        case 118: return String(UnicodeScalar(NSF4FunctionKey)!)        // F4
        case 96: return String(UnicodeScalar(NSF5FunctionKey)!)         // F5
        case 97: return String(UnicodeScalar(NSF6FunctionKey)!)         // F6
        case 98: return String(UnicodeScalar(NSF7FunctionKey)!)         // F7
        case 100: return String(UnicodeScalar(NSF8FunctionKey)!)        // F8
        case 101: return String(UnicodeScalar(NSF9FunctionKey)!)        // F9
        case 122: return String(UnicodeScalar(NSF1FunctionKey)!)        // F1
        case 120: return String(UnicodeScalar(NSF2FunctionKey)!)        // F2
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 30: return "]"
        case 33: return "["
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 25: return "9"
        case 26: return "7"
        case 29: return "8"
        case 31: return "o"
        case 32: return "u"
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 39: return "k"
        case 43: return ","
        case 44: return "-"
        case 45: return "."
        case 46: return "/"
        case 50: return "`"   // T-31: ⌃` — embedded terminal (ANSI-US grave)
        case 67: return "*"
        case 69: return "+"
        case 75: return "/"
        case 78: return "-"
        case 126: return String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        default: return nil
        }
    }

    static func modifierMask(for tokens: Set<ModifierToken>) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for token in tokens {
            switch token {
            case .command: flags.insert(.command)
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .function: flags.insert(.function)
            case .numericPad: break   // display-only tokens carry no menu mask
            }
        }
        return flags
    }
}

extension NSMenu {
    @discardableResult
    fileprivate func addItem(withTitle title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
