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
