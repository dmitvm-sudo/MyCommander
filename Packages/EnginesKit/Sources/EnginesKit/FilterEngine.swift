// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.6 (FilterEngine, F-10 quick filter):
// substring by default, optional simple fuzzy; a pass over 50 000 names within
// 50 ms; works over Int indices and never re-creates strings — callers keep a
// prepared (lowercased) name index and pass it in for every incremental stroke.

/// Quick filter style (F-10 «подстрока/fuzzy, настраиваемо»).
public enum FilterStyle: Sendable, Hashable {
    /// Case-insensitive containment (default).
    case substring
    /// Case-insensitive subsequence: query characters appear in `name` in order.
    case fuzzy
}

public enum FilterEngine {
    /// Lowercased view of `name` — prepared once per listing by the caller.
    public static func prepare(_ name: String) -> String {
        name.lowercased()
    }

    /// Matching semantics over prepared (lowercased) strings. Empty query
    /// matches everything.
    public static func matches(
        preparedName: String,
        query: String,
        style: FilterStyle
    ) -> Bool {
        if query.isEmpty { return true }
        switch style {
        case .substring:
            return preparedName.contains(query)
        case .fuzzy:
            return isSubsequence(query, of: preparedName)
        }
    }

    /// Convenience matcher for raw names (single-shot use, tests).
    public static func matches(name: String, query: String, style: FilterStyle) -> Bool {
        matches(preparedName: prepare(name), query: prepare(query), style: style)
    }

    /// Cold pass over the whole prepared index (after a listing change).
    /// Returns indices into `preparedNames` in ascending order.
    public static func filter(
        preparedNames: [String],
        query: String,
        style: FilterStyle
    ) -> [Int] {
        filter(preparedNames: preparedNames, query: query, style: style, candidates: nil)
    }

    /// Incremental pass (§6.6 «мемоизация префикса ввода»): when the caller
    /// passes the previous result as `candidates` (the query being an extension
    /// of the previous one), only those rows are re-tested — the keystroke cost
    /// shrinks with the result instead of staying proportional to the folder.
    public static func filter(
        preparedNames: [String],
        query: String,
        style: FilterStyle,
        candidates: [Int]?
    ) -> [Int] {
        if query.isEmpty { return Array(0 ..< preparedNames.count) }
        var result: [Int] = []
        result.reserveCapacity(candidates?.count ?? preparedNames.count / 4)
        for index in candidates ?? Array(0 ..< preparedNames.count) {
            guard preparedNames.indices.contains(index) else { continue }
            if matches(preparedName: preparedNames[index], query: query, style: style) {
                result.append(index)
            }
        }
        return result
    }

    /// Convenience cold pass for raw names (single-shot use, tests).
    public static func filter(names: [String], query: String, style: FilterStyle) -> [Int] {
        filter(
            preparedNames: names.map(prepare),
            query: prepare(query),
            style: style,
            candidates: nil
        )
    }

    /// Greedy subsequence check: every `query` character must appear in
    /// `preparedName` in order (not necessarily adjacent).
    private static func isSubsequence(_ query: String, of preparedName: String) -> Bool {
        var nameIterator = preparedName.makeIterator()
        nextQuery: for queryCharacter in query {
            while let current = nameIterator.next() {
                if current == queryCharacter { continue nextQuery }
            }
            return false
        }
        return true
    }
}
