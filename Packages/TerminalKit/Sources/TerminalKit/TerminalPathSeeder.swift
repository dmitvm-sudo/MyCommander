// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.8 «Уточнение T-31» — panel paths enter the PTY only
// through these pure string helpers (unit-tested); the pane just sends the
// result as terminal input. POSIX single-quote escaping is safe for spaces,
// quotes, `$`, `;`, backslashes and unicode without shell interpretation.

/// Pure seeding helpers for the embedded terminal (F-17).
public enum TerminalPathSeeder {
    /// POSIX-safe quoted argument: `'…'` with an embedded `'` → `'\''`.
    public static func posixQuoted(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A complete `cd -- '…'` line the shell executes at once (newline included).
    public static func cdTo(_ url: URL) -> String {
        "cd -- " + posixQuoted(url.path) + "\n"
    }

    /// Only the quoted path, WITHOUT a newline — lands in a typed command
    /// and stays open for editing (⌃⇧V).
    public static func insertSequence(_ url: URL) -> String {
        posixQuoted(url.path)
    }
}
