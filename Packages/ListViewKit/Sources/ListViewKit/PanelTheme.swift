// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// Contract: docs/SDD/06 §6.9 «Уточнение T-33» (F-23 частично) — color tokens
// of the PANEL LIST surface. The App layer maps the persisted theme string to
// these tokens (plus `NSApp.appearance` for light/dark) and pushes them live
// through `FileListView.applyTheme`; nil restores system colors. The ncBlue
// preset paints ONLY the panel lists — tab chrome, dialogs, Lister, terminal
// stay system (skin-extension lives in v1.x with its own SDD note).

/// Optional-color token set; constructed in the App layer (or by tests).
/// `@unchecked Sendable`: NSColor lacks the annotation, the struct is
/// immutable after construction.
public struct PanelTheme: Equatable, @unchecked Sendable {
    public let rowBackground: NSColor
    public let rowAlternate: NSColor?
    public let rowText: NSColor
    public let rowSecondaryText: NSColor

    public init(
        rowBackground: NSColor,
        rowAlternate: NSColor?,
        rowText: NSColor,
        rowSecondaryText: NSColor
    ) {
        self.rowBackground = rowBackground
        self.rowAlternate = rowAlternate
        self.rowText = rowText
        self.rowSecondaryText = rowSecondaryText
    }

    /// Classic NC-blue panel skin: solid blue surface with white primary text
    /// and a dimmed secondary over it (hidden-file color, meta columns).
    public static let ncBlueClassic = PanelTheme(
        rowBackground: NSColor(srgbRed: 0, green: 0, blue: 0.62, alpha: 1),
        rowAlternate: NSColor(srgbRed: 0, green: 0, blue: 0.75, alpha: 1),
        rowText: .white,
        rowSecondaryText: NSColor(white: 0.82, alpha: 1)
    )
}
