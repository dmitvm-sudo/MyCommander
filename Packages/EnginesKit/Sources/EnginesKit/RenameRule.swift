// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-28) + F-14 — the multi-rename
// rule block. Pure value type: no I/O, no AppKit — the planner (RenamePlanner)
// applies it; the dialog (ListViewKit) edits it; it is Codable so the dialog
// can remember the last rule in the session layer later.

/// Letter case applied to the STEM after the replace block.
public enum RenameCaseStyle: String, Codable, Sendable, CaseIterable {
    case unchanged
    case lowercase
    case uppercase
}

/// What happens to the extension (suffix after the LAST dot; directories and
/// dot-less names have none). `.replace` overrides the `[E]` token's source.
public enum RenameExtensionMode: Sendable, Equatable {
    case keep
    case replace(String)
    case remove
}

/// The F-14 rule block (06 §6.6 уточнение T-28): template tokens `[N]` (the
/// processed old stem), `[C]` (the counter), `[E]` (the extension) — the
/// template is the ONLY source of the new name's shape.
public struct RenameRule: Codable, Sendable, Equatable {
    public var template: String
    public var counterStart: Int
    public var counterStep: Int
    /// Pad width; `0` = no padding («[C] без pad = как есть»).
    public var counterPad: Int
    public var find: String
    public var replacement: String
    public var isRegex: Bool
    public var caseStyle: RenameCaseStyle
    public var extensionMode: RenameExtensionMode

    public init(
        template: String = "[N]",
        counterStart: Int = 1,
        counterStep: Int = 1,
        counterPad: Int = 0,
        find: String = "",
        replacement: String = "",
        isRegex: Bool = false,
        caseStyle: RenameCaseStyle = .unchanged,
        extensionMode: RenameExtensionMode = .keep
    ) {
        self.template = template
        self.counterStart = counterStart
        self.counterStep = counterStep
        self.counterPad = counterPad
        self.find = find
        self.replacement = replacement
        self.isRegex = isRegex
        self.caseStyle = caseStyle
        self.extensionMode = extensionMode
    }

    public enum CodingKeys: String, CodingKey {
        case template, counterStart, counterStep, counterPad, find, replacement, isRegex, caseStyle
        case extensionMode
    }

    // Codable: `RenameExtensionMode` has an associated value — synthesize via
    // a flat (mode, replacementValue) pair.
    private enum FlatKeys: String, CodingKey {
        case mode, replacementValue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(String.self, forKey: .template)
        counterStart = try c.decode(Int.self, forKey: .counterStart)
        counterStep = try c.decode(Int.self, forKey: .counterStep)
        counterPad = try c.decode(Int.self, forKey: .counterPad)
        find = try c.decode(String.self, forKey: .find)
        replacement = try c.decode(String.self, forKey: .replacement)
        isRegex = try c.decode(Bool.self, forKey: .isRegex)
        caseStyle = try c.decode(RenameCaseStyle.self, forKey: .caseStyle)
        let ext = try c.nestedContainer(keyedBy: FlatKeys.self, forKey: .extensionMode)
        let mode = try ext.decode(String.self, forKey: .mode)
        switch mode {
        case "keep": extensionMode = .keep
        case "remove": extensionMode = .remove
        case "replace": extensionMode = .replace(try ext.decode(String.self, forKey: .replacementValue))
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: ext, debugDescription: "unknown extension mode \(mode)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(template, forKey: .template)
        try c.encode(counterStart, forKey: .counterStart)
        try c.encode(counterStep, forKey: .counterStep)
        try c.encode(counterPad, forKey: .counterPad)
        try c.encode(find, forKey: .find)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(isRegex, forKey: .isRegex)
        try c.encode(caseStyle, forKey: .caseStyle)
        var ext = c.nestedContainer(keyedBy: FlatKeys.self, forKey: .extensionMode)
        switch extensionMode {
        case .keep: try ext.encode("keep", forKey: .mode)
        case .remove: try ext.encode("remove", forKey: .mode)
        case .replace(let value):
            try ext.encode("replace", forKey: .mode)
            try ext.encode(value, forKey: .replacementValue)
        }
    }
}
