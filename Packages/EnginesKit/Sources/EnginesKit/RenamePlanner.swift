// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-28) + F-14 — the multi-rename
// planner. PURE: no I/O, no AppKit — the preview must handle 10 000 names
// in ≤ 1 s (F-14 acceptance) and the dialog calls it on every keystroke.
// Commit builds ONE `.move` TransferPlan (same-volume rename(2), journal
// `renameBack` → undo F-6 for free) through the unified queue (05 §5.6
// уточнение T-27).

/// One preview row: the item, its new name, and the rule index that produced it.
public struct RenamePair: Sendable {
    public let item: VFSItem
    public let newName: String

    public init(item: VFSItem, newName: String) {
        self.item = item
        self.newName = newName
    }
}

public enum RenameConflictKind: Sendable, Equatable {
    /// The result equals another result of the plan.
    case duplicateTarget(newName: String)
    /// The name is already taken in the directory (by a DIFFERENT item).
    case targetExists(newName: String)
    /// Empty, contains «/», or is «.»/«..».
    case invalidName(newName: String)
}

public struct RenameConflict: Sendable, Equatable {
    public let index: Int   // index into RenamePlan.pairs
    public let kind: RenameConflictKind
}

public struct RenamePlan: Sendable {
    public let pairs: [RenamePair]
    public let conflicts: [RenameConflict]

    public init(pairs: [RenamePair], conflicts: [RenameConflict]) {
        self.pairs = pairs
        self.conflicts = conflicts
    }

    /// `true` when every row can be committed as-is.
    public var isValid: Bool { conflicts.isEmpty }
}

public enum RenamePlanner {
    /// Splits «name.ext» into (stem, extension) — the suffix after the LAST
    /// dot; no dot (or a leading-only dot) means no extension. Directories
    /// NEVER have an extension (F-14: «name.ext.tar» dirs aside, a dir named
    /// «v1.2» renames whole).
    public static func stemExtension(of name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        guard !isDirectory, let lastDot = name.lastIndex(of: "."), lastDot != name.startIndex else {
            return (name, "")
        }
        let stem = String(name[name.startIndex ..< lastDot])
        let ext = String(name[name.index(after: lastDot)...])
        return (stem, ext)
    }

    /// Plans the batch. `occupiedNames` = the directory's CURRENT names (the
    /// panel already holds them); renaming an item to its own name is not a
    /// conflict. Unchanged results (new == old) are NOT planned.
    public static func plan(items: [VFSItem], rule: RenameRule, occupiedNames: Set<String>) -> RenamePlan {
        var pairs: [RenamePair] = []
        var conflicts: [RenameConflict] = []
        var plannedNames: [String: Int] = [:]   // new name → first pair index

        var counter = rule.counterStart
        for item in items {
            let isDirectory: Bool
            if case .directory = item.kind { isDirectory = true } else { isDirectory = false }
            let (stem, ext) = stemExtension(of: item.name, isDirectory: isDirectory)
            var processed = applyReplace(stem, rule: rule)
            processed = applyCase(processed, style: rule.caseStyle)

            let counterText: String
            if rule.counterPad > 0 {
                counterText = String(counter).leftPadded(toWidth: rule.counterPad)
            } else {
                counterText = String(counter)
            }
            counter += rule.counterStep

            // The template is the only source of the new name's shape;
            // `[E]` resolves by the extension mode when present.
            var newName = rule.template
                .replacingOccurrences(of: "[N]", with: processed)
                .replacingOccurrences(of: "[C]", with: counterText)
            if newName.contains("[E]") {
                let resolvedExt: String
                if isDirectory {
                    resolvedExt = ""   // directories rename whole (06 §6.6 T-28)
                } else {
                    switch rule.extensionMode {
                    case .keep: resolvedExt = ext
                    case .replace(let replacement): resolvedExt = replacement
                    case .remove: resolvedExt = ""
                    }
                }
                newName = newName.replacingOccurrences(of: "[E]", with: resolvedExt)
            } else {
                // No [E] token: the mode still decides the final suffix —
                // but never for directories (no extension to speak of).
                if isDirectory {
                    // nothing to append
                } else {
                    switch rule.extensionMode {
                    case .keep:
                        if !ext.isEmpty { newName += ".\(ext)" }
                    case .replace(let replacement):
                        if !replacement.isEmpty { newName += ".\(replacement)" }
                    case .remove:
                        break
                    }
                }
            }

            if newName == item.name {
                continue   // unchanged — not planned (§6.6)
            }
            if newName.isEmpty || newName == "." || newName == ".." || newName.contains("/") {
                conflicts.append(RenameConflict(index: pairs.count, kind: .invalidName(newName: newName)))
                pairs.append(RenamePair(item: item, newName: newName))
                continue
            }

            if let firstIndex = plannedNames[newName] {
                conflicts.append(RenameConflict(index: pairs.count, kind: .duplicateTarget(newName: newName)))
                _ = firstIndex
            } else if occupiedNames.contains(newName), !occupiedOnlyBySelf(newName: newName, item: item, items: items) {
                conflicts.append(RenameConflict(index: pairs.count, kind: .targetExists(newName: newName)))
            }
            plannedNames[newName] = pairs.count
            pairs.append(RenamePair(item: item, newName: newName))
        }
        return RenamePlan(pairs: pairs, conflicts: conflicts)
    }

    /// «Переименование в то же имя у самого файла не конфликт»: `newName` taken
    /// by one of the PLANNED items (e.g. swap chains a→b while b renames away)
    /// is fine — the batch executes in one sorted pass.
    private static func occupiedOnlyBySelf(newName: String, item: VFSItem, items: [VFSItem]) -> Bool {
        items.contains { $0.name == newName }
    }

    /// The replace block: plain substring or regex (`NSRegularExpression`).
    private static func applyReplace(_ stem: String, rule: RenameRule) -> String {
        guard !rule.find.isEmpty else { return stem }
        if rule.isRegex {
            guard let regex = try? NSRegularExpression(pattern: rule.find) else { return stem }
            let range = NSRange(stem.startIndex..., in: stem)
            return regex.stringByReplacingMatches(in: stem, range: range, withTemplate: rule.replacement)
        }
        return stem.replacingOccurrences(of: rule.find, with: rule.replacement)
    }

    private static func applyCase(_ stem: String, style: RenameCaseStyle) -> String {
        switch style {
        case .unchanged: return stem
        case .lowercase: return stem.lowercased()
        case .uppercase: return stem.uppercased()
        }
    }

    /// ONE `.move` plan for the valid subset (sorted stable by old name —
    /// 06 §6.6 «sort для стабильности»): same-volume rename(2) inside the
    /// executor, journal `renameBack` → undo (F-6) rides the unified queue.
    public static func buildTransferPlan(pairs: [RenamePair], in parent: VFSPath) -> TransferPlan {
        let sorted = pairs.sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        var items: [TransferItem] = []
        for pair in sorted {
            let target = VFSPath(root: parent.root, components: parent.components + [pair.newName])
            items.append(TransferItem(source: pair.item.id, target: target, item: pair.item))
        }
        // Conflicts were resolved at preview time (Apply is enabled only for a
        // valid plan); the executor's runtime re-check is the last guard.
        return TransferPlan(op: .move, items: items, conflicts: [])
    }
}

extension String {
    /// Zero-pads the number textual form to at least `width` characters.
    fileprivate func leftPadded(toWidth width: Int) -> String {
        guard count < width else { return self }
        return String(repeating: "0", count: width - count) + self
    }
}
