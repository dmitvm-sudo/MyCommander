// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-30) + F-16 — the Spotlight-first
// path. The predicate build is PURE (unit-tested); the gathering wrapper is a
// thin NSMetadataQuery drive. Candidates are ALWAYS re-validated by the
// engine (mask/size/date + content), so an index miss or a stale index can
// never change the result — only the speed.

enum NSMetadataQueryBridge {
    /// Builds the Spotlight predicate for the metadata filters of `query`
    /// (`nil` = nothing to offload — the caller walks directly).
    static func predicate(root: URL, query: SearchQuery) -> NSPredicate? {
        var clauses: [NSPredicate] = []
        if let mask = query.nameMask, !mask.masks.isEmpty {
            // One LIKE clause per glob, OR-ed (FileMask semantics).
            let likes = mask.masks.map { glob in
                NSPredicate(format: "kMDItemFSName LIKE[c] %@", globPatternToLike(glob.pattern))
            }
            clauses.append(NSCompoundPredicate(orPredicateWithSubpredicates: likes))
        }
        if let minSize = query.minSize {
            clauses.append(NSPredicate(format: "kMDItemFSSize >= %lld", minSize))
        }
        if let maxSize = query.maxSize {
            clauses.append(NSPredicate(format: "kMDItemFSSize <= %lld", maxSize))
        }
        if let after = query.modifiedAfter {
            clauses.append(NSPredicate(format: "kMDItemFSContentChangeDate > %@", after as NSDate))
        }
        if let before = query.modifiedBefore {
            clauses.append(NSPredicate(format: "kMDItemFSContentChangeDate < %@", before as NSDate))
        }
        guard !clauses.isEmpty else { return nil }
        return NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    /// Runs the query scoped to `root` and returns the candidate file URLs;
    /// `nil` = the gather failed (the caller falls back to the walk).
    static func candidates(at root: URL, predicate: NSPredicate) async -> [URL]? {
        // NSMetadataQuery/NotificationCenter are not Sendable — isolate them
        // in an unchecked box (single query per call, life-bound to it).
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            weak var query: NSMetadataQuery?
            var observer: NSObjectProtocol?
        }
        let state = State()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL]?, Never>) in
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = [root.path]
            query.operationQueue = OperationQueue()   // off the main queue (modal-safe)
            state.query = query
            state.observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: nil
            ) { [state] _ in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.finished else { return }
                state.finished = true
                let urls = state.query?.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                    .map { URL(fileURLWithPath: $0) } ?? []
                continuation.resume(returning: urls)
            }
            state.lock.unlock()
            query.start()
        }
    }

    /// `*.txt` → `%.txt` (Spotlight LIKE wildcard dialect).
    private static func globPatternToLike(_ pattern: String) -> String {
        var like = ""
        for character in pattern {
            switch character {
            case "*": like.append("%")
            case "?": like.append("_")
            default: like.append(character)
            }
        }
        return like
    }
}
