// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore

// Contract: docs/SDD/06 §6.5 (уточнения T-23/T-25) — the SFTP connection
// lifetime on top of Citadel: connect → authenticate → open ONE SFTP
// sub-channel, then a SUPERVISOR task owns robustness: idle-KA every 30 s
// (a `getRealPath(".")` probe — Citadel 0.12.1 exposes no SSH-level
// keepalive), reconnect with the 1/2/4/8 s backoff schedule (max 5 attempts)
// and a published state (.connected / .reconnecting / .failed). Every failure
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

/// Host-key policy of one connection (06 §6.5: pinning lives in T-24's
/// `HostKeyPolicy`; the core accepts any validator the caller passes).
public struct SftpConnectionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: SftpAuthMethod
    public var hostKeyValidator: SSHHostKeyValidator
    /// Connection-establishment timeout (Citadel `connectTimeout`).
    public var connectTimeout: TimeInterval
    /// Idle keep-alive probe interval (06 §6.5: 30 s).
    public var keepAliveInterval: TimeInterval
    /// Reconnect delays per attempt (capped at the last element; 06 §6.5:
    /// 1/2/4/8 s). Empty schedule + `maxAttempts > 1` still retries after
    /// the last delay.
    public var reconnectSchedule: [TimeInterval]
    public var maxAttempts: Int

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: SftpAuthMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeInterval = 10,
        keepAliveInterval: TimeInterval = 30,
        reconnectSchedule: [TimeInterval] = [1, 2, 4, 8],
        maxAttempts: Int = 5
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.keepAliveInterval = keepAliveInterval
        self.reconnectSchedule = reconnectSchedule
        self.maxAttempts = maxAttempts
    }
}

/// Published supervisor state (06 §6.5 уточнение T-25): the App maps
/// `.reconnecting` onto the panel status line («Reconnect…») and reloads on
/// `.connected` — SFTP has no watch channel (05 §5.4).
public enum SftpConnectionState: Sendable, Equatable {
    case connected
    case reconnecting(attempt: Int, nextDelay: TimeInterval)
    case failed
}

/// One SFTP session with a robustness supervisor. `SFTPClient` is Sendable and
/// correlates request/response pairs by id; the `SSHClient` handle itself is
/// not declared Sendable by Citadel — both live inside a locked box owned
/// exclusively by this class and the supervisor task, hence `@unchecked`.
public final class SftpConnection: @unchecked Sendable {
    public let id: VFSInstanceID
    private let config: SftpConnectionConfig

    private struct Handles {
        var ssh: SSHClient
        var sftp: SFTPClient
    }

    private let handles: NIOLockedValueBox<Handles?>
    private let stateBox = NIOLockedValueBox<SftpConnectionState>(.connected)
    /// Fan-out of the supervisor state (06 §6.5 уточнение T-25).
    private nonisolated(unsafe) var onStateChange: (@Sendable (SftpConnectionState) -> Void)?
    private let supervisorBox = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// Stable session identity (05 §5.1: `sftp: connection id`).
    private static func instanceID(host: String, port: Int, user: String) -> VFSInstanceID {
        VFSInstanceID(
            kind: .sftp,
            credentialRef: nil,
            specID: "\(user)@\(host):\(port)#\(UUID().uuidString)"
        )
    }

    /// Publishes state to the box AND the callback (best effort).
    private func publish(_ state: SftpConnectionState) {
        stateBox.withLockedValue { $0 = state }
        onStateChange?(state)
    }

    /// Connects, authenticates and opens the SFTP subsystem; throws `MCError`.
    /// The supervisor task starts immediately (idle-KA + reconnect).
    public init(config: SftpConnectionConfig) async throws {
        self.config = config
        self.handles = NIOLockedValueBox<Handles?>(nil)
        self.id = Self.instanceID(host: config.host, port: config.port, user: config.username)
        let connected = try await Self.establish(config: config)
        handles.withLockedValue { $0 = connected }
        startSupervisor()
    }

    /// One connect → authenticate → openSFTP round; throws `MCError`.
    private static func establish(config: SftpConnectionConfig) async throws -> Handles {
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
                reconnect: .never,
                connectTimeout: .seconds(Int64(config.connectTimeout))
            )
            let sftp = try await client.openSFTP()
            return Handles(ssh: client, sftp: sftp)
        } catch {
            throw mapHandshake(error, host: config.host, port: config.port)
        }
    }

    /// The supervisor: idle-KA probes while connected, backoff reconnects
    /// while the server is away, `.failed` after `maxAttempts` (06 §6.5).
    private func startSupervisor() {
        supervisorBox.withLockedValue { current in
            guard current == nil else { return }
            current = Task<Void, Never> { [weak self] in
                await self?.supervise()
            }
        }
    }

    private func supervise() async {
        while true {
            // Idle phase: sleep, then probe.
            do {
                try await Task.sleep(for: .seconds(config.keepAliveInterval))
            } catch {
                return   // cancelled via close()
            }
            guard isActive else { break }
            do {
                _ = try await currentClient().getRealPath(atPath: ".")
            } catch {
                break   // the probe failed → reconnect phase
            }
        }
        await reconnectLoop()
    }

    private func reconnectLoop() async {
        for attempt in 1 ... max(1, config.maxAttempts) {
            let delay = Self.nextDelay(attempt: attempt, schedule: config.reconnectSchedule)
            publish(.reconnecting(attempt: attempt, nextDelay: delay))
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return   // cancelled via close()
            }
            do {
                let fresh = try await Self.establish(config: config)
                // A stale channel must not linger under the fresh one.
                await teardown()
                handles.withLockedValue { $0 = fresh }
                publish(.connected)
                await supervise()
                return
            } catch {
                continue   // next attempt (the state was published above)
            }
        }
        publish(.failed)
    }

    /// Contract helper: `schedule[attempt-1]`, capped at the last element.
    public static func nextDelay(attempt: Int, schedule: [TimeInterval]) -> TimeInterval {
        guard !schedule.isEmpty else { return 0 }
        return schedule[min(attempt - 1, schedule.count - 1)]
    }

    /// `true` while the underlying channel is alive.
    public var isActive: Bool {
        handles.withLockedValue { handle in
            guard let handle else { return false }
            return handle.ssh.isConnected && handle.sftp.isActive
        }
    }

    /// The last published supervisor state.
    public var state: SftpConnectionState {
        stateBox.withLockedValue { $0 }
    }

    /// The state fan-out (06 §6.5 уточнение T-25). Set BEFORE operations begin.
    public func setOnStateChange(_ callback: (@Sendable (SftpConnectionState) -> Void)?) {
        onStateChange = callback
    }

    private func teardown() async {
        let stale = handles.withLockedValue { current -> Handles? in
            defer { current = nil }
            return current
        }
        if let stale {
            try? await stale.sftp.close()
            try? await stale.ssh.close()
        }
    }

    /// Closes the SFTP channel and the SSH session; stops the supervisor.
    public func close() async {
        let task = supervisorBox.withLockedValue { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        task?.cancel()
        await teardown()
    }

    /// The shared SFTP client (callers must map thrown errors via `map(_:)`).
    func currentClient() throws -> SFTPClient {
        guard let handle = handles.withLockedValue({ $0 }) else {
            throw MCError.interrupted(reason: "connection closed")
        }
        return handle.sftp
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
