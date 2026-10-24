// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ListViewKit

/// Main menu = today's hand-built slice of the future keymap profile reflection
/// (docs/SDD/11: MenuBuilder — «главное меню = отражение keymap-профиля»).
/// Full CommandID-routing and keymap files belong to T-09; until then the menu
/// targets PanelsCoordinator methods directly.
@MainActor
enum MenuBuilder {
    private static let upArrowKeyEquivalent = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)

    static func build(coordinator: PanelsCoordinator) -> NSMenu {
        let main = NSMenu()

        // Application menu.
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: String(localized: "menu.appName"))
        appMenu.addItem(withTitle: String(localized: "menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Go.
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: String(localized: "menu.go"))
        goMenu.addItem(withTitle: String(localized: "menu.parentDirectory"), action: #selector(PanelsCoordinator.mcGoUp(_:)), keyEquivalent: upArrowKeyEquivalent)
        goMenu.addItem(withTitle: String(localized: "menu.home"), action: #selector(PanelsCoordinator.mcGoHome(_:)), keyEquivalent: "h")
            .withKeyEquivalentModifierMask([.command, .shift])
        goMenu.addItem(withTitle: String(localized: "menu.reload"), action: #selector(PanelsCoordinator.mcReload(_:)), keyEquivalent: "r")
        goItem.submenu = goMenu
        main.addItem(goItem)

        // View.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "menu.view"))
        viewMenu.addItem(withTitle: String(localized: "menu.focusLeft"), action: #selector(PanelsCoordinator.mcFocusLeft(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: String(localized: "menu.focusRight"), action: #selector(PanelsCoordinator.mcFocusRight(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: String(localized: "menu.swapPanels"), action: #selector(PanelsCoordinator.mcSwapPanels(_:)), keyEquivalent: "u")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "menu.viewFull"), action: #selector(PanelsCoordinator.mcViewFull(_:)), keyEquivalent: "1")
            .withKeyEquivalentModifierMask(.control)
        viewMenu.addItem(withTitle: String(localized: "menu.viewBrief"), action: #selector(PanelsCoordinator.mcViewBrief(_:)), keyEquivalent: "2")
            .withKeyEquivalentModifierMask(.control)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "menu.window"))
        windowMenu.addItem(withTitle: String(localized: "menu.miniaturize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        // Explicit targets for coordinator actions; nil-target items walk the
        // responder chain (terminate/miniaturize/zoom).
        for menu in [goMenu, viewMenu] {
            for item in menu.items where item.action != nil {
                item.target = coordinator
            }
        }

        return main
    }
}

extension NSMenuItem {
    @discardableResult
    fileprivate func withKeyEquivalentModifierMask(_ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        keyEquivalentModifierMask = mask
        return self
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
