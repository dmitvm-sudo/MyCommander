// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-30) + F-16 — the search engine.
// Filters (mask/size/date) run BEFORE the content scan; the content scan is
// `ByteScan` (line-based 8 MB windows); Spotlight-first via
// `NSMetadataQueryBridge` for LocalVFS with candidates re-validated by the
// SAME checks — a miss falls back to the recursive walk. Cancellation is
// instant (checked per directory and per chunk, F-16 acceptance).

public struct SearchQuery: Sendable {
    public var nameMask: FileMask?
    public var content: String
    public var contentIsRegex: Bool
    public var caseSensitive: Bool
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    /// Content-scan cap per file (settings); larger files match by name only.
    public var maxFileSize: Int64
    public var resultLimit: Int

    public init(
        nameMask: FileMask? = nil,
        content: String = "",
        contentIsRegex: Bool = false,
        caseSensitive: Bool = false,
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        maxFileSize: Int64 = 32 << 20,
        resultLimit: Int = 1000
    ) {
        self.nameMask = nameMask
        self.content = content
        self.contentIsRegex = contentIsRegex
        self.caseSensitive = caseSensitive
        self.minSize = minSize
        self.maxSize = maxSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.maxFileSize = maxFileSize
        self.resultLimit = resultLimit
    }
}

public struct SearchHit: Sendable {
    public let item: VFSItem
    /// Number of matching content lines; `nil` = matched by name/filters only.
    public let contentMatches: Int?
}

public struct SearchResult: Sendable {
    public let hits: [SearchHit]
    /// `true` when `resultLimit` stopped the search early.
    public let truncated: Bool
}

/// Marker for adapters backed by a Spotlight-indexable local volume
/// (`LocalVFS` conforms in VFSKit — the reverse import is impossible since
/// VFSKit depends on EnginesKit). The engine drives the Spotlight-first path
/// through this seam; candidates are re-validated regardless.
public protocol SpotlightSearchable: AnyObject, Sendable {
    func url(for path: VFSPath) -> URL
}

public enum SearchEngine {
    /// Searches the tree rooted at `root`. `onHit` fires per accepted hit
    /// (live results); the final `SearchResult` is the same set + truncated.
    public static func search(
        in vfs: any VFS,
        at root: VFSPath,
        query: SearchQuery,
        onHit: (@Sendable (SearchHit) -> Void)? = nil
    ) async throws -> SearchResult {
        var hits: [SearchHit] = []
        var truncated = false

        func accept(_ hit: SearchHit) -> Bool {
            hits.append(hit)
            onHit?(hit)
            if hits.count >= query.resultLimit {
                truncated = true
                return false
            }
            return true
        }

        // Spotlight-first (06 §6.6 T-30): Spotlight-searchable VFS + metadata
        // filters → try the index; re-validate every candidate; fall back on
        // any miss.
        if let spot = vfs as? SpotlightSearchable, vfs.id == root.root,
           let predicate = NSMetadataQueryBridge.predicate(root: spot.url(for: root), query: query) {
            let rootURL = spot.url(for: root)
            if let candidates = await NSMetadataQueryBridge.candidates(at: rootURL, predicate: predicate) {
                if !candidates.isEmpty {
                    for url in candidates {
                        if Task.isCancelled { throw CancellationError() }
                        guard let components = relativeComponents(of: url, under: rootURL) else { continue }
                        let path = VFSPath(root: vfs.id, components: components)
                        guard let item = try? await vfs.metadata(of: path) else { continue }
                        guard passesMetadataFilters(item, query: query) else { continue }
                        if query.content.isEmpty {
                            if !accept(SearchHit(item: item, contentMatches: nil)) { break }
                        } else if let match = try? await contentMatches(of: item, in: vfs, query: query), match > 0 {
                            if !accept(SearchHit(item: item, contentMatches: match)) { break }
                        }
                    }
                    return SearchResult(hits: hits, truncated: truncated)
                }
                // Zero candidates: an unindexed volume is indistinguishable
                // from «no matches» → fall through to the walk (correctness).
            }
        }

        func recurse(_ path: VFSPath) async throws -> Bool {
            if Task.isCancelled { throw CancellationError() }
            for item in try await vfs.listDirectory(at: path) {
                if Task.isCancelled { throw CancellationError() }
                var isDirectory = false
                if case .directory = item.kind { isDirectory = true }

                if passesMetadataFilters(item, query: query) {
                    if isDirectory {
                        // A directory never matches a CONTENT filter — it is
                        // a hit only for name/size/date searches.
                        if query.content.isEmpty, !accept(SearchHit(item: item, contentMatches: nil)) {
                            return false
                        }
                    } else if query.content.isEmpty {
                        if !accept(SearchHit(item: item, contentMatches: nil)) { return false }
                    } else if let match = try? await contentMatches(of: item, in: vfs, query: query), match > 0 {
                        if !accept(SearchHit(item: item, contentMatches: match)) { return false }
                    }
                }
                if isDirectory {
                    if !(try await recurse(VFSPath(root: path.root, components: path.components + [item.name]))) {
                        return false
                    }
                }
            }
            return true
        }
        _ = try await recurse(root)
        return SearchResult(hits: hits, truncated: truncated)
    }

    // MARK: internals

    private static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let fullPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(fullPath.dropFirst(rootPath.count + 1))
        return relative.split(separator: "/").map(String.init)
    }

    /// Mask/size/date checks (the content scan happens separately). Size
    /// filters target FILES — a directory does not match when one is set
    /// (its size is meaningless for the diff).
    static func passesMetadataFilters(_ item: VFSItem, query: SearchQuery) -> Bool {
        if let mask = query.nameMask, !mask.matches(item.name) {
            return false
        }
        var isDirectory = false
        if case .directory = item.kind { isDirectory = true }
        if query.minSize != nil || query.maxSize != nil {
            guard !isDirectory, let size = item.attributes.size else { return false }
            if let minSize = query.minSize, size < minSize { return false }
            if let maxSize = query.maxSize, size > maxSize { return false }
        }
        if let after = query.modifiedAfter {
            guard let modified = item.attributes.modified, modified > after else { return false }
        }
        if let before = query.modifiedBefore {
            guard let modified = item.attributes.modified, modified < before else { return false }
        }
        return true
    }

    /// Content scan (files only). Returns the matching-line count; `nil` when
    /// the item cannot match (no needle / directory / over the size cap /
    /// unreadable). `0` = readable, no matches.
    static func contentMatches(of item: VFSItem, in vfs: any VFS, query: SearchQuery) async throws -> Int? {
        guard !query.content.isEmpty else { return nil }
        var isDirectory = false
        if case .directory = item.kind { isDirectory = true }
        guard !isDirectory else { return nil }
        if let size = item.attributes.size, size > query.maxFileSize { return nil }
        let stream = try await vfs.openRead(item.id)
        return try await ByteScan.countMatchingLines(
            in: stream,
            needle: query.content,
            isRegex: query.contentIsRegex,
            caseSensitive: query.caseSensitive
        )
    }
}
