// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-29) + F-15 — the directory
// compare/sync engine. PURE: no AppKit — the App (PanelsCoordinator) turns
// the action script into TransferPlanner plans and rides the unified queue.
// Budget: a 100 000-entry diff ≤ 3 s (F-15 acceptance).

/// Metadata-only or content-verified comparison (06 §6.6 T-29).
public enum SyncCompareMode: Sendable {
    case metadata
    case content
}

public enum SyncEntryState: Sendable, Equatable {
    case onlyA
    case onlyB
    case differing
    case equal
}

/// One diff row; `relativeComponents` is the path INSIDE the compared roots.
public struct SyncEntry: Sendable {
    public let relativeComponents: [String]
    public let state: SyncEntryState
    public let itemA: VFSItem?
    public let itemB: VFSItem?

    public var relativePath: String { relativeComponents.joined(separator: "/") }
}

public struct SyncReport: Sendable {
    /// Sorted by relative path (stable script order).
    public let entries: [SyncEntry]

    public func count(_ state: SyncEntryState) -> Int {
        entries.lazy.filter { $0.state == state }.count
    }
}

public enum SyncDirection: Sendable, Equatable {
    case aToB
    case bToA
}

public enum SyncActionKind: Sendable, Equatable {
    case copyAToB
    case copyBToA
    case deleteInA
    case deleteInB
}

public struct SyncAction: Sendable, Equatable {
    public let kind: SyncActionKind
    public let relativeComponents: [String]

    public var relativePath: String { relativeComponents.joined(separator: "/") }
}

public enum SyncReporter {
    /// Compares the trees rooted at `atA` (side A) and `atB` (side B).
    /// `cache` (optional) memoizes content digests keyed by instance+path,
    /// invalidated on mtime/size mismatch (06 §6.6 T-29).
    public static func compare(
        a: any VFS, at atA: VFSPath,
        b: any VFS, at atB: VFSPath,
        mode: SyncCompareMode,
        cache: HashCache? = nil,
        workers: Int = 4
    ) async throws -> SyncReport {
        // Both trees walk concurrently (§6.6 T-29); recursion inside a side
        // stays sequential (one readdir per directory).
        async let walkA: [String: VFSItem] = walk(a, at: atA)
        async let walkB: [String: VFSItem] = walk(b, at: atB)
        let (itemsA, itemsB) = try await (walkA, walkB)

        // Union of relative paths, sorted once.
        var keys = Set(itemsA.keys)
        keys.formUnion(itemsB.keys)
        let sortedKeys = keys.sorted()

        // Content mode hashes metadata-equal FILES with a bounded worker pool.
        var digestsA: [String: Data] = [:]
        var digestsB: [String: Data] = [:]
        if mode == .content {
            let hashable = sortedKeys.filter { key in
                guard let itemA = itemsA[key], let itemB = itemsB[key] else { return false }
                return isFile(itemA) && isFile(itemB) && metadataEqual(itemA, itemB)
            }
            let pool = max(1, min(workers, hashable.count))
            if pool > 0 {
                let sliceSize = (hashable.count + pool - 1) / pool
                let slices = stride(from: 0, to: hashable.count, by: sliceSize).map {
                    Array(hashable[$0 ..< min($0 + sliceSize, hashable.count)])
                }
                let results = await withTaskGroup(
                    of: [(String, Data, Data)].self,
                    returning: [(String, Data, Data)].self
                ) { group in
                    for slice in slices {
                        group.addTask {
                            var local: [(String, Data, Data)] = []
                            for key in slice {
                                guard let itemA = itemsA[key], let itemB = itemsB[key] else { continue }
                                guard let digestA = await self.digest(of: itemA, in: a, cache: cache),
                                      let digestB = await self.digest(of: itemB, in: b, cache: cache)
                                else { continue }
                                local.append((key, digestA, digestB))
                            }
                            return local
                        }
                    }
                    var collected: [(String, Data, Data)] = []
                    for await slice in group { collected.append(contentsOf: slice) }
                    return collected
                }
                for (key, digestA, digestB) in results {
                    digestsA[key] = digestA
                    digestsB[key] = digestB
                }
            }
        }

        var entries: [SyncEntry] = []
        entries.reserveCapacity(sortedKeys.count)
        for key in sortedKeys {
            let components = key.split(separator: "/").map(String.init)
            let itemA = itemsA[key]
            let itemB = itemsB[key]
            let state: SyncEntryState
            switch (itemA, itemB) {
            case (.some, .none):
                state = .onlyA
            case (.none, .some):
                state = .onlyB
            case (let a?, let b?):
                guard isFile(a) && isFile(b) else {
                    // Two directories (or a type mismatch): presence decides.
                    state = sameKind(a, b) ? .equal : .differing
                    break
                }
                if !metadataEqual(a, b) {
                    state = .differing
                } else if mode == .content {
                    state = digestsA[key] == digestsB[key] ? .equal : .differing
                } else {
                    state = .equal
                }
            case (.none, .none):
                continue   // impossible by construction
            }
            entries.append(SyncEntry(relativeComponents: components, state: state, itemA: itemA, itemB: itemB))
        }
        return SyncReport(entries: entries)
    }

    /// Builds the action script (06 §6.6 T-29): copies for `onlyX` +
    /// `differing`, mirror deletes the extras on the RECEIVING side; equal
    /// entries stay untouched. A directory copy/delete covers its subtree —
    /// descendants are NOT duplicated into the script.
    public static func actionScript(from report: SyncReport, direction: SyncDirection, mirror: Bool) -> [SyncAction] {
        var actions: [SyncAction] = []
        var coveredDirectories: Set<String> = []

        func covered(_ components: [String]) -> Bool {
            for count in 1 ..< components.count where coveredDirectories.contains(components.prefix(count).joined(separator: "/")) {
                return true
            }
            return false
        }

        for entry in report.entries {
            guard !covered(entry.relativeComponents) else { continue }
            switch entry.state {
            case .equal:
                continue
            case .onlyA, .onlyB, .differing:
                break
            }
            let isDirectory: Bool
            if case .directory = (entry.itemA ?? entry.itemB)?.kind { isDirectory = true } else { isDirectory = false }

            switch (direction, entry.state) {
            case (.aToB, .onlyA), (.aToB, .differing):
                if isDirectory { coveredDirectories.insert(entry.relativePath) }
                actions.append(SyncAction(kind: .copyAToB, relativeComponents: entry.relativeComponents))
            case (.bToA, .onlyB), (.bToA, .differing):
                if isDirectory { coveredDirectories.insert(entry.relativePath) }
                actions.append(SyncAction(kind: .copyBToA, relativeComponents: entry.relativeComponents))
            case (.aToB, .onlyB):
                if mirror {
                    if isDirectory { coveredDirectories.insert(entry.relativePath) }
                    actions.append(SyncAction(kind: .deleteInB, relativeComponents: entry.relativeComponents))
                }
            case (.bToA, .onlyA):
                if mirror {
                    if isDirectory { coveredDirectories.insert(entry.relativePath) }
                    actions.append(SyncAction(kind: .deleteInA, relativeComponents: entry.relativeComponents))
                }
            default:
                break   // equal (already filtered) + cross combinations
            }
        }
        return actions
    }

    // MARK: internals

    /// Depth-first walk into `relativePath → item` (the root itself excluded).
    private static func walk(_ vfs: any VFS, at root: VFSPath) async throws -> [String: VFSItem] {
        var result: [String: VFSItem] = [:]
        func recurse(_ path: VFSPath, prefix: [String]) async throws {
            for item in try await vfs.listDirectory(at: path) {
                let relative = prefix + [item.name]
                result[relative.joined(separator: "/")] = item
                if case .directory = item.kind {
                    try await recurse(
                        VFSPath(root: path.root, components: path.components + [item.name]),
                        prefix: relative
                    )
                }
            }
        }
        try await recurse(root, prefix: [])
        return result
    }

    private static func isFile(_ item: VFSItem) -> Bool {
        if case .directory = item.kind { return false }
        return true
    }

    private static func sameKind(_ a: VFSItem, _ b: VFSItem) -> Bool {
        let dirA: Bool
        if case .directory = a.kind { dirA = true } else { dirA = false }
        let dirB: Bool
        if case .directory = b.kind { dirB = true } else { dirB = false }
        return dirA == dirB
    }

    /// Size exact; mtime within a 1 s tolerance (cross-filesystem precision,
    /// §6.6 T-29). A missing mtime on either side falls back to size alone.
    private static func metadataEqual(_ a: VFSItem, _ b: VFSItem) -> Bool {
        guard a.attributes.size == b.attributes.size else { return false }
        guard let modifiedA = a.attributes.modified, let modifiedB = b.attributes.modified else {
            return true
        }
        return abs(modifiedA.timeIntervalSince(modifiedB)) < 1.0
    }

    /// SHA-256 over the streamed bytes, memoized through `cache` when given.
    private static func digest(of item: VFSItem, in vfs: any VFS, cache: HashCache?) async -> Data? {
        let key = HashCache.Key(instance: item.instance.specID, path: item.id.components.joined(separator: "/"))
        let mtime = item.attributes.modified
        let size = item.attributes.size
        if let cache, let cached = cache.lookup(key, mtime: mtime, size: size) {
            return cached
        }
        do {
            let stream = try await vfs.openRead(item.id)
            var hasher = SHA256()
            while let chunk = try await stream.readChunk(max: 1 << 20) {
                hasher.update(data: chunk)
            }
            let digest = Data(hasher.finalize())
            cache?.store(key, mtime: mtime, size: size, digest: digest)
            return digest
        } catch {
            return nil   // unreadable → counted as differing by the caller
        }
    }
}
