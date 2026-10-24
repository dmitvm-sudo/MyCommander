// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import DomainKit

/// POSIX adapter (docs/SDD/11: VFSKit/LocalVFS.swift — «POSIX-адаптер
/// (list/stat/copyContents/rm…)»). Watch arrives in T-06 (FSEventsWatcher), so
/// `canWatch` reports false for now. `instanceID:` override exists for tests/edge
/// roots: without it, two temp directories on one volume would share the same
/// volume-UUID identity (specID = volume UUID per §5.1).
///
/// Errors are mapped into `MCError` at this boundary (§5.8): ENOENT → `.vfsNotFound`,
/// EACCES/EPERM → `.vfsAccessDenied(underlying:)`, everything else → `.unexpected`.
public final class LocalVFS: VFS, @unchecked Sendable {
    public let id: VFSInstanceID
    public let capabilities: VFSCapabilities

    private let lock = NSLock()
    private let rootURL: URL
    /// Targets of staged-but-unfinished writers (one slot per openWrite call).
    private var openWriters: Set<[String]> = []
    private var revisionCounter: UInt64 = 1

    public init(at root: URL, instanceID: VFSInstanceID? = nil) {
        let standardized = root.standardizedFileURL
        self.rootURL = standardized
        self.id = instanceID ?? VFSInstanceID(
            kind: .localDisk,
            credentialRef: nil,
            specID: LocalVFS.volumeID(of: standardized)
        )
        // Write/Rename/Delete/RandomSeek/Dates/Symlinks: full POSIX profile.
        // canWatch: FSEventsWatcher (T-06) serves every path with a displayURL.
        self.capabilities = VFSCapabilities(
            canWrite: true,
            canDelete: true,
            canRename: true,
            canWatch: true,
            canRandomSeek: true,
            preservesDates: true,
            symlinkSupport: true
        )
    }

    private static func volumeID(of url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString
        else { return "unknown" }
        return uuid
    }

    // MARK: §5.3 listing and metadata

    private static let listKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
    ]

    public func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        try checkOwn(path)
        let listingURL = resolveURL(path)
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: listingURL.path, isDirectory: &isDir) else { throw MCError.vfsNotFound(path) }
        guard isDir.boolValue else { throw MCError.vfsUnsupported(id, "ENOTDIR (listDirectory on file)") }
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: listingURL, includingPropertiesForKeys: Self.listKeys, options: [])
        } catch {
            throw mapFSError(error, path)
        }
        let revision: UInt64 = withLock { revisionCounter &+= 1; return revisionCounter }
        return children.map { child in makeItem(parent: path, child: child, revision: revision) }
    }

    public func metadata(of path: VFSPath) async throws -> VFSItem {
        try checkOwn(path)
        let itemURL = resolveURL(path)
        let values = try snapshotValues(of: itemURL, or: path)
        let revision: UInt64 = withLock { revisionCounter }
        let name = path.components.last ?? rootURL.lastPathComponent
        return VFSItem(
            id: vfsPath(of: path.components, display: itemURL),
            instance: id,
            name: name,
            kind: kind(of: itemURL, values: values),
            attributes: attributes(of: itemURL, values: values),
            revision: revision
        )
    }

    /// Recursively sums regular-file sizes; sinks fire per file after the walk.
    /// Symlinked directories are NOT followed (intentional: no alias loops).
    public func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        try checkOwn(path)
        let root = resolveURL(path)
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
            throw MCError.vfsNotFound(path)
        }
        guard isDir.boolValue else {
            let size = (try? root.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            progress?(ProgressUpdate(completedItems: 1))
            return Int64(size)
        }
        var updates: [ProgressUpdate] = []
        let total = sumFiles(under: root, updates: &updates)
        for update in updates { progress?(update) }
        return total
    }

    /// Synchronous walk (FileManager.DirectoryEnumerator is not async-iterable).
    private func sumFiles(under root: URL, updates: inout [ProgressUpdate]) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }   // unreadable subtree: skip it, keep counting
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory != true,
               let size = values.fileSize {
                total += Int64(size)
                updates.append(ProgressUpdate(completedItems: updates.count + 1, message: child.lastPathComponent))
            }
        }
        return total
    }

    // MARK: §5.3 mutations

    public func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        try checkOwn(parent)
        guard !name.isEmpty, !name.contains("/") else { throw MCError.vfsUnsupported(id, "EINVAL: name «\(name)»") }
        let fm = FileManager.default
        let parentURL = resolveURL(parent)
        var parentIsDir = ObjCBool(false)
        guard fm.fileExists(atPath: parentURL.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw MCError.vfsNotFound(parent)
        }
        let createdURL = parentURL.appendingPathComponent(name)
        let createdPath = VFSPath(root: id, components: parent.components + [name])
        var exists = ObjCBool(false)
        if fm.fileExists(atPath: createdURL.path, isDirectory: &exists) {
            if exists.boolValue { return createdPath }          // idempotent, mkdir(2) «EEXIST-dir»
            throw MCError.vfsAccessDenied(createdPath, underlying: nil)   // EEXIST-file
        }
        do {
            try fm.createDirectory(at: createdURL, withIntermediateDirectories: false, attributes: nil)
        } catch {
            throw mapFSError(error, createdPath)
        }
        bumpRevision()
        return createdPath
    }

    public func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        try checkOwn(path)
        guard !name.isEmpty, !name.contains("/") else { throw MCError.vfsUnsupported(id, "EINVAL: name «\(name)»") }
        guard !path.components.isEmpty else { throw MCError.vfsAccessDenied(path, underlying: nil) }   // root is not renameable
        let fm = FileManager.default
        let sourceURL = resolveURL(path)
        var sourceKind = ObjCBool(false)
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &sourceKind) else { throw MCError.vfsNotFound(path) }
        let targetComponents = Array(path.components.dropLast()) + [name]
        let targetPath = VFSPath(root: id, components: targetComponents)
        let targetURL = resolveURL(targetPath)
        if fm.fileExists(atPath: targetURL.path) {
            throw MCError.transferConflict(source: path, target: targetPath)
        }
        do {
            try fm.moveItem(at: sourceURL, to: targetURL)   // same parent → same volume: plain rename(2)
        } catch {
            throw mapFSError(error, path)
        }
        bumpRevision()
        return targetPath
    }

    /// Direct delete or trash. toTrash uses `FileManager.trashItem` (06 §6.2: local
    /// volumes only); VFS without trash capability deletes directly with a warning.
    public func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        for path in paths { try checkOwn(path) }
        let fm = FileManager.default
        for path in paths {
            let targetURL = resolveURL(path)
            guard fm.fileExists(atPath: targetURL.path) else { throw MCError.vfsNotFound(path) }
            do {
                if toTrash {
                    try fm.trashItem(at: targetURL, resultingItemURL: nil)
                } else {
                    try fm.removeItem(at: targetURL)
                }
            } catch {
                throw mapFSError(error, path)
            }
            bumpRevision()
        }
    }

    // MARK: §5.5 streams

    public func openRead(_ path: VFSPath) async throws -> any ByteStream {
        try checkOwn(path)
        let fm = FileManager.default
        let targetURL = resolveURL(path)
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir) else { throw MCError.vfsNotFound(path) }
        guard !isDir.boolValue else { throw MCError.vfsUnsupported(id, "EISDIR (openRead on directory)") }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: targetURL)
        } catch {
            throw mapFSError(error, path)
        }
        let length = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return LocalByteStream(handle: handle, length: length)
    }

    public func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        try checkOwn(path)
        guard !path.components.isEmpty else { throw MCError.vfsAccessDenied(path, underlying: nil) }   // root is not a write target
        let fm = FileManager.default
        let targetURL = resolveURL(path)
        var parentIsDir = ObjCBool(false)
        let parentURL = targetURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: parentURL.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw MCError.vfsNotFound(path)
        }
        var targetIsDir = ObjCBool(false)
        if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir), targetIsDir.boolValue {
            throw MCError.vfsAccessDenied(path, underlying: nil)   // EISDIR
        }
        let stagedURL = parentURL.appendingPathComponent("." + path.components.last! + ".mc-partial")
        let key = path.components
        try withLock {
            guard !openWriters.contains(key) else { throw MCError.vfsAccessDenied(path, underlying: nil) }
            openWriters.insert(key)
        }
        do {
            // A crashed session leaves `.mc-partial` residue — it is OURS, reclaim it (T-11 resume).
            if fm.fileExists(atPath: stagedURL.path) {
                try? fm.removeItem(at: stagedURL)
            }
            if fm.createFile(atPath: stagedURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) == false {
                throw MCError.vfsAccessDenied(path, underlying: nil)
            }
            let handle = try FileHandle(forWritingTo: stagedURL)
            return LocalByteWriter(owner: self, handle: handle, stagedURL: stagedURL, targetKey: key, replace: replace)
        } catch {
            _ = withLock { openWriters.remove(key) }
            try? fm.removeItem(at: stagedURL)
            throw mapFSError(error, path)
        }
    }

    public func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        try checkOwn(path)
        var itemURL = resolveURL(path)   // setResourceValues mutates the URL value
        let values = try snapshotValues(of: itemURL, or: path)
        let permissionsURL = itemURL
        var updated = attributes(of: permissionsURL, values: values)
        // Snapshots BEFORE mutate: the diff below must see the original values.
        let originalPermissions = updated.posixPermissions
        let originalModified = updated.modified
        let originalHidden = updated.isHidden
        let originalTags = updated.tags
        mutate(&updated)
        let fm = FileManager.default
        var fileAttributes: [FileAttributeKey: Any] = [:]
        if let permissions = updated.posixPermissions, permissions != originalPermissions {
            fileAttributes[.posixPermissions] = NSNumber(value: Int(permissions))
        }
        if updated.modified != originalModified {
            fileAttributes[.modificationDate] = updated.modified ?? Date()
        }
        if !fileAttributes.isEmpty {
            do {
                try fm.setAttributes(fileAttributes, ofItemAtPath: itemURL.path)
            } catch {
                throw mapFSError(error, path)
            }
        }
        if updated.isHidden != originalHidden {
            do {
                var mutable = try itemURL.resourceValues(forKeys: [.isHiddenKey])
                mutable.isHidden = updated.isHidden
                try itemURL.setResourceValues(mutable)
            } catch {
                throw mapFSError(error, path)
            }
        }
        if updated.tags != originalTags {
            do {
                try LocalVFS.writeUserTags(updated.tags, to: itemURL)
            } catch {
                throw mapFSError(error, path)
            }
        }
        bumpRevision()
    }

    // MARK: writer plumbing (LocalByteWriter calls in)

    fileprivate func commit(temp: URL, to finalTarget: VFSPath, replace: Bool, releasing key: [String]) throws {
        try checkOwn(finalTarget)
        let fm = FileManager.default
        let finalURL = resolveURL(finalTarget)
        try withLock {
            defer { openWriters.remove(key) }
            var occupying = ObjCBool(false)
            let occupied = fm.fileExists(atPath: finalURL.path, isDirectory: &occupying)
            if occupied, occupying.boolValue {
                try? fm.removeItem(at: temp)
                throw MCError.vfsAccessDenied(finalTarget, underlying: nil)   // rename(2) onto a directory
            }
            if occupied, !replace {
                try? fm.removeItem(at: temp)
                throw MCError.transferConflict(source: finalTarget, target: finalTarget)
            }
            do {
                if occupied, replace {
                    _ = try fm.replaceItemAt(finalURL, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: finalURL)   // atomic temp→final inside one directory
                }
            } catch {
                throw mapFSError(error, finalTarget)
            }
            bumpRevisionLocked()
        }
    }

    fileprivate func abandonWriter(key: [String], handle: FileHandle, at temp: URL) {
        try? handle.close()
        try? FileManager.default.removeItem(at: temp)
        _ = withLock { openWriters.remove(key) }
    }

    // MARK: private plumbing

    /// Resolves a VFS path of this instance to a file URL (local fast paths:
    /// APFS clonefile / fcopyfile in FileOpsKit, docs/SDD/06 §6.2). Paths of
    /// other instances are a programming error — precondition.
    public func url(for path: VFSPath) -> URL {
        precondition(path.root == id, "path belongs to another instance")
        return resolveURL(path)
    }

    private func checkOwn(_ path: VFSPath) throws {
        guard path.root == id else { throw MCError.vfsUnsupported(id, "path belongs to another instance") }
    }

    private func resolveURL(_ path: VFSPath) -> URL {
        var url = rootURL
        for component in path.components {
            url = url.appendingPathComponent(component)
        }
        return url
    }

    private func vfsPath(of components: [String], display: URL? = nil) -> VFSPath {
        VFSPath(root: id, components: components, displayURL: display)
    }

    private func bumpRevision() {
        withLock { bumpRevisionLocked() }
    }

    /// Caller must already hold `lock` (used inside `commit`).
    private func bumpRevisionLocked() {
        revisionCounter &+= 1
    }

    private func makeItem(parent: VFSPath, child: URL, revision: UInt64) -> VFSItem {
        let values = try? child.resourceValues(forKeys: Set(Self.listKeys))
        return VFSItem(
            id: vfsPath(of: parent.components + [child.lastPathComponent], display: child),
            instance: id,
            name: child.lastPathComponent,
            kind: kind(of: child, values: values),
            attributes: attributes(of: child, values: values),
            revision: revision
        )
    }

    private func snapshotValues(of url: URL, or path: VFSPath) throws -> URLResourceValues {
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw MCError.vfsNotFound(path)
        }
        do {
            return try url.resourceValues(forKeys: Set(Self.listKeys))
        } catch {
            throw mapFSError(error, path)
        }
    }

    private func kind(of url: URL, values: URLResourceValues?) -> VFSItemKind {
        guard let values else { return .file }
        if values.isSymbolicLink == true {
            return .symlink(target: symlinkTarget(of: url))
        }
        if values.isDirectory == true { return .directory }
        return .file
    }

    private func symlinkTarget(of url: URL) -> VFSPath? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let targetURL = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        let rootPrefix = rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix) else { return nil }   // outside the volume → leave nil
        let relative = targetURL.path.dropFirst(rootPrefix.count)
        return VFSPath(root: id, components: relative.split(separator: "/").map(String.init))
    }

    private func attributes(of url: URL, values: URLResourceValues?) -> VFSItemAttributes {
        var attributes = VFSItemAttributes()
        guard let values else { return attributes }
        attributes.size = values.isDirectory == true ? nil : Int64(values.fileSize ?? 0)
        attributes.created = values.creationDate
        attributes.modified = values.contentModificationDate
        // POSIX permissions are not exposed by URLResourceValues — an extra stat per item.
        let permission = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        attributes.posixPermissions = permission.map { Int16(truncatingIfNeeded: $0) }
        attributes.isHidden = values.isHidden ?? false
        attributes.tags = LocalVFS.userTags(of: url)
        if let finderInfo = LocalVFS.finderInfo(of: url) {
            attributes.urlResourceMeta[LocalVFS.finderInfoXattr] = finderInfo   // F-4 custom columns
        }
        return attributes
    }

    /// Cocoa/POSIX errno → MCError mapping at the adapter boundary (§5.8).
    private func mapFSError(_ error: Error, _ path: VFSPath) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadInvalidFileNameError:
                return MCError.vfsNotFound(path)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteFileExistsError:
                return MCError.vfsAccessDenied(path, underlying: error)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(ENOENT): return MCError.vfsNotFound(path)
            case Int(EACCES), Int(EPERM): return MCError.vfsAccessDenied(path, underlying: error)
            default: break
            }
        }
        return MCError.unexpected(underlying: error)
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// §5.5 sequential reader: one open FileHandle walked with bounded chunks.
final class LocalByteStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let storedLength: Int64
    private var closed = false

    init(handle: FileHandle, length: Int64) {
        self.handle = handle
        self.storedLength = length
    }

    var length: Int64 { storedLength }

    func readChunk(max: Int) async throws -> Data? {
        try withLock {
            guard max > 0 else {
                throw MCError.unexpected(underlying: NSError(
                    domain: "MyCommander.LocalVFS",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "readChunk(max:) must be positive"]
                ))
            }
            guard !closed else {
                throw MCError.unexpected(underlying: NSError(
                    domain: "MyCommander.LocalVFS",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "stream already drained/closed"]
                ))
            }
            guard let chunk = try handle.read(upToCount: max), !chunk.isEmpty else {
                closed = true
                return nil
            }
            return chunk
        }
    }

    deinit {
        if !closed { try? handle.close() }
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// §5.5 staged writer: bytes go into `.<name>.mc-partial` next to the target;
/// `finish(committingTo:)` fsyncs and renames (06 §6.2 temp→rename pattern).
final class LocalByteWriter: ByteStreamWriter, @unchecked Sendable {
    private let lock = NSLock()
    private let worker: LocalVFS
    private let handle: FileHandle
    private let stagedURL: URL
    private let targetKey: [String]
    private let replace: Bool
    private var finished = false

    init(owner: LocalVFS, handle: FileHandle, stagedURL: URL, targetKey: [String], replace: Bool) {
        self.worker = owner
        self.handle = handle
        self.stagedURL = stagedURL
        self.targetKey = targetKey
        self.replace = replace
    }

    func write(_ data: Data) async throws {
        try withLock {
            guard !finished else { throw writerMisuse("finish() already called") }
            try handle.write(contentsOf: data)
        }
    }

    func finish(committingTo finalTarget: VFSPath) async throws {
        try withLock {
            guard !finished else { throw writerMisuse("finish() already called") }
            finished = true
        }
        do {
            handle.synchronizeFile()   // not throwing by signature; errors surface at close/commit
            try handle.close()
        } catch {
            try? handle.close()
            worker.abandonWriter(key: targetKey, handle: handle, at: stagedURL)
            throw MCError.unexpected(underlying: error)
        }
        try worker.commit(temp: stagedURL, to: finalTarget, replace: replace, releasing: targetKey)
    }

    deinit {
        if !finished { worker.abandonWriter(key: targetKey, handle: handle, at: stagedURL) }
    }

    private func writerMisuse(_ reason: String) -> MCError {
        MCError.unexpected(underlying: NSError(
            domain: "MyCommander.LocalVFS",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "ByteWriter misuse: \(reason)"]
        ))
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
