// SPDX-License-Identifier: GPL-3.0-or-later

/// Single model of focus (docs/SDD/06 §6.1): exactly one panel is active at a
/// time; `CommandRouter` (T-09) will always dispatch with
/// `activePanel`/`otherPanel` context derived from this controller.
@MainActor
public final class FocusController {
    public enum PanelSide: Hashable, CaseIterable, Sendable {
        case left
        case right
    }

    public private(set) var activePanel: PanelSide = .left

    public init() {}

    /// Fires on every focus switch (owner moves first-responder + visual state).
    public var onFocusChanged: ((PanelSide) -> Void)?

    public func activate(_ panel: PanelSide) {
        guard activePanel != panel else { return }
        activePanel = panel
        onFocusChanged?(panel)
    }

    public func toggle() {
        activate(activePanel == .left ? .right : .left)
    }

    public var otherPanel: PanelSide {
        activePanel == .left ? .right : .left
    }
}
