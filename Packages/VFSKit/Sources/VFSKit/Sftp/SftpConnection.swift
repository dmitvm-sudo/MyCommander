// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.5 (уточнение T-23) — the SFTP connection lifetime on
// top of Citadel: connect → authenticate → open ONE SFTP sub-channel. The
// robustness layer (idle-KA, reconnect backoff, timeouts) arrives with T-25;
// the core keeps `reconnectMode: .never` and a plain lifetime. Every failure
// crossing this boundary is mapped into `MCError` (docs/SDD/05 §5.8, rule 5):
// SFTP status codes → typed MCError cases (06 §6.5 уточнение T-23), everything
// else (handshake, auth, host key) → `.network` with the carrier code.

/// Authentication material for one connection. The OpenSSH key STRING parsing
/// and the Keychain plumbing belong to ConnectionStore (T-24); the core takes
/// the parsed key.
public enum SftpAuthMethod: Sendable {
    case password(String)
    case ed25519(privateKey: Curve25519.Signing.PrivateKey)
}

/// Host-key policy of one connection (06 §6.5: pinning + fingerprint UI come
/// with T-24; the core accepts any validator the caller passes — tests use
/// `trustedKeys`, a bare probe may use `acceptAnything`).
public struct SftpConnectionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SftpAuthMethod
    public var hostKeyValidator: SSHHostKeyValidator

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: SftpAuthMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyValidator = hostKeyValidator
    }
}

/// One open SFTP session: `SSHClient` + its single `SFTPClient` sub-channel.
/// `SFTPClient` is Sendable and correlates request/response pairs by id, so all
/// VFS operations share one channel (06 §6.5 уточнение T-23). The SSHClient
/// handle itself is not declared Sendable by Citadel; this class owns it
/// exclusively and exposes only the SFTP surface — hence `@unchecked`.
public final class SftpConnection: @unchecked Sendable {
    public let id: VFSInstanceID
    private let ssh: SSHClient
    private let sftp: SFTPClient

    /// Stable session identity (05 §5.1: `sftp: connection id`).
    private static func instanceID(host: String, port: Int, user: String) -> VFSInstanceID {
        VFSInstanceID(
            kind: .sftp,
            credentialRef: nil,
            specID: "\(user)@\(host):\(port)#\(UUID().uuidString)"
        )
    }

    /// Connects, authenticates and opens the SFTP subsystem; throws `MCError`.
    public init(config: SftpConnectionConfig) async throws {
        let method: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            method = .passwordBased(username: config.username, password: password)
        case .ed25519(let key):
            method = .ed25519(username: config.username, privateKey: key)
        }
        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: method,
                hostKeyValidator: config.hostKeyValidator,
                reconnect: .never
            )
            let sftp = try await client.openSFTP()
            self.ssh = client
            self.sftp = sftp
            self.id = Self.instanceID(host: config.host, port: config.port, user: config.username)
        } catch {
            throw Self.mapHandshake(error, host: config.host, port: config.port)
        }
    }

    /// `true` while the underlying channel is alive.
    public var isActive: Bool {
        ssh.isConnected && sftp.isActive
    }

    /// Closes the SFTP channel and the SSH session.
    public func close() async {
        try? await sftp.close()
        try? await ssh.close()
    }

    /// The shared SFTP client (callers must map thrown errors via `map(_:)`).
    var client: SFTPClient {
        sftp
    }

    /// Absolute SFTP path from normalized components («/» root = empty);
    /// shared with the writer inside SftpVFS (same module).
    func sftpPath(_ path: VFSPath) -> String {
        guard !path.components.isEmpty else { return "/" }
        return "/" + path.components.joined(separator: "/")
    }

    // MARK: error mapping (06 §6.5 уточнение T-23)

    /// SFTP status code → MCError. Path-sensitive codes (`noSuchFile`,
    /// `permissionDenied`) sharpen when the caller supplies a path.
    static func map(_ error: Error, instance: VFSInstanceID, path: VFSPath?) -> MCError {
        // The canonical shape: the server answered with a status message.
        if let status = status(of: error) {
            return map(status.errorCode, instance: instance, path: path)
        }
        switch error {
        case let sftpError as Citadel.SFTPError:
            switch sftpError {
            case .connectionClosed, .missingResponse:
                return .interrupted(reason: String(describing: sftpError))
            case .errorStatus(let status):
                return map(status.errorCode, instance: instance, path: path)
            default:
                return .network(instance, code: String(describing: sftpError))
            }
        default:
            return .network(instance, code: String(describing: error))
        }
    }

    /// The mapping table itself (public for testability and for callers that
    /// hold a bare status code — 06 §6.5 errno-mapping is contract).
    public static func map(_ code: Citadel.SFTPStatusCode, instance: VFSInstanceID, path: VFSPath?) -> MCError {
        switch code {
        case .noSuchFile:
            return path.map { .vfsNotFound($0) } ?? .network(instance, code: "SSH_FX_NO_SUCH_FILE")
        case .permissionDenied:
            return path.map { .vfsAccessDenied($0, underlying: nil) }
                ?? .network(instance, code: "SSH_FX_PERMISSION_DENIED")
        case .ok, .eof:
            // EOF is a normal read terminator — reaching the mapper means a
            // misuse at the call site.
            return .unexpected(underlying: SFStatusMisuse(code: code))
        case .failure, .badMessage, .unsupportedOperation:
            return .network(instance, code: code.debugDescription)
        case .noConnection, .connectionLost:
            return .interrupted(reason: code.debugDescription)
        case .unknown(let value):
            return .network(instance, code: "SSH_FX_\(value)")
        }
    }

    private struct SFStatusMisuse: Error {
        let code: Citadel.SFTPStatusCode
    }

    /// Unwraps `SFTPError.errorStatus`/direct Status errors to the Status.
    private static func status(of error: Error) -> Citadel.SFTPMessage.Status? {
        switch error {
        case let status as Citadel.SFTPMessage.Status:
            return status
        case let sftpError as Citadel.SFTPError:
            if case .errorStatus(let status) = sftpError { return status }
            return nil
        default:
            return nil
        }
    }

    /// Handshake/auth failures (no path context): connect timeout, auth
    /// rejection, host key rejection — all surface as `.network` codes.
    private static func mapHandshake(_ error: Error, host: String, port: Int) -> MCError {
        let code: String
        switch error {
        case let sftpError as Citadel.SFTPError:
            code = String(describing: sftpError)
        case let invalid as InvalidHostKey:
            code = "hostKeyRejected (\(invalid))"
        default:
            code = String(describing: error)
        }
        return .network(
            VFSInstanceID(kind: .sftp, specID: "\(host):\(port)"),
            code: code
        )
    }
}
