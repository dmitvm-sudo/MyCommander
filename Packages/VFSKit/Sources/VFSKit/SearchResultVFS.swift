// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-30) + F-16 — the READ-ONLY virtual
// folder of search results. `listDirectory` flattens the hits into ONE
// directory (component[0] = hit index, since names may collide);
// `metadata`/`openRead` DELEGATE to each hit's origin VFS (F-3 viewing and
// F-5 copying work through the default `copyContents`); every write path is
// `vfsUnsupported`.

public final class SearchResultVFS: VFS, @unchecked Sendable {
    public struct Hit: Sendable {
        public let item: VFSItem
        public let origin: any VFS

        public init(item: VFSItem, origin: any VFS) {
            self.item = item
            self.origin = origin
        }
    }

    public let id: VFSInstanceID
    public let capabilities = VFSCapabilities()

    private let hits: [Hit]
    private let title: String

    public init(hits: [Hit], title: String = String(localized: "search.results.folder")) {
        self.hits = hits
        self.title = title
        id = VFSInstanceID(kind: .searchResults, specID: "search-\(UUID().uuidString)")
    }

    /// The row item for hit `index` — same name/kind/attributes, but the id
    /// is OURS (`[String(index), name]`) so duplicate names stay addressable.
    private func rowItem(_ index: Int) -> VFSItem {
        let hit = hits[index]
        let components = [String(index), hit.item.name]
        return VFSItem(
            id: VFSPath(root: id, components: components),
            instance: id,
            name: hit.item.name,
            kind: hit.item.kind,
            attributes: hit.item.attributes,
            revision: 0
        )
    }

    private func hitIndex(of path: VFSPath) -> Int? {
        guard path.components.count == 2, let index = Int(path.components[0]), hits.indices.contains(index) else {
            return nil
        }
        return index
    }

    // MARK: VFS

    public func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        guard path.components.isEmpty else { return [] }   // flat folder
        return hits.indices.map(rowItem)
    }

    public func metadata(of path: VFSPath) async throws -> VFSItem {
        guard let index = hitIndex(of: path) else {
            throw MCError.vfsNotFound(path)
        }
        return rowItem(index)
    }

    public func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        hits.reduce(0) { $0 + ($1.item.attributes.size ?? 0) }
    }

    public func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        throw MCError.vfsUnsupported(id, "SearchResultVFS is read-only")
    }

    public func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        throw MCError.vfsUnsupported(id, "SearchResultVFS is read-only")
    }

    public func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        throw MCError.vfsUnsupported(id, "SearchResultVFS is read-only")
    }

    /// F-5 copy FROM the results rides the DEFAULT `copyContents` (openRead
    /// delegates to the origin) — no override needed.
    public func openRead(_ path: VFSPath) async throws -> any ByteStream {
        guard let index = hitIndex(of: path) else {
            throw MCError.vfsNotFound(path)
        }
        return try await hits[index].origin.openRead(hits[index].item.id)
    }

    public func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        throw MCError.vfsUnsupported(id, "SearchResultVFS is read-only")
    }

    public func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        throw MCError.vfsUnsupported(id, "SearchResultVFS is read-only")
    }
}
