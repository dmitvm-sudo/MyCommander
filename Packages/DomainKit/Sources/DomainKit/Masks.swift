// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Masks and size formatting (docs/SDD/11 map: "глоб-маски, размеры (200 кБ «1,2 MB»)").

/// One glob pattern: `*` (any sequence), `?` (any single character),
/// `[abc]` / `[a-z]` (character class, `!` or `^` first for negation; a `]`
/// right after `[` is a literal). Matching is anchored to the whole name.
/// There is no backslash escaping in classic TC-style masks.
public struct GlobMask: Sendable, Hashable {
    public let pattern: String
    public let caseSensitive: Bool

    private enum Atom: Sendable, Hashable {
        case anySequence
        case anyCharacter
        case literals([Character])
        case set(required: Bool, exacts: Set<Character>, ranges: [ClosedRange<Character>])
    }

    private let atoms: [Atom]

    public init(_ pattern: String, caseSensitive: Bool = false) {
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.atoms = GlobMask.compile(pattern, caseSensitive: caseSensitive)
    }

    public func matches(_ name: String) -> Bool {
        let nameChars = Array(caseSensitive ? name : name.lowercased())
        var seenReturns = Set<[Int]>()
        return match(atoms, 0, nameChars, 0, &seenReturns)
    }

    private func match(
        _ atoms: [Atom], _ atomIndex: Int,
        _ nameChars: [Character], _ charIndex: Int,
        _ memo: inout Set<[Int]>
    ) -> Bool {
        if atomIndex == atoms.count { return charIndex == nameChars.count }
        let state = [atomIndex, charIndex]
        guard memo.insert(state).inserted else { return false }

        switch atoms[atomIndex] {
        case .anySequence:
            for next in charIndex...nameChars.count where match(atoms, atomIndex + 1, nameChars, next, &memo) {
                return true
            }
            return false
        case .anyCharacter:
            guard charIndex < nameChars.count else { return false }
            return match(atoms, atomIndex + 1, nameChars, charIndex + 1, &memo)
        case .literals(let expected):
            guard charIndex + expected.count <= nameChars.count,
                  Array(nameChars[charIndex ..< charIndex + expected.count]) == expected
            else { return false }
            return match(atoms, atomIndex + 1, nameChars, charIndex + expected.count, &memo)
        case .set(let required, let exacts, let ranges):
            guard charIndex < nameChars.count else { return false }
            let char = nameChars[charIndex]
            let positive = exacts.contains(char) || ranges.contains { $0.contains(char) }
            guard positive == required else { return false }
            return match(atoms, atomIndex + 1, nameChars, charIndex + 1, &memo)
        }
    }

    private static func compile(_ pattern: String, caseSensitive: Bool) -> [Atom] {
        let source = Array(caseSensitive ? pattern : pattern.lowercased())
        var result: [Atom] = []
        var index = 0
        while index < source.count {
            let char = source[index]
            switch char {
            case "*":
                result.append(.anySequence)
                index += 1
            case "?":
                result.append(.anyCharacter)
                index += 1
            case "[":
                if let atom = parseSet(from: source, at: index) {
                    result.append(atom.atom)
                    index = atom.next
                } else {
                    result.append(.literals([char]))
                    index += 1
                }
            default:
                var literals: [Character] = [char]
                index += 1
                while index < source.count, !"*?[".contains(source[index]) {
                    literals.append(source[index])
                    index += 1
                }
                result.append(.literals(literals))
            }
        }
        return result
    }

    private static func parseSet(from source: [Character], at openIndex: Int) -> (atom: Atom, next: Int)? {
        var index = openIndex + 1
        let characters = Array(source)
        guard index < characters.count else { return nil }

        var negated = false
        if characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }

        var items: [Character] = []
        var ranges: [ClosedRange<Character>] = []

        // A `]` right after the (optional) negation is a literal member.
        while index < characters.count {
            let char = characters[index]
            if char == "]" {
                return (Atom.set(required: !negated, exacts: Set(items), ranges: ranges), index + 1)
            }
            if char == "-", let previous = items.popLast() {
                // "a-z": previous item is the range start; consume the next one.
                guard index + 1 < characters.count, characters[index + 1] != "]" else {
                    items.append(previous)
                    items.append(char)
                    index += 1
                    continue
                }
                let upper = characters[index + 1]
                if previous <= upper { ranges.append(previous...upper) } else { items.append(previous); items.append(upper) }
                index += 2
            } else {
                items.append(char)
                index += 1
            }
        }
        return nil // unmatched "[": treated as literal by the caller
    }
}

/// A set of glob patterns whose union defines the selection, TC-style
/// (`+`/`−`/`*` selection dialogs, F-3; quick filter presets).
public struct FileMask: Sendable, Hashable {
    public var masks: [GlobMask]

    public init(_ globs: [String], caseSensitive: Bool = false) {
        self.masks = globs.map { GlobMask($0, caseSensitive: caseSensitive) }
    }

    public func matches(_ name: String) -> Bool {
        masks.contains { $0.matches(name) }
    }
}

/// Deterministic "human" byte formatting (the «200 кБ / 1,2 MB» family).
/// `.binary` uses 1024-base units ("KB/MB/GB" — file-manager convention, default),
/// `.decimal` uses 1000-base ("kB/MB" — Finder style).
/// The numeric part is locale-aware (decimal separator, grouping); unit words are
/// latin — localized unit words arrive with L10n (T-35).
public enum ByteSizeFormat {
    public enum Style: Sendable {
        case binary
        case decimal
    }

    private static let binaryUnits = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    private static let decimalUnits = ["bytes", "kB", "MB", "GB", "TB", "PB"]

    public static func string(_ bytes: Int64, style: Style = .binary, locale: Locale? = nil) -> String {
        let isBinary = (style == .binary)
        let factor: Double = isBinary ? 1024 : 1000
        let units = isBinary ? binaryUnits : decimalUnits

        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= factor, unitIndex < units.count - 1 {
            value /= factor
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(max(0, bytes)) \(units[0])"
        }
        let formatter = NumberFormatter()
        formatter.locale = locale ?? Locale.current
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: value)) ?? "0") \(units[unitIndex])"
    }
}
