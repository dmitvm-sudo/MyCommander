// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Testing
import VFSKit

// T-25 acceptance (F-13, docs/SDD/12): SFTP robustness — the reconnect
// backoff schedule, the LIVE «перерубить сеть» scenario (the fixture server
// dies and returns on the same port/key; the supervisor reconnects and the
// VFS works again), idle-KA probes, exhaustion → .failed, and cooperative
// cancellation closing the channel mid-write.

/// Polls `condition` until it holds or the timeout elapses (50 ms stride).
private func waitUntil(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Suite("SftpRobustness (F-13, T-25)")
struct SftpRobustnessTests {

    // MARK: backoff schedule (pure)

    @Test func backoffScheduleIsCappedAtTheLastElement() {
        let schedule: [TimeInterval] = [1, 2, 4, 8]
        #expect(SftpConnection.nextDelay(attempt: 1, schedule: schedule) == 1)
        #expect(SftpConnection.nextDelay(attempt: 2, schedule: schedule) == 2)
        #expect(SftpConnection.nextDelay(attempt: 3, schedule: schedule) == 4)
        #expect(SftpConnection.nextDelay(attempt: 4, schedule: schedule) == 8)
        #expect(SftpConnection.nextDelay(attempt: 5, schedule: schedule) == 8)   // capped
        #expect(SftpConnection.nextDelay(attempt: 9, schedule: schedule) == 8)
        #expect(SftpConnection.nextDelay(attempt: 1, schedule: []) == 0)
    }

    // MARK: live «перерубить сеть»

    @Test func liveCablePullReconnectsAndVfsWorksAgain() async throws {
        let fixture = try await SFFixture.start("reconnect")
        defer { Task { await fixture.stop() } }

        let events = EventBox<[SftpConnectionState]>([])
        let connection = try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: fixture.port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .trustedKeys([fixture.hostKey]),
            keepAliveInterval: 0.2,
            reconnectSchedule: [0.2, 0.2, 0.2, 0.2],
            maxAttempts: 5
        ))
        connection.setOnStateChange { state in
            events.update { $0.append(state) }
        }
        let vfs = SftpVFS(connection: connection)

        // Pull the cable: every client session dies; the server stays up.
        await fixture.pullCable()

        // The supervisor must cycle through .reconnecting and land .connected.
        let recovered = await waitUntil(timeout: 15) {
            connection.state == .connected
                && events.get.contains { if case .reconnecting = $0 { return true }; return false }
        }
        #expect(recovered)

        // The VFS works again over the fresh channel.
        let items = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(items.isEmpty)   // fresh server, same (empty) root dir
        await connection.close()
    }

    @Test func liveKeepAliveProbesHitTheServer() async throws {
        let fixture = try await SFFixture.start("ka")
        defer { Task { await fixture.stop() } }
        let connection = try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: fixture.port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .trustedKeys([fixture.hostKey]),
            keepAliveInterval: 0.15
        ))
        let probed = await waitUntil(timeout: 5) {
            fixture.realPathCounter.value >= 2
        }
        #expect(probed)   // ≥2 probes in ~0.5 s of idling
        await connection.close()
    }

    @Test func liveExhaustedAttemptsPublishFailed() async throws {
        let fixture = try await SFFixture.start("exhaust")
        defer { Task { await fixture.stop() } }
        let connection = try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: fixture.port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .trustedKeys([fixture.hostKey]),
            keepAliveInterval: 0.1,
            reconnectSchedule: [0.1],
            maxAttempts: 2
        ))
        // Kill the server WITHOUT restarting it: both attempts fail.
        await fixture.stop()
        let failed = await waitUntil(timeout: 15) {
            connection.state == .failed
        }
        #expect(failed)
        await connection.close()
    }

    // MARK: cancellation («мгновенный close-channel»)

    @Test func liveCancelledWriteClosesChannelKeepsStagedPartial() async throws {
        let fixture = try await SFFixture.start("cancel-write")
        defer { Task { await fixture.stop() } }
        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let target = sfPath(vfs, "big.bin")
        let writer = try await vfs.openWrite(target, replace: false)

        let chunk = Data(repeating: 0xAB, count: 4096)
        // Deterministic gate: the writer task waits for release, the parent
        // cancels it BEFORE the first write — readChunk/write then observe
        // Task.isCancelled deterministically.
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let writeTask = Task<Bool, Error> {
            for await _ in gate {}
            for _ in 0 ..< 10_000 {
                try await writer.write(chunk)
            }
            return true
        }
        try await Task.sleep(for: .milliseconds(50))   // the child reached the gate
        writeTask.cancel()
        gateContinuation.finish()
        do {
            _ = try await writeTask.value
            Issue.record("a cancelled write must not complete")
        } catch is CancellationError {
            // cooperative cancellation surfaced
        } catch let error as MCError {
            if case .canceled = error {} else {
                Issue.record("expected .canceled, got \(error)")
            }
        }

        // The staged partial NEVER became the final (finish never ran).
        let listed = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(!listed.contains { $0.name == "big.bin" })
        await connection.close()
    }

    @Test func liveCancelledReadThrowsCanceled() async throws {
        let fixture = try await SFFixture.start("cancel-read")
        defer { Task { await fixture.stop() } }
        sfWrite(Data(repeating: 9, count: 100_000), to: fixture.root.appendingPathComponent("big.bin"))
        let connection = try await fixture.connect()
        let vfs = SftpVFS(connection: connection)
        let stream = try await vfs.openRead(sfPath(vfs, "big.bin"))

        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let readTask = Task<Data?, Error> {
            for await _ in gate {}
            return try await stream.readChunk(max: 100)
        }
        try await Task.sleep(for: .milliseconds(50))   // the child reached the gate
        readTask.cancel()
        gateContinuation.finish()
        do {
            _ = try await readTask.value
            Issue.record("a cancelled read must not complete")
        } catch is CancellationError {
            // cooperative cancellation surfaced to the caller
        } catch let error as MCError {
            if case .canceled = error {} else {
                Issue.record("expected .canceled, got \(error)")
            }
        }
        await connection.close()
    }
}
