// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import DomainKit
import Foundation
import NIO
import NIOConcurrencyHelpers

// Contract: docs/SDD/05 §5.3 + 06 §6.5 (уточнение T-23) — the SFTP adapter.
// `VFSPath` components are the segments of an ABSOLUTE SFTP path (root «/» =
// empty components); item metadata comes from SFTP attributes; reads are
// offset-based (`ByteStreamSeekable`), writes follow the staging protocol
// (`.mc-partial` → finish → rename, 06 §6.2). Errors are mapped into `MCError`
// at this boundary (§5.8); SFTP has no trash — `delete(toTrash: true)` deletes
// directly (confirmation lives in the UI).

public final class SftpVFS: VFS, @unchecked Sendable {
    public let id: VFSInstanceID
    public let capabilities = VFSCapabilities(
        canWrite: true,
        canDelete: true,
        canRename: true,
        canWatch: false,
        canRandomSeek: true,
        preservesDates: false,
        symlinkSupport: false,
        maxPathLength: 4096
    )

    private let connection: SftpConnection
    /// Snapshot revision (§5.4): bumped by every committed mutation.
    private let revisionBox = NIOLockedValueBox<UInt64>(1)

    /// Adapts an established connection. One VFS instance per connection.
    public init(connection: SftpConnection) {
        self.connection = connection
        self.id = connection.id
    }

    /// Live connection (the App uses this for the «Reconnect…» state later).
    public var isActive: Bool {
        connection.isActive
    }

    /// Closes the underlying SSH/SFTP session.
    public func close() async {
        await connection.close()
    }

    // MARK: paths

    /// Absolute SFTP path from the normalized components («/» root = empty).
    private func absolute(_ path: VFSPath) -> String {
        guard !path.components.isEmpty else { return "/" }
        return "/" + path.components.joined(separator: "/")
    }

    private func checkOwn(_ path: VFSPath) throws {
        guard path.root == id else {
            throw MCError.vfsUnsupported(id, "path belongs to another instance")
        }
    }

    private var revision: UInt64 {
        revisionBox.withLockedValue { $0 }
    }

    private func bumpRevision() {
        revisionBox.withLockedValue { $0 &+= 1 }
    }

    // MARK: §5.8 error boundary

    private func map(_ error: Error, _ path: VFSPath? = nil) -> MCError {
        SftpConnection.map(error, instance: id, path: path)
    }

    // MARK: item mapping

    private func makeItem(path: VFSPath, name: String, attributes: SFTPFileAttributes) -> VFSItem {
        let mode = attributes.permissions ?? 0
        let kind: VFSItemKind
        switch mode & 0o170000 {
        case 0o040000:
            kind = .directory
        case 0o120000:
            kind = .symlink(target: nil)   // v1: target resolution not materialized
        default:
            kind = .file
        }
        let writeable = mode & 0o200 != 0
        return VFSItem(
            id: path,
            instance: id,
            name: name,
            kind: kind,
            attributes: VFSItemAttributes(
                size: attributes.size.map { Int64(clamping: $0) },
                modified: attributes.accessModificationTime?.modificationTime,
                posixPermissions: Int16(clamping: mode & 0o7777),
                owner: attributes.uidgid.map { "\($0.userId)" },
                group: attributes.uidgid.map { "\($0.groupId)" },
                isHidden: name.hasPrefix("."),
                isReadOnly: !writeable
            ),
            revision: revision
        )
    }

    private func childPath(_ parent: VFSPath, _ name: String) -> VFSPath {
        parent.appending(component: name)
    }

    // MARK: §5.3 listing / metadata

    public func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        try checkOwn(path)
        do {
            let names = try await connection.currentClient().listDirectory(atPath: absolute(path))
            let entries = names.flatMap { $0.components }
            return entries.compactMap { component in
                guard component.filename != ".", component.filename != ".." else { return nil }
                return makeItem(
                    path: childPath(path, component.filename),
                    name: component.filename,
                    attributes: component.attributes
                )
            }
        } catch {
            throw map(error, path)
        }
    }

    public func metadata(of path: VFSPath) async throws -> VFSItem {
        try checkOwn(path)
        let name = path.components.last ?? "/"
        do {
            let attributes = try await connection.currentClient().getAttributes(at: absolute(path))
            return makeItem(path: path, name: name, attributes: attributes)
        } catch {
            throw map(error, path)
        }
    }

    /// Recursive size sum (06 §6.5: dirSize through listDirectory recursion);
    /// the progress sink reports one step per visited entry.
    public func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        try checkOwn(path)
        return try await walkSize(path, progress: progress)
    }

    private func walkSize(_ path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        if Task.isCancelled { throw MCError.canceled }
        let item = try await metadata(of: path)
        progress?(ProgressUpdate(completedItems: 1, totalItems: nil, message: item.name))
        switch item.kind {
        case .file, .special:
            return item.attributes.size ?? 0
        case .symlink:
            return 0
        case .directory:
            var total: Int64 = 0
            for child in try await listDirectory(at: path) {
                total += try await walkSize(child.id, progress: progress)
            }
            return total
        }
    }

    // MARK: §5.3 mutations

    public func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        try checkOwn(parent)
        let target = childPath(parent, name)
        do {
            try await connection.currentClient().createDirectory(atPath: absolute(target))
            bumpRevision()
            return target
        } catch {
            throw map(error, target)
        }
    }

    public func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        try checkOwn(path)
        guard !path.components.isEmpty else {
            throw MCError.vfsUnsupported(id, "cannot rename the server root")
        }
        let target = childPath(path.parent, name)
        do {
            try await connection.currentClient().rename(at: absolute(path), to: absolute(target))
            bumpRevision()
            return target
        } catch {
            throw map(error, path)
        }
    }

    /// SFTP has no trash (06 §6.5): both modes delete directly. Trees are
    /// dismantled bottom-up — SFTP has no bulk «rm -r».
    public func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        for path in paths {
            try checkOwn(path)
            try await deleteTree(path)
        }
        bumpRevision()
    }

    private func deleteTree(_ path: VFSPath) async throws {
        if Task.isCancelled { throw MCError.canceled }
        let item = try await metadata(of: path)
        if case .directory = item.kind {
            for child in try await listDirectory(at: path) {
                try await deleteTree(child.id)
            }
        }
        do {
            if case .directory = item.kind {
                try await connection.currentClient().rmdir(at: absolute(path))
            } else {
                try await connection.currentClient().remove(at: absolute(path))
            }
        } catch {
            throw map(error, path)
        }
    }

    // MARK: §5.5 byte streams

    /// Offset-based read stream (canRandomSeek — 06 §6.5): one open SFTPFile,
    /// local cursor, reads clamped to the SFTP packet limit (32 KB).
    private final class SftpByteStream: ByteStreamSeekable, @unchecked Sendable {
        private let file: SFTPFile
        private let instance: VFSInstanceID
        private let state: NIOLockedValueBox<Int64>   // cursor
        private let totalLength: Int64
        /// SFTP packet/window limit (swift-nio-ssh #99 / 06 §6.5).
        private static let maxPacketPayload = 32_768

        init(file: SFTPFile, length: Int64, instance: VFSInstanceID, startOffset: Int64 = 0) {
            self.file = file
            self.totalLength = max(0, length)
            self.instance = instance
            self.state = NIOLockedValueBox(min(max(0, startOffset), self.totalLength))
        }

        var length: Int64 {
            totalLength
        }

        func readChunk(max limit: Int) async throws -> Data? {
            // Cancellation = «мгновенный close-channel» (06 §6.5 уточнение T-25).
            if Task.isCancelled {
                try? await file.close()
                throw MCError.canceled
            }
            let position = state.withLockedValue { $0 }
            guard position < totalLength else { return nil }
            let want = Int64(min(
                min(limit, Self.maxPacketPayload),
                Int(clamping: totalLength - position)
            ))
            do {
                let buffer = try await file.read(from: UInt64(clamping: position), length: UInt32(want))
                let data = Data(buffer: buffer)
                guard !data.isEmpty else { return nil }   // EOF status → empty
                state.withLockedValue { $0 = position + Int64(data.count) }
                return data
            } catch {
                throw SftpConnection.map(error, instance: instance, path: nil)
            }
        }

        func seek(to offset: Int64) async throws {
            state.withLockedValue { $0 = min(max(0, offset), totalLength) }
        }

        func close() async {
            try? await file.close()
        }
    }

    public func openRead(_ path: VFSPath) async throws -> any ByteStream {
        try checkOwn(path)
        do {
            let file = try await connection.currentClient().openFile(filePath: absolute(path), flags: .read)
            // Size comes from the handle's own attributes (fstat semantics).
            let attributes = (try? await file.readAttributes()) ?? .none
            let length = attributes.size.map { Int64(clamping: $0) } ?? 0
            return SftpByteStream(file: file, length: length, instance: id)
        } catch {
            throw map(error, path)
        }
    }

    /// Staging writer (06 §6.2): bytes land in `.<name>.mc-partial` inside the
    /// target's parent; `finish` closes, resolves the final-target conflict
    /// (replace=false → `transferConflict`; replace=true → pre-remove, because
    /// SFTP_RENAME v3 does not overwrite) and renames.
    private final class SftpStreamWriter: ByteStreamWriter, @unchecked Sendable {
        private struct WriteState {
            var offset: Int64 = 0
            var finished = false
        }

        private let file: SFTPFile
        private let connection: SftpConnection
        private let tempPath: VFSPath
        private let replace: Bool
        private let state = NIOLockedValueBox(WriteState())

        init(file: SFTPFile, connection: SftpConnection, tempPath: VFSPath, replace: Bool) {
            self.file = file
            self.connection = connection
            self.tempPath = tempPath
            self.replace = replace
        }

        func write(_ data: Data) async throws {
            // Cancellation = «мгновенный close-channel» (06 §6.5 уточнение T-25).
            if Task.isCancelled {
                try? await file.close()
                throw MCError.canceled
            }
            let position = state.withLockedValue { current -> Int64 in
                current.offset += Int64(data.count)
                return current.offset - Int64(data.count)
            }
            do {
                try await file.write(ByteBuffer(data: data), at: UInt64(clamping: position))
            } catch {
                throw SftpConnection.map(error, instance: connection.id, path: tempPath)
            }
        }

        func finish(committingTo finalTarget: VFSPath) async throws {
            let alreadyFinished = state.withLockedValue { current -> Bool in
                let was = current.finished
                current.finished = true
                return was
            }
            guard !alreadyFinished else {
                throw MCError.vfsUnsupported(connection.id, "writer already finished")
            }
            do {
                try await file.close()
                let sftp = try connection.currentClient()
                let finalPath = connection.sftpPath(finalTarget)
                if let existing = try? await sftp.getAttributes(at: finalPath) {
                    if existing.size != nil {
                        guard replace else {
                            throw MCError.transferConflict(source: tempPath, target: finalTarget)
                        }
                        // SFTP_RENAME v3 fails instead of overwriting — clear
                        // the stale final first (06 §6.5 уточнение T-23).
                        try await sftp.remove(at: finalPath)
                    }
                }
                try await sftp.rename(at: connection.sftpPath(tempPath), to: finalPath)
            } catch let error as MCError {
                try? await connection.currentClient().remove(at: connection.sftpPath(tempPath))
                throw error
            } catch {
                try? await connection.currentClient().remove(at: connection.sftpPath(tempPath))
                throw SftpConnection.map(error, instance: connection.id, path: finalTarget)
            }
        }
    }

    public func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        try checkOwn(path)
        guard !path.components.isEmpty else {
            throw MCError.vfsUnsupported(id, "cannot write the server root")
        }
        let parent = path.parent
        let staged = childPath(parent, "." + (path.components.last ?? "file") + ".mc-partial")
        do {
            let file = try await connection.currentClient().openFile(
                filePath: absolute(staged),
                flags: [.write, .create, .truncate]
            )
            return SftpStreamWriter(file: file, connection: connection, tempPath: staged, replace: replace)
        } catch {
            throw map(error, path)
        }
    }

    // MARK: attributes

    public func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        try checkOwn(path)
        var attributes = VFSItemAttributes()
        mutate(&attributes)
        var sftpAttributes = SFTPFileAttributes.none
        if let permissions = attributes.posixPermissions {
            // Preserve the file-type bits of the current mode (server-side
            // setstat replaces the whole mode word — 06 §6.5).
            let current = try await connection.currentClient().getAttributes(at: absolute(path))
            let typeBits = (current.permissions ?? 0) & 0o170000
            sftpAttributes.permissions = typeBits | (UInt32(permissions) & 0o7777)
        }
        if let modified = attributes.modified {
            sftpAttributes.accessModificationTime = .init(
                accessTime: modified,
                modificationTime: modified
            )
        }
        do {
            try await connection.currentClient().setAttributes(at: absolute(path), to: sftpAttributes)
            bumpRevision()
        } catch {
            throw map(error, path)
        }
    }

    // §5.3: server-side copy is a v1.x feature — the default extension walks
    // openRead/openWrite (docs/SDD/12 «Уточнение T-04»), no override here.
}
