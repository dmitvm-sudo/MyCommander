// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Testing
import VFSKit

// T-23 acceptance (F-13 core, docs/SDD/12): a LIVE SFTP test server — an
// in-process Citadel `SSHServer` (full SSH/SFTP protocol over loopback TCP,
// host keys generated per test) with a FileManager-backed SFTPDelegate whose
// remote "/" is a temp directory. The suite covers the §5.3 operations end to
// end through the real handshake: listing, metadata, mkdir, rename, tree
// delete, streaming read (+ seek), the staged write protocol (publish /
// replace / conflict), errno mapping and the host-key pinning refusal.

private func sfRoot(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("sftpvfs-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func sfWrite(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

/// A free loopback port (BSD probe; small race window is fine for tests).
private func sfFreePort() -> Int {
    for _ in 0 ..< 64 {
        let candidate = Int.random(in: 21000 ..< 55000)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(candidate).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        defer { close(fd) }
        var flag: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &flag, socklen_t(MemoryLayout<Int32>.size))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult == 0 { return candidate }
    }
    return 22_222   // extremely unlikely to be reached
}

/// Password auth fixture («citadel» / «test»), mirrors Citadel's own tests.
private struct SFPasswordAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .password(let password) where request.username == "citadel" && password.password == "test":
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// FileManager-backed SFTP server: remote «/» == `root` (a temp directory).
private final class SFFileSystemDelegate: SFTPDelegate, @unchecked Sendable {
    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// Absolute SFTP path → local URL; «..» never reaches the mapping (the
    /// client VFS normalizes, but the server guards too — path traversal).
    private func url(_ path: String) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else {
            throw SFDelegateError.traversal
        }
        var result = root
        for component in components {
            result.appendPathComponent(component)
        }
        return result
    }

    enum SFDelegateError: Error { case traversal, notFound }

    private func attributes(_ url: URL) throws -> SFTPFileAttributes {
        let stat = try fm.attributesOfItem(atPath: url.path)
        let size = (stat[.size] as? NSNumber)?.uint64Value ?? 0
        let date = stat[.modificationDate] as? Date ?? Date()
        var sftpAttributes = SFTPFileAttributes(size: size, accessModificationTime: .init(
            accessTime: date,
            modificationTime: date
        ))
        var permissions = (stat[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        if stat[.type] as? FileAttributeType == .typeDirectory {
            permissions |= 0o040000
        }
        sftpAttributes.permissions = permissions
        return sftpAttributes
    }

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        // Citadel 0.12.1's server handler swallows delegate throws for the
        // stat family WITHOUT replying (the client would hang), so the
        // fixture never throws: a missing path reports attribute-less
        // metadata (size nil), which the adapter treats as «no file».
        guard let fileURL = try? url(path), fm.fileExists(atPath: fileURL.path) else {
            return SFTPFileAttributes.none
        }
        return try attributes(fileURL)
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> SFTPFileHandle {
        let fileURL = try url(filePath)
        if flags.contains(.create) {
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
        }
        guard fm.fileExists(atPath: fileURL.path) else { throw SFDelegateError.notFound }
        let handle = try FileHandle(forUpdating: fileURL)
        return SFFileHandle(handle: handle, flags: flags, url: fileURL, owner: self)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        try fm.removeItem(at: try url(filePath))
        return .ok
    }

    func createDirectory(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        try fm.createDirectory(at: try url(filePath), withIntermediateDirectories: false)
        return .ok
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        try fm.removeItem(at: try url(filePath))
        return .ok
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        // The whole canonical path rides in ONE component (Name.path joins by
        // «/», so the client's realpath loop converges immediately).
        [SFTPPathComponent(filename: canonicalUrl, longname: canonicalUrl, attributes: .none)]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        let directoryURL = try url(path)
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: nil) else {
            throw SFDelegateError.notFound
        }
        return SFDirectoryHandle(url: directoryURL, owner: self)
    }

    func setFileAttributes(
        to attributes: SFTPFileAttributes,
        atPath path: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        let fileURL = try url(path)
        var stat: [FileAttributeKey: Any] = [:]
        if let permissions = attributes.permissions {
            stat[.posixPermissions] = Int(permissions & 0o7777)
        }
        if let times = attributes.accessModificationTime {
            stat[.modificationDate] = times.modificationTime
        }
        try fm.setAttributes(stat, ofItemAtPath: fileURL.path)
        return .ok
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        try fm.createSymbolicLink(atPath: try url(linkPath).path, withDestinationPath: targetPath)
        return .ok
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let target = try fm.destinationOfSymbolicLink(atPath: try url(path).path)
        return [SFTPPathComponent(filename: target, longname: target, attributes: .none)]
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        let source = try url(oldPath)
        let target = try url(newPath)
        if fm.fileExists(atPath: target.path) { throw SFDelegateError.notFound }   // v3: no overwrite
        try fm.moveItem(at: source, to: target)
        return .ok
    }

    // MARK: handles

    private final class SFFileHandle: SFTPFileHandle, @unchecked Sendable {
        private let handle: FileHandle
        private let flags: SFTPOpenFileFlags
        private let fileURL: URL
        private let owner: SFFileSystemDelegate

        init(handle: FileHandle, flags: SFTPOpenFileFlags, url: URL, owner: SFFileSystemDelegate) {
            self.handle = handle
            self.flags = flags
            self.fileURL = url
            self.owner = owner
        }

        func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
            let size = (try owner.fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            try handle.seek(toOffset: min(offset, size))
            let data = handle.readData(ofLength: Int(length))
            return ByteBuffer(data: data)
        }

        func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
            try handle.seek(toOffset: offset)
            handle.write(Data(data.readableBytesView))
            return .ok
        }

        func close() async throws -> SFTPStatusCode {
            try? handle.close()
            return .ok
        }

        func readFileAttributes() async throws -> SFTPFileAttributes {
            try owner.attributes(fileURL)
        }

        func setFileAttributes(to attributes: SFTPFileAttributes) async throws {
            var stat: [FileAttributeKey: Any] = [:]
            if let permissions = attributes.permissions {
                stat[.posixPermissions] = Int(permissions & 0o7777)
            }
            if let times = attributes.accessModificationTime {
                stat[.modificationDate] = times.modificationTime
            }
            try owner.fm.setAttributes(stat, ofItemAtPath: fileURL.path)
        }
    }

    private final class SFDirectoryHandle: SFTPDirectoryHandle, @unchecked Sendable {
        private let url: URL
        private let owner: SFFileSystemDelegate

        init(url: URL, owner: SFFileSystemDelegate) {
            self.url = url
            self.owner = owner
        }

        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
            let entries = try owner.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return entries.map { entry in
                let attributes = (try? owner.attributes(entry)) ?? SFTPFileAttributes.none
                return SFTPFileListing(path: [SFTPPathComponent(
                    filename: entry.lastPathComponent,
                    longname: entry.lastPathComponent,
                    attributes: attributes
                )])
            }
        }
    }
}

/// One live server + connected client pair for a single test.
private struct SFFixture {
    let server: SSHServer
    let hostKey: NIOSSHPublicKey
    let port: Int
    let root: URL

    static func start(_ label: String) async throws -> SFFixture {
        let root = sfRoot(label)
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let port = sfFreePort()
        let server = try await SSHServer.host(
            host: "127.0.0.1",
            port: port,
            hostKeys: [hostKey],
            authenticationDelegate: SFPasswordAuth()
        )
        server.enableSFTP(withDelegate: SFFileSystemDelegate(root: root))
        return SFFixture(server: server, hostKey: hostKey.publicKey, port: port, root: root)
    }

    func connect() async throws -> SftpConnection {
        try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .trustedKeys([hostKey])
        ))
    }

    func stop() async {
        try? await server.close()
    }
}

/// The VFS-side root path for the fixture's SftpVFS (any SftpVFS instance id
/// works: the tests build paths from `vfs.id`).
private func sfPath(_ vfs: SftpVFS, _ components: String...) -> VFSPath {
    VFSPath(root: vfs.id, components: components)
}

@Suite("SftpVFS (F-13 core, T-23)")
struct SftpVFSTests {

    @Test func listDirectoryListsServerFiles() async throws {
        let fixture = try await SFFixture.start("list")
        defer { Task { await fixture.stop() } }
        sfWrite(Data("one\n".utf8), to: fixture.root.appendingPathComponent("one.txt"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let items = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(Set(items.map(\.name)) == ["one.txt", "sub"])
        await connection.close()
    }

    @Test func metadataReportsSizeKindAndDate() async throws {
        let fixture = try await SFFixture.start("meta")
        defer { Task { await fixture.stop() } }
        let payload = Data((0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0) })
        sfWrite(payload, to: fixture.root.appendingPathComponent("blob.bin"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let item = try await vfs.metadata(of: sfPath(vfs, "blob.bin"))
        if case .file = item.kind {} else { Issue.record("expected .file kind") }
        #expect(item.attributes.size == 100_000)
        #expect(item.attributes.modified != nil)
        await connection.close()
    }

    @Test func noSuchFileMapsThroughErrorMapper() {
        // Live note (06 §6.5 уточнение T-23): the Citadel server-side handler
        // swallows delegate throws for the stat family (no reply at all), so
        // the errno mapping table is covered directly — on real servers
        // (OpenSSH) the same statuses arrive over the wire.
        let instance = VFSInstanceID(kind: .sftp, specID: "t")
        let path = VFSPath(root: instance, components: ["gone.txt"])
        let noSuch = SftpConnection.map(Citadel.SFTPStatusCode.noSuchFile, instance: instance, path: path)
        if case .vfsNotFound = noSuch {} else { Issue.record("expected vfsNotFound, got \(noSuch)") }

        let denied = SftpConnection.map(Citadel.SFTPStatusCode.permissionDenied, instance: instance, path: path)
        if case .vfsAccessDenied = denied {} else { Issue.record("expected vfsAccessDenied, got \(denied)") }

        let unknown = SftpConnection.map(Citadel.SFTPStatusCode.unknown(99), instance: instance, path: path)
        if case .network = unknown {} else { Issue.record("expected .network, got \(unknown)") }

        let lost = SftpConnection.map(Citadel.SFTPStatusCode.connectionLost, instance: instance, path: path)
        if case .interrupted = lost {} else { Issue.record("expected .interrupted, got \(lost)") }
    }

    @Test func createDirectoryAndRenameThroughVFS() async throws {
        let fixture = try await SFFixture.start("mkdir")
        defer { Task { await fixture.stop() } }
        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)

        let created = try await vfs.createDirectory("newdir", in: VFSPath(root: vfs.id))
        #expect(created.components == ["newdir"])
        let listed = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(listed.map(\.name) == ["newdir"])

        let renamed = try await vfs.rename(created, to: "renamed")
        #expect(renamed.components == ["renamed"])
        let after = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(after.map(\.name) == ["renamed"])   // old name gone from the listing
        await connection.close()
    }

    @Test func deleteFileAndNestedTree() async throws {
        let fixture = try await SFFixture.start("delete")
        defer { Task { await fixture.stop() } }
        sfWrite(Data("a".utf8), to: fixture.root.appendingPathComponent("file.txt"))
        sfWrite(Data("deep".utf8), to: fixture.root.appendingPathComponent("tree/inner/deep.txt"))
        sfWrite(Data("shallow".utf8), to: fixture.root.appendingPathComponent("tree/other.txt"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        // Trash does not exist over SFTP — both modes delete directly (06 §6.5).
        try await vfs.delete([sfPath(vfs, "file.txt")], toTrash: true)
        try await vfs.delete([sfPath(vfs, "tree")], toTrash: false)

        let listed = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(listed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        await connection.close()
    }

    @Test func openReadRoundTripAndLength() async throws {
        let fixture = try await SFFixture.start("read")
        defer { Task { await fixture.stop() } }
        let payload = Data("sftp streaming payload\n".utf8)
        sfWrite(payload, to: fixture.root.appendingPathComponent("payload.txt"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let stream = try await vfs.openRead(sfPath(vfs, "payload.txt"))
        let length = try await stream.length
        #expect(length == Int64(payload.count))
        var collected = Data()
        while let chunk = try await stream.readChunk(max: 7) {
            collected.append(chunk)
        }
        #expect(collected == payload)
        await connection.close()
    }

    @Test func streamIsSeekable() async throws {
        let fixture = try await SFFixture.start("seek")
        defer { Task { await fixture.stop() } }
        let payload = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0) })
        sfWrite(payload, to: fixture.root.appendingPathComponent("seek.bin"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let stream = try await vfs.openRead(sfPath(vfs, "seek.bin"))
        let seekable = stream as? any ByteStreamSeekable
        #expect(seekable != nil)
        try await seekable?.seek(to: 3000)
        let chunk = try await seekable?.readChunk(max: 100)
        #expect(chunk == payload[3000 ..< 3100])
        await connection.close()
    }

    @Test func openWritePublishesThroughStaging() async throws {
        let fixture = try await SFFixture.start("write")
        defer { Task { await fixture.stop() } }
        sfWrite(Data("old".utf8), to: fixture.root.appendingPathComponent("keep.txt"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let target = sfPath(vfs, "fresh.txt")
        let writer = try await vfs.openWrite(target, replace: false)
        try await writer.write(Data("chunk one; ".utf8))
        try await writer.write(Data("chunk two".utf8))
        try await writer.finish(committingTo: target)

        // Published: the final carries the bytes, the staged temp is gone.
        let published = try Data(contentsOf: fixture.root.appendingPathComponent("fresh.txt"))
        #expect(published == Data("chunk one; chunk two".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!leftovers.contains { $0.hasPrefix(".") && $0.contains("mc-partial") })

        // replace=false over an existing final → transferConflict, temp cleaned.
        let secondWriter = try await vfs.openWrite(target, replace: false)
        try await secondWriter.write(Data("x".utf8))
        do {
            try await secondWriter.finish(committingTo: target)
            Issue.record("conflicting finish must throw")
        } catch let error as MCError {
            if case .transferConflict = error {} else { Issue.record("expected transferConflict, got \(error)") }
        }
        let afterConflict = try Data(contentsOf: fixture.root.appendingPathComponent("fresh.txt"))
        #expect(afterConflict == Data("chunk one; chunk two".utf8))
        await connection.close()
    }

    @Test func openWriteReplaceOverwritesExistingFinal() async throws {
        let fixture = try await SFFixture.start("replace")
        defer { Task { await fixture.stop() } }
        sfWrite(Data("stale-content".utf8), to: fixture.root.appendingPathComponent("doc.txt"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let target = sfPath(vfs, "doc.txt")
        let writer = try await vfs.openWrite(target, replace: true)
        try await writer.write(Data("fresh".utf8))
        try await writer.finish(committingTo: target)
        let replaced = try Data(contentsOf: fixture.root.appendingPathComponent("doc.txt"))
        #expect(replaced == Data("fresh".utf8))
        await connection.close()
    }

    @Test func directorySizeSumsTreeWithProgress() async throws {
        let fixture = try await SFFixture.start("size")
        defer { Task { await fixture.stop() } }
        sfWrite(sfZeros(100), to: fixture.root.appendingPathComponent("tree/a.txt"))
        sfWrite(sfZeros(200), to: fixture.root.appendingPathComponent("tree/nested/b.bin"))

        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let counter = SFCounter()
        let size = try await vfs.directorySize(of: sfPath(vfs, "tree")) { _ in
            counter.increment()
        }
        #expect(size == 300)
        #expect(counter.value >= 2)
        await connection.close()
    }

    @Test func hostKeyPinningRejectsForeignServer() async throws {
        let fixture = try await SFFixture.start("pinning")
        defer { Task { await fixture.stop() } }
        // A DIFFERENT host key: the pinned set holds a freshly generated one.
        let foreignKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        do {
            let connection = try await SftpConnection(config: SftpConnectionConfig(
                host: "127.0.0.1",
                port: fixture.port,
                username: "citadel",
                auth: .password("test"),
                hostKeyValidator: .trustedKeys([foreignKey])
            ))
            await connection.close()
            Issue.record("connection must fail host-key validation")
        } catch let error as MCError {
            if case .network = error {} else { Issue.record("expected .network(hostKeyRejected), got \(error)") }
        }
    }

    @Test func pathOfAnotherInstanceIsRefused() async throws {
        let fixture = try await SFFixture.start("foreign")
        defer { Task { await fixture.stop() } }
        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let foreign = VFSPath(
            root: VFSInstanceID(kind: .sftp, specID: "someone@elsewhere:22"),
            components: ["x"]
        )
        do {
            _ = try await vfs.listDirectory(at: foreign)
            Issue.record("foreign path must be refused")
        } catch let error as MCError {
            if case .vfsUnsupported = error {} else { Issue.record("expected vfsUnsupported, got \(error)") }
        }
        await connection.close()
    }
}

private func sfZeros(_ count: Int) -> Foundation.Data {
    Data(repeating: 7, count: count)
}

/// Lock-protected counter for the @Sendable progress sink (`sf` name-space).
private final class SFCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value_ = 0

    func increment() {
        lock.lock()
        value_ += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return value_
    }
}
