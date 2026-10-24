// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServicesKit

/// Single dispatch point (docs/SDD/06 §6.10, docs/SDD/11): every action is a
/// `CommandID`; handlers are registered by the owning coordinator classes
/// («все команды реализуются методами coordinator-классов»). The menu carries
/// the command id in `representedObject`, so MenuBuilder stays declarative and
/// menu key equivalents come from the active keymap profile.
@MainActor
final class CommandRouter: NSObject {
    private var handlers: [CommandID: () -> Void] = [:]

    func register(_ command: CommandID, handler: @escaping () -> Void) {
        handlers[command] = handler
    }

    func isRegistered(_ command: CommandID) -> Bool {
        handlers[command] != nil
    }

    /// `true` when a handler exists and ran; unimplemented commands (their
    /// features arrive with later tasks) return `false` and stay out of menus.
    @discardableResult
    func dispatch(_ command: CommandID) -> Bool {
        guard let handler = handlers[command] else { return false }
        handler()
        return true
    }

    /// Menu action entry point: all menu items target this.
    @objc func dispatchMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = CommandID(rawValue: raw)
        else { return }
        dispatch(command)
    }
}
