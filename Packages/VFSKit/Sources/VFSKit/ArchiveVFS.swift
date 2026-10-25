// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import SWCompression
import ZIPFoundation

// Contract: docs/SDD/05 §5.3 + docs/SDD/06 §6.4 (уточнение T-21) — archive-as-folder.
// Read-only source (capabilities.canWrite/… = false); write support arrives with the
// pack flow (T-22). The index is built at mount (headers only); per-entry extraction
// is lazy into `…/extract/<mountCacheHex>/` with the `.mc-partial` → rename pattern
// (06 §6.2). gz/xz/bz2 containers inflate whole-in-RAM at mount — the honest v1 limit
// (container ≤ RAM), documented in §6.4.

public final class ArchiveVFS: VFS, @unchecked Sendable {
    public let id: VFSInstanceID
    public let capabilities = VFSCapabilities(canRandomSeek: true)   // listing/seek only

    /// The host archive file on the local disk (root metadata, F-9 Quick Look).
    let archiveURL: URL
    private let flavor: Flavor
    private let nodes: [String: Node]
    private let order: [String]
    private let extractDir: URL
    /// Serializes tar-family handle walks and ZIPFoundation extracts (not thread-safe).
    private let ioLock = NSLock()

    private enum Flavor {
        /// ZIPFoundation Archive; central directory in RAM.
        case zip(archive: ZIPFoundation.Archive, entries: [String: ZIPFoundation.Entry])
        /// Raw tar in the host file; the read handle doubles for extraction.
        case tar(handle: FileHandle)
        /// Uncompressed tar already published into the extract cache.
        case tarInCache(cacheFile: URL, handle: FileHandle)
        /// gz/xz/bz2 of ONE file, already uncompressed into the cache.
        case singleFile(name: String, cacheFile: URL)
    }

    private struct Node {
        var components: [String]
        var kind: VFSItemKind
        var size: Int64?
        var modified: Date?
        var permissions: Int16?
        var symlinkTarget: String?
        /// tar-family payload offset in the backing file; zip resolves via `zipPath`.
        var dataOffset: Int64?
        var zipPath: String?
    }

    // MARK: mount

    /// docs/SDD/06 §6.4: idempotent mount identity — path:size:mtime (same bytes =
    /// same mount; a replaced file is a different mount).
    static func fileIdentity(of url: URL) -> VFSInstanceID {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = attributes[.size] as? Int64 ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let spec = "\(url.path)#\(size)#\(Int(mtime * 1000))"
        return VFSInstanceID(kind: .archive, credentialRef: nil, specID: spec)
    }

    /// Opens (indexes) the archive; throws `MCError` (§5.8 mapping at this boundary).
    /// `pathEncoding` covers legacy code-page names (06 §6.4: CP866 fallback);
    /// nil = ZIPFoundation default (UTF-8, else CP437).
    public init(
        reading url: URL,
        extractRoot: URL,
        pathEncoding: String.Encoding? = nil
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw MCError.vfsNotFound(VFSPath.local(url))
        }
        let standardized = url.standardizedFileURL
        self.archiveURL = standardized
        self.id = Self.fileIdentity(of: standardized)
        self.extractDir = extractRoot.appendingPathComponent(self.id.specID.mountCacheHex(), isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        var index: [String: Node] = [:]
        var order: [String] = []
        let lowercasedName = standardized.lastPathComponent.lowercased()

        if lowercasedName.hasSuffix(".zip") {
            let archive = try ZIPFoundation.Archive(url: standardized, accessMode: .read, pathEncoding: pathEncoding)
            var entries: [String: ZIPFoundation.Entry] = [:]
            for entry in archive {
                // ZIPFoundation's `path` property decodes UTF-8-flagged names and
                // falls back to CP437; a container-level legacy override (CP866)
                // must re-decode explicitly (06 §6.4 T-21).
                let decodedPath = pathEncoding.map { entry.path(using: $0) } ?? entry.path
                if entries[decodedPath] == nil { entries[decodedPath] = entry }   // duplicate paths: first wins
            }
            self.flavor = .zip(archive: archive, entries: entries)
            for (decodedPath, entry) in entries {
                let components = Self.normalizeEntryName(decodedPath)
                guard !components.isEmpty else { continue }   // «..»-escape / absolute: dropped
                Self.synthesizeDirectories(components, into: &index, &order)
                let attributes = entry.fileAttributes
                let modified = attributes[.modificationDate] as? Date
                let permissions = (attributes[.posixPermissions] as? Int).map { Int16(truncatingIfNeeded: $0) }
                switch entry.type {
                case .directory:
                    Self.pushNode(.init(components: components, kind: .directory, size: nil,
                                        modified: modified, permissions: permissions, symlinkTarget: nil,
                                        dataOffset: nil, zipPath: decodedPath), into: &index, &order)
                case .symlink:
                    // v1: on-disk symlinks are never created (06 §6.4) — shown, not opened.
                    Self.pushNode(.init(components: components, kind: .symlink(target: nil), size: nil,
                                        modified: modified, permissions: nil, symlinkTarget: nil,
                                        dataOffset: nil, zipPath: decodedPath), into: &index, &order)
                case .file:
                    Self.pushNode(.init(components: components, kind: .file,
                                        size: Int64(clamping: entry.uncompressedSize),
                                        modified: modified, permissions: permissions, symlinkTarget: nil,
                                        dataOffset: nil, zipPath: decodedPath), into: &index, &order)
                }
            }
        } else if lowercasedName.hasSuffix(".tar") {
            let handle = try FileHandle(forReadingFrom: standardized)
            let scanned = try TarStream.scan(fileHandle: handle)
            self.flavor = .tar(handle: handle)
            Self.absorb(scanned, into: &index, &order)
        } else if let compressor = Self.compressedTarFlavor(lowercasedName) {
            let tarData = try Self.uncompressedContainer(of: standardized, with: compressor)
            let cacheFile = try Self.publish(tarData, as: "unpacked.tar", under: extractDir)
            let handle = try FileHandle(forReadingFrom: cacheFile)
            let scanned = try TarStream.scan(fileHandle: handle)
            self.flavor = .tarInCache(cacheFile: cacheFile, handle: handle)
            Self.absorb(scanned, into: &index, &order)
        } else if let compressor = Self.singleFileFlavor(lowercasedName) {
            let payload = try Self.uncompressedContainer(of: standardized, with: compressor)
            let cacheFile = try Self.publish(payload, as: "payload.bin", under: extractDir)
            let entryName = Self.strippedBaseName(standardized) ?? "unpacked.bin"
            let size = Int64(clamping: (try? cacheFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let modified = ((try? fm.attributesOfItem(atPath: cacheFile.path)) ?? [:])[.modificationDate] as? Date
            self.flavor = .singleFile(name: entryName, cacheFile: cacheFile)
            Self.pushNode(.init(components: [entryName], kind: .file, size: size, modified: modified,
                                permissions: nil, symlinkTarget: nil, dataOffset: nil, zipPath: nil),
                          into: &index, &order)
        } else {
            throw MCError.vfsUnsupported(id, "unsupported archive container: \(standardized.lastPathComponent)")
        }

        guard !order.isEmpty else {
            throw MCError.vfsUnsupported(id, "empty archive container")
        }
        self.nodes = index
        self.order = order
    }

    // MARK: §5.3 listing

    public func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        try checkOwn(path)
        let parent = path.components
        var items: [VFSItem] = []
        for key in order {
            let components = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count == parent.count + 1 else { continue }
            guard Array(components.prefix(parent.count)) == parent else { continue }
            guard let node = nodes[key] else { continue }
            items.append(Self.makeItem(node, in: id, revision: 1))
        }
        return items
    }

    public func metadata(of path: VFSPath) async throws -> VFSItem {
        try checkOwn(path)
        if path.components.isEmpty {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)) ?? [:]
            return VFSItem(
                id: path,
                instance: id,
                name: archiveURL.lastPathComponent,
                kind: .directory,
                attributes: VFSItemAttributes(
                    modified: attributes[.modificationDate] as? Date,
                    isReadOnly: true
                )
            )
        }
        guard let node = nodes[path.components.joined(separator: "/")] else {
            throw MCError.vfsNotFound(path)
        }
        return Self.makeItem(node, in: id, revision: 1)
    }

    /// Sizes come from the index — no disk walk (06 §6.4 T-21).
    public func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        try checkOwn(path)
        _ = try await metadata(of: path)   // existence check (root always exists)
        let prefix = path.components.joined(separator: "/")
        var total: Int64 = 0
        var count = 0
        for (key, node) in nodes {
            guard key == prefix || key.hasPrefix(prefix.isEmpty ? "" : prefix + "/") else { continue }
            guard case .file = node.kind, let size = node.size else { continue }
            total &+= size
            count += 1
            progress?(ProgressUpdate(completedItems: count, message: node.components.last))
        }
        return total
    }

    // MARK: §5.3 mutations — the pack flow (T-22) adds write support afterwards

    public func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        throw MCError.vfsUnsupported(id, "archive write is pack-flow (T-22)")
    }

    public func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        throw MCError.vfsUnsupported(id, "archives are read-only in v1")
    }

    public func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        throw MCError.vfsUnsupported(id, "archives are read-only in v1")
    }

    public func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        throw MCError.vfsUnsupported(id, "archive write is pack-flow (T-22)")
    }

    public func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        throw MCError.vfsUnsupported(id, "archive attributes are read-only in v1")
    }

    // MARK: §5.5 streams

    public func openRead(_ path: VFSPath) async throws -> any ByteStream {
        try checkOwn(path)
        guard !path.components.isEmpty else {
            throw MCError.vfsUnsupported(id, "EISDIR (openRead on archive root)")
        }
        guard let node = nodes[path.components.joined(separator: "/")] else {
            throw MCError.vfsNotFound(path)
        }
        guard case .file = node.kind, let size = node.size else {
            throw MCError.vfsUnsupported(id, "openRead expects a file entry")
        }

        let cacheURL = entryCacheURL(for: path.components)
        try withLock {
            if !FileManager.default.fileExists(atPath: cacheURL.path) {
                try extract(node, to: cacheURL)
            }
        }
        do {
            let handle = try FileHandle(forReadingFrom: cacheURL)
            return ArchiveByteStream(handle: handle, length: size)
        } catch {
            throw MCError.vfsAccessDenied(path, underlying: error)
        }
    }

    private func checkOwn(_ path: VFSPath) throws {
        guard path.root == id else { throw MCError.vfsUnsupported(id, "path belongs to another instance") }
    }

    // MARK: plumbing

    private func entryCacheURL(for components: [String]) -> URL {
        let key = components.joined(separator: "\u{1F}")
        return extractDir.appendingPathComponent(key.mountCacheHex() + "__" + (components.last ?? "payload"))
    }

    /// Caller holds `ioLock`.
    private func extract(_ node: Node, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch flavor {
        case let .zip(archive, entries):
            guard let entry = entries[node.zipPath ?? ""] else {
                throw MCError.vfsNotFound(VFSPath(root: id, components: node.components))
            }
            do {
                _ = try archive.extract(entry, to: destination, skipCRC32: true)
            } catch {
                try? fm.removeItem(at: destination)
                throw MCError.unexpected(underlying: error)
            }
        case .tar(let handle):
            try extractTarEntry(node, handle: handle, to: destination)
        case let .tarInCache(cacheFile, handle):
            _ = cacheFile
            try extractTarEntry(node, handle: handle, to: destination)
        case let .singleFile(_, cacheFile):
            if destination != cacheFile {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: cacheFile, to: destination)
            }
        }
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try body()
    }

    private func extractTarEntry(_ node: Node, handle: FileHandle, to destination: URL) throws {
        guard let offset = node.dataOffset, node.size != nil else {
            throw MCError.vfsUnsupported(id, "entry has no payload")
        }
        try TarStream.extract(fileHandle: handle, at: offset, size: node.size ?? 0, to: destination)
    }

    private static func makeItem(_ node: Node, in id: VFSInstanceID, revision: UInt64) -> VFSItem {
        let attributes = VFSItemAttributes(
            size: node.size,
            modified: node.modified,
            posixPermissions: node.permissions,
            isReadOnly: true
        )
        return VFSItem(
            id: VFSPath(root: id, components: node.components),
            instance: id,
            name: node.components.last ?? "",
            kind: node.kind,
            attributes: attributes,
            revision: revision
        )
    }

    private static func pushNode(_ node: Node, into index: inout [String: Node], _ order: inout [String]) {
        let key = node.components.joined(separator: "/")
        guard index[key] == nil else { return }   // first occurrence wins
        index[key] = node
        order.append(key)
    }

    /// Implied ancestors of a nested entry become virtual directories first.
    private static func synthesizeDirectories(
        _ components: [String], into index: inout [String: Node], _ order: inout [String]
    ) {
        var prefix: [String] = []
        for component in components.dropLast() {
            prefix.append(component)
            pushNode(.init(components: prefix, kind: .directory, size: nil, modified: nil,
                           permissions: nil, symlinkTarget: nil, dataOffset: nil, zipPath: nil),
                     into: &index, &order)
        }
    }

    private static func absorb(
        _ scanned: [TarScannedEntry],
        into index: inout [String: Node],
        _ order: inout [String]
    ) {
        for entry in scanned {
            let components = Self.normalizeEntryName(entry.name)
            guard !components.isEmpty else { continue }   // «..»-escape / absolute: dropped
            Self.synthesizeDirectories(components, into: &index, &order)
            switch entry.kind {
            case .file:
                Self.pushNode(.init(components: components, kind: .file, size: entry.size,
                                    modified: entry.modified, permissions: entry.permissions,
                                    symlinkTarget: nil, dataOffset: entry.dataOffset, zipPath: nil),
                              into: &index, &order)
            case .directory:
                Self.pushNode(.init(components: components, kind: .directory, size: nil,
                                    modified: entry.modified, permissions: entry.permissions,
                                    symlinkTarget: nil, dataOffset: nil, zipPath: nil),
                              into: &index, &order)
            case .symlink:
                // v1: displayed with the raw target string; open/extract refuse (06 §6.4).
                Self.pushNode(.init(components: components, kind: .symlink(target: nil), size: nil,
                                    modified: entry.modified, permissions: nil,
                                    symlinkTarget: entry.symlinkTarget, dataOffset: nil, zipPath: nil),
                              into: &index, &order)
            case .skipped:
                continue   // hardlink/dev/fifo: header-only (§5.1 v1 scope)
            }
        }
    }

    // MARK: flavor detection + compressed-container helpers

    private enum Compressor { case gzip, xz, bzip2 }

    private static func compressedTarFlavor(_ name: String) -> Compressor? {
        if name.hasSuffix(".tgz") || name.hasSuffix(".tar.gz") { return .gzip }
        if name.hasSuffix(".txz") || name.hasSuffix(".tar.xz") { return .xz }
        if name.hasSuffix(".tbz2") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") { return .bzip2 }
        return nil
    }

    private static func singleFileFlavor(_ name: String) -> Compressor? {
        if compressedTarFlavor(name) != nil { return nil }   // .tar.gz is the compressed-tar case
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".xz") { return .xz }
        if name.hasSuffix(".bz2") { return .bzip2 }
        return nil
    }

    /// Honest v1 RAM limit (06 §6.4): the whole container inflates in RAM.
    private static func uncompressedContainer(of url: URL, with compressor: Compressor) throws -> Data {
        let compressed: Data
        do {
            compressed = try Data(contentsOf: url)
        } catch {
            throw MCError.unexpected(underlying: error)
        }
        do {
            switch compressor {
            case .gzip: return try GzipArchive.unarchive(archive: compressed)
            case .xz: return try XZArchive.unarchive(archive: compressed)
            case .bzip2: return try BZip2.decompress(data: compressed)
            }
        } catch {
            throw MCError.unexpected(underlying: error)
        }
    }

    /// Publishes ready bytes into the mount cache dir (`.mc-partial` → rename).
    private static func publish(_ data: Data, as file: String, under dir: URL) throws -> URL {
        let destination = dir.appendingPathComponent(file)
        let staged = dir.appendingPathComponent(file + ".mc-partial")
        try? FileManager.default.removeItem(at: staged)
        do {
            try data.write(to: staged)
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw MCError.unexpected(underlying: error)
        }
        return destination
    }

    /// «notes.txt.gz» → «notes.txt»; the base of a bare «.gz» becomes nil.
    private static func strippedBaseName(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Entry name → archive-relative components (F-12 traversal lock):
    /// absolute names lose the leading «/»; inner «..» pops; an escape past the
    /// archive root DROPS the entry. Components are NFC (contract §5.1).
    static func normalizeEntryName(_ name: String) -> [String] {
        var components: [String] = []
        for segment in name.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(segment)
            switch segment {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return [] }
                components.removeLast()
            default:
                components.append(segment)
            }
        }
        guard !components.isEmpty else { return [] }
        return components.map { $0.precomposedStringWithCanonicalMapping }
    }
}

// MARK: - ByteStream

/// §5.5 reader over ONE cache file (extracted lazily by `openRead`);
/// random access for the Lister window (ByteStreamSeekable, уточнение T-13).
final class ArchiveByteStream: ByteStreamSeekable, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let storedLength: Int64
    private var closed = false

    init(handle: FileHandle, length: Int64) {
        self.handle = handle
        self.storedLength = length
    }

    var length: Int64 { storedLength }

    func seek(to offset: Int64) async throws {
        try withLock {
            guard !closed else { throw ArchiveStreamError.closed }
            handle.seek(toFileOffset: UInt64(truncatingIfNeeded: max(0, min(offset, storedLength))))
        }
    }

    func readChunk(max: Int) async throws -> Data? {
        try withLock {
            guard !closed else { throw ArchiveStreamError.closed }
            guard let chunk = try handle.read(upToCount: max), !chunk.isEmpty else {
                closed = true
                return nil
            }
            return chunk
        }
    }

    deinit {
        try? handle.close()
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum ArchiveStreamError: Error {
    case closed
}
