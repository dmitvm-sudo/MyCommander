// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import VFSKit

// T-23/T-24 test support: the in-process live SFTP fixture (docs/SDD/06 §6.5) —
// a Citadel SSHServer with a FileManager-backed SFTPDelegate whose remote «/»
// is a temp directory. Shared by SftpVFSTests and HostKeyPolicyTests.

func sfRoot(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("sftpvfs-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func sfWrite(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

/// A free loopback port (BSD probe; small race window is fine for tests).
func sfFreePort() -> Int {
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
struct SFPasswordAuth: NIOSSHServerUserAuthenticationDelegate {
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
final class SFFileSystemDelegate: SFTPDelegate, @unchecked Sendable {
    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// Absolute SFTP path → local URL; «..» never reaches the mapping (the
    /// client VFS normalizes, but the server guards too — path traversal).
    func url(_ path: String) throws -> URL {
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

    func attributes(_ url: URL) throws -> SFTPFileAttributes {
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

    final class SFFileHandle: SFTPFileHandle, @unchecked Sendable {
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

    final class SFDirectoryHandle: SFTPDirectoryHandle, @unchecked Sendable {
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
struct SFFixture {
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
func sfPath(_ vfs: SftpVFS, _ components: String...) -> VFSPath {
    VFSPath(root: vfs.id, components: components)
}
