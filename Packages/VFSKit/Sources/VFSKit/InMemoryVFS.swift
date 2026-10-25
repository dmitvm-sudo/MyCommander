// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import DomainKit

// Test fake (docs/SDD/11: VFSKit/InMemoryVFS.swift — «тестовый fake + errno-инжекция»).
// The basic InMemoryVFS (T-03) implements §5.3/§5.5 semantics purely in memory;
// errno/failure injection arrives with T-11 (docs/SDD/12).
//
// `copyContents` semantics: `target` is a DESTINATION DIRECTORY on the receiving VFS;
// the source object is created inside it (`target/<source.name>`) — two-panel copy.
// Existing file target → `MCError.transferConflict`; existing directory target merges.

/// Operation names for fault injection (docs/SDD/12 T-04: «InMemoryVFS errno-инъекция»;
/// consumable from T-11 trouble-matrix tests and later integration suites).
public enum VFSOperation: Sendable, Hashable, CaseIterable {
    case listDirectory
    case metadata
    case directorySize
    case createDirectory
    case rename
    case delete
    case copyContents
    case openRead
    case openWrite
    case setAttributes
}

public final class InMemoryVFS: VFS, @unchecked Sendable {
    final class FileContent {
        var data: Data
        var attributes: VFSItemAttributes
        init(data: Data, attributes: VFSItemAttributes) {
            self.data = data
            self.attributes = attributes
        }
    }

    public let id: VFSInstanceID
    public let capabilities = VFSCapabilities.inMemoryRW

    private let lock = NSLock()
    /// Root directory «""» always exists.
    private var directories: Set<[String]> = [[]]
    private var files: [[String]: FileContent] = [:]
    private var folderAttributes: [[String]: VFSItemAttributes] = [:]
    /// Staged-but-unfinished writers (temp slots, one per openWrite call).
    private var openWriters: Set<[String]> = []
    private var revisionCounter: UInt64 = 1
    /// Fault injection state: throw `error` from every listed operation (nil = clean).
    private var injection: (error: MCError, operations: Set<VFSOperation>)?

    public init(name: String = "default") {
        self.id = VFSInstanceID(kind: .localDisk, credentialRef: nil, specID: "inmemory:" + name)
    }

    /// Injects a failure for the given operations; `operations == nil` means «all».
    /// `error: nil` clears the injection back to a healthy fake.
    public func injectFailure(_ error: MCError?, for operations: Set<VFSOperation>? = nil) {
        withLock {
            if let error {
                injection = (error, operations ?? Set(VFSOperation.allCases))
            } else {
                injection = nil
            }
        }
    }

    private func checkInjection(_ operation: VFSOperation) throws {
        let current = withLock { injection }
        guard let current, current.operations.contains(operation) else { return }
        throw current.error
    }

    // MARK: §5.3 listing and metadata

    public func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        try checkInjection(.listDirectory)
        try checkOwn(path)
        let key = key(of: path)
        return try withLock { try listDirectoryLocked(key: key) }
    }

    private func listDirectoryLocked(key: [String]) throws -> [VFSItem] {
        guard directories.contains(key) else { throw MCError.vfsNotFound(vfsPath(of: key)) }
        var names = Set<String>()
        for fileKey in files.keys where parent(of: fileKey) == key {
            names.insert(fileKey.last!)
        }
        for dirKey in directories where dirKey.count == key.count + 1 && parent(of: dirKey) == key {
            names.insert(dirKey.last!)
        }
        return try names.sorted().map { name in
            try itemLocked(name: name, key: key + [name])
        }
    }

    public func metadata(of path: VFSPath) async throws -> VFSItem {
        try checkInjection(.metadata)
        try checkOwn(path)
        let key = key(of: path)
        return try withLock { try itemLocked(name: key.last ?? "", key: key) }
    }

    /// Fake: file → its size; directory → recursive file sum. The optional sink fires
    /// per visited file, emission happens after the locked walk (sinks must not poke
    /// back into this VFS from inside the lock).
    public func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        try checkInjection(.directorySize)
        try checkOwn(path)
        let key = key(of: path)
        var updates: [ProgressUpdate] = []
        let total: Int64 = try withLock {
            if let file = files[key] { return Int64(file.data.count) }
            guard directories.contains(key) else { throw MCError.vfsNotFound(path) }
            var sum: Int64 = 0
            for fileKey in files.keys where isProperSubpath(of: fileKey, under: key) {
                sum += Int64(files[fileKey]!.data.count)
                if progress != nil {
                    updates.append(ProgressUpdate(completedItems: updates.count + 1, message: fileKey.last))
                }
            }
            return sum
        }
        updates.forEach { progress?($0) }
        return total
    }

    // MARK: §5.3 mutations

    public func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        try checkInjection(.createDirectory)
        try checkOwn(parent)
        guard !name.isEmpty, !name.contains("/") else { throw MCError.vfsUnsupported(id, "EINVAL: name «\(name)»") }
        let parentKey = key(of: parent)
        let newKey = parentKey + [name]
        let created = vfsPath(of: newKey)
        try withLock {
            guard directories.contains(parentKey) else { throw MCError.vfsNotFound(parent) }
            if directories.contains(newKey) { return }          // idempotent, mkdir(2) «EEXIST»
            guard files[newKey] == nil else { throw MCError.vfsAccessDenied(created, underlying: nil) }
            directories.insert(newKey)
            bumpRevision()
        }
        return created
    }

    public func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        try checkInjection(.rename)
        try checkOwn(path)
        guard !name.isEmpty, !name.contains("/") else { throw MCError.vfsUnsupported(id, "EINVAL: name «\(name)»") }
        let sourceKey = key(of: path)
        let targetKey = Array(path.components.dropLast()) + [name]
        let renamed = vfsPath(of: targetKey)
        try withLock {
            let isDirectory = directories.contains(sourceKey)
            guard isDirectory || files[sourceKey] != nil else { throw MCError.vfsNotFound(path) }
            guard targetKey != sourceKey else { return }
            guard !directories.contains(targetKey), files[targetKey] == nil else {
                throw MCError.transferConflict(source: path, target: renamed)
            }
            if isDirectory {
                let movedDirs = directories.filter { isProperSubpath(of: $0, under: sourceKey) }
                for dirKey in movedDirs {
                    directories.remove(dirKey)
                    directories.insert(replacedPrefix(of: dirKey, replacing: sourceKey, with: targetKey))
                }
            }
            if let file = files.removeValue(forKey: sourceKey) {
                files[targetKey] = file
            }
            bumpRevision()
        }
        return renamed
    }

    /// Direct removal (06 §6.2: VFS без trash → прямое удаление; the fake has no trash).
    public func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        try checkInjection(.delete)
        try paths.forEach { try checkOwn($0) }
        try withLock {
            for path in paths {
                let target = key(of: path)
                let isDirectory = directories.contains(target)
                guard isDirectory || files[target] != nil else { throw MCError.vfsNotFound(path) }
                if isDirectory {
                    directories.subtract(directories.filter { isProperSubpath(of: $0, under: target) })
                    for fileKey in files.keys where isProperSubpath(of: fileKey, under: target) {
                        files.removeValue(forKey: fileKey)
                    }
                    directories.remove(target)   // the directory itself, not just its children
                } else {
                    files.removeValue(forKey: target)
                }
                bumpRevision()
            }
        }
    }

    /// Uses the default two-panel copy from the `VFS` extension (DomainKit) —
    /// no override: the fake delegates bytes through its own `openRead`/writers.

    // MARK: §5.5 streams

    public func openRead(_ path: VFSPath) async throws -> any ByteStream {
        try checkInjection(.openRead)
        try checkOwn(path)
        let key = key(of: path)
        return try withLock {
            guard !directories.contains(key) else { throw MCError.vfsUnsupported(id, "ENOTDIR (openRead on directory)") }
            guard let file = files[key] else { throw MCError.vfsNotFound(path) }
            return InMemoryByteStream(data: file.data)
            // Snapshot: later mutations never rewind this stream's window.
        }
    }

    public func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        try checkInjection(.openWrite)
        try checkOwn(path)
        let key = key(of: path)
        try withLock {
            guard directories.contains(parent(of: key)) else { throw MCError.vfsNotFound(path) }
            guard !directories.contains(key) else { throw MCError.vfsAccessDenied(path, underlying: nil) }
            guard !openWriters.contains(key) else { throw MCError.vfsAccessDenied(path, underlying: nil) }
            openWriters.insert(key)
        }
        return InMemoryByteWriter(owner: self, stagedPath: path, replace: replace)
    }

    public func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        try checkInjection(.setAttributes)
        try checkOwn(path)
        let key = key(of: path)
        try withLock {
            if let file = files[key] {
                mutate(&file.attributes)
                bumpRevision()
            } else if directories.contains(key) {
                var attributes = folderAttributes[key] ?? VFSItemAttributes()
                mutate(&attributes)
                folderAttributes[key] = attributes
                bumpRevision()
            } else {
                throw MCError.vfsNotFound(path)
            }
        }
    }

    // MARK: commit path (called by writers; T-10/T-11 exercise `.mc-partial` end-to-end)

    fileprivate func commit(_ data: Data, to finalTarget: VFSPath, replace: Bool, releasing stagedKey: [String]) throws {
        try checkOwn(finalTarget)
        let finalKey = key(of: finalTarget)
        try withLock {
            defer { openWriters.remove(stagedKey) }
            guard directories.contains(parent(of: finalKey)) else { throw MCError.vfsNotFound(finalTarget) }
            guard files[finalKey] == nil || replace else {
                throw MCError.transferConflict(source: finalTarget, target: finalTarget)
            }
            var attributes = VFSItemAttributes(created: Date(), modified: Date())
            attributes.size = Int64(data.count)
            files[finalKey] = FileContent(data: data, attributes: attributes)
            bumpRevision()
        }
    }

    fileprivate func abandonWriter(at stagedKey: [String]) {
        _ = withLock { openWriters.remove(stagedKey) }
    }

    // MARK: private plumbing

    private func checkOwn(_ path: VFSPath) throws {
        guard path.root == id else { throw MCError.vfsUnsupported(id, "path belongs to another instance") }
    }

    private func key(of path: VFSPath) -> [String] { path.components }

    private func parent(of components: [String]) -> [String] { Array(components.dropLast()) }

    private func replacedPrefix(of components: [String], replacing oldRoot: [String], with newRoot: [String]) -> [String] {
        newRoot + Array(components.dropFirst(oldRoot.count))
    }

    private func isProperSubpath(of components: [String], under root: [String]) -> Bool {
        components.count > root.count && Array(components.prefix(root.count)) == root
    }

    private func vfsPath(of components: [String]) -> VFSPath {
        VFSPath(root: id, components: components)
    }

    private func itemLocked(name: String, key: [String]) throws -> VFSItem {
        if directories.contains(key) {
            return VFSItem(
                id: vfsPath(of: key),
                instance: id,
                name: name,
                kind: .directory,
                attributes: folderAttributes[key] ?? VFSItemAttributes(),
                revision: revisionCounter
            )
        }
        guard let file = files[key] else { throw MCError.vfsNotFound(vfsPath(of: key)) }
        if file.attributes.size == nil { file.attributes.size = Int64(file.data.count) }
        return VFSItem(
            id: vfsPath(of: key),
            instance: id,
            name: name,
            kind: .file,
            attributes: file.attributes,
            revision: revisionCounter
        )
    }

    private func bumpRevision() {
        revisionCounter += 1
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// §5.5 writer for the fake: bytes accumulate in `buffer`; commitment happens on
/// `finish(committingTo:)` — the temp→rename pattern in miniature.
final class InMemoryByteWriter: ByteStreamWriter, @unchecked Sendable {
    private let owner: InMemoryVFS
    private let stagedKey: [String]
    private let replace: Bool
    private let lock = NSLock()
    private var buffer: Data = Data()
    private var finished = false

    init(owner: InMemoryVFS, stagedPath: VFSPath, replace: Bool) {
        self.owner = owner
        self.stagedKey = stagedPath.components
        self.replace = replace
    }

    func write(_ data: Data) async throws {
        try withLock {
            guard !finished else { throw writerMisuse("finish() already called") }
            buffer.append(data)
        }
    }

    func finish(committingTo finalTarget: VFSPath) async throws {
        let payload: Data = try withLock {
            guard !finished else { throw writerMisuse("finish() already called") }
            finished = true
            return buffer
        }
        try owner.commit(payload, to: finalTarget, replace: replace, releasing: stagedKey)
    }

    deinit {
        if !finished { owner.abandonWriter(at: stagedKey) }
    }

    private func writerMisuse(_ reason: String) -> MCError {
        MCError.unexpected(underlying: NSError(
            domain: "MyCommander.InMemoryVFS",
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

/// §5.5 sequential reader over an immutable byte snapshot.
final class InMemoryByteStream: ByteStreamSeekable, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var position = 0

    init(data: Data) {
        self.data = data
    }

    var length: Int64 { Int64(data.count) }

    /// Уточнение T-13: window seeks for the Lister (§5.5 ByteStreamSeekable).
    func seek(to offset: Int64) async throws {
        withLock {
            position = Int(min(max(offset, 0), Int64(data.count)))
        }
    }

    func readChunk(max: Int) async throws -> Data? {
        try withLock {
            guard position < data.count else { return Data?.none }
            guard max > 0 else { throw MCError.unexpected(underlying: NSError(
                domain: "MyCommander.InMemoryVFS",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "readChunk(max:) must be positive"]
            )) }
            let end = min(position + max, data.count)
            let chunk = data.subdata(in: position ..< end)
            position = end
            return chunk
        }
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
