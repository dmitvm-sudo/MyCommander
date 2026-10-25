// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
import Testing
import VFSKit

// T-24 acceptance (F-13, docs/SDD/12): host-key pinning — the fingerprint
// format, the fail-closed policy matrix (match / first use / changed) and the
// LIVE pin flow against the in-process SFTP fixture: first use → accept →
// pin; a foreign server key → changed → decline → the handshake fails.

@Suite("HostKeyPolicy (F-13, T-24)")
struct HostKeyPolicyTests {

    // MARK: fingerprint format

    @Test func fingerprintFormat() {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let fingerprint = HostKeyFingerprint.compute(key)
        #expect(fingerprint.hasPrefix("SHA256:"))
        let body = fingerprint.dropFirst("SHA256:".count)
        #expect(body.count == 43)   // 32-byte digest, base64 without padding
        #expect(!body.contains("="))
    }

    @Test func fingerprintIsStableAndDistinct() {
        let a = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let b = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        #expect(HostKeyFingerprint.compute(a) == HostKeyFingerprint.compute(a))
        #expect(HostKeyFingerprint.compute(a) != HostKeyFingerprint.compute(b))
    }

    // MARK: policy matrix (EmbeddedEventLoop promises)

    /// Runs `validateHostKey` and awaits the promise outcome.
    private func outcome(of policy: HostKeyPolicy, key: NIOSSHPublicKey) async -> Bool {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Void.self)
        policy.validateHostKey(hostKey: key, validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            return true
        } catch {
            return false
        }
    }

    @Test func pinnedMatchSucceedsSilently() async {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let policy = HostKeyPolicy(pinnedFingerprint: HostKeyFingerprint.compute(key))
        // No handler at all: a matching pin must not need any decision.
        #expect(await outcome(of: policy, key: key))
    }

    @Test func noPinAndNoHandlerFailsClosed() async {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let policy = HostKeyPolicy(pinnedFingerprint: nil)
        #expect(!(await outcome(of: policy, key: key)))
    }

    @Test func mismatchWithNoHandlerFailsClosed() async {
        let pinnedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let foreignKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let policy = HostKeyPolicy(pinnedFingerprint: HostKeyFingerprint.compute(pinnedKey))
        #expect(!(await outcome(of: policy, key: foreignKey)))
    }

    @Test func firstUseHandlerDecides() async {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let seen = EventBox<HostKeyEvent?>(nil)
        let policy = HostKeyPolicy(pinnedFingerprint: nil, decisionHandler: { event in
            seen.set(event)
            return true
        })
        #expect(await outcome(of: policy, key: key))
        #expect(seen.get == .firstUse(fingerprint: HostKeyFingerprint.compute(key)))

        // Declining first use fails the handshake.
        let decline = HostKeyPolicy(pinnedFingerprint: nil, decisionHandler: { _ in false })
        #expect(!(await outcome(of: decline, key: key)))
    }

    @Test func changedEventCarriesBothFingerprints() async {
        let pinnedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let foreignKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let seen = EventBox<HostKeyEvent?>(nil)
        let policy = HostKeyPolicy(
            pinnedFingerprint: HostKeyFingerprint.compute(pinnedKey),
            decisionHandler: { event in
                seen.set(event)
                return true   // the explicit «re-trust» path
            }
        )
        #expect(await outcome(of: policy, key: foreignKey))
        #expect(seen.get == .changed(
            pinned: HostKeyFingerprint.compute(pinnedKey),
            presented: HostKeyFingerprint.compute(foreignKey)
        ))

        // The red-screen default: decline → the handshake dies (MITM guard).
        let decline = HostKeyPolicy(
            pinnedFingerprint: HostKeyFingerprint.compute(pinnedKey),
            decisionHandler: { _ in false }
        )
        #expect(!(await outcome(of: decline, key: foreignKey)))
    }

    // MARK: live pin flow (in-process SFTP server, docs/SDD/06 §6.5)

    @Test func liveFirstUseAcceptThenPinnedReconnect() async throws {
        let fixture = try await SFFixture.start("pin-flow")
        defer { Task { await fixture.stop() } }

        // First connect: no pin — the decision handler records and accepts.
        let events = EventBox<[HostKeyEvent]>([])
        let firstPolicy = HostKeyPolicy(pinnedFingerprint: nil, decisionHandler: { event in
            events.update { $0.append(event) }
            return true
        })
        let first = try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: fixture.port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .custom(firstPolicy)
        ))
        await first.close()
        #expect(events.get == [.firstUse(fingerprint: HostKeyFingerprint.compute(fixture.hostKey))])

        // Reconnect WITH the now-known pin: succeeds without any decision.
        let decisions = EventBox<Int>(0)
        let pinnedPolicy = HostKeyPolicy(
            pinnedFingerprint: HostKeyFingerprint.compute(fixture.hostKey),
            decisionHandler: { _ in
                decisions.set(1)   // any decision here is a policy failure
                return false
            }
        )
        let second = try await SftpConnection(config: SftpConnectionConfig(
            host: "127.0.0.1",
            port: fixture.port,
            username: "citadel",
            auth: .password("test"),
            hostKeyValidator: .custom(pinnedPolicy)
        ))
        await second.close()
        #expect(decisions.get == 0)
    }

    @Test func liveForeignServerKeyTriggersChangedAndDecline() async throws {
        let fixture = try await SFFixture.start("pin-mitm")
        defer { Task { await fixture.stop() } }

        // The pin holds a DIFFERENT key's fingerprint (an earlier session with
        // another host at this address) — the server's real key presents as
        // «changed», the classic MITM shape.
        let staleKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let pinnedFingerprint = HostKeyFingerprint.compute(staleKey)

        let changed = EventBox<HostKeyEvent?>(nil)
        let policy = HostKeyPolicy(
            pinnedFingerprint: pinnedFingerprint,
            decisionHandler: { event in
                changed.set(event)
                return false   // the red-screen «Abort»
            }
        )
        do {
            let connection = try await SftpConnection(config: SftpConnectionConfig(
                host: "127.0.0.1",
                port: fixture.port,
                username: "citadel",
                auth: .password("test"),
                hostKeyValidator: .custom(policy)
            ))
            await connection.close()
            Issue.record("a changed host key must not connect silently")
        } catch let error as MCError {
            if case .network = error {} else { Issue.record("expected .network, got \(error)") }
        }
        #expect(changed.get == .changed(
            pinned: pinnedFingerprint,
            presented: HostKeyFingerprint.compute(fixture.hostKey)
        ))
    }
}

// MARK: SftpPrivateKey (v1: unencrypted OpenSSH Ed25519)

@Suite("SftpPrivateKey (T-24)")
struct SftpPrivateKeyTests {
    /// A real `ssh-keygen -t ed25519` fixture (unencrypted, comment
    /// «mc-fixture»); the matching public key is asserted below.
    private static let fixture = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDjzQFU6YT+5LGOxxzlVUPz0UgslOOdR6YXvn9DSZ2bIgAAAJC6fASnunwE
    pwAAAAtzc2gtZWQyNTUxOQAAACDjzQFU6YT+5LGOxxzlVUPz0UgslOOdR6YXvn9DSZ2bIg
    AAAEAScSr5Om1+rqwaeo5KeqmE0EAE5cEccAWY5JcpAYtxoOPNAVTphP7ksY7HHOVVQ/PR
    SCyU451Hphe+f0NJnZsiAAAACm1jLWZpeHR1cmUBAgM=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let fixturePublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOPNAVTphP7ksY7HHOVVQ/PRSCyU451Hphe+f0NJnZsi"

    @Test func parsesRealOpenSSHKey() throws {
        let key = try SftpPrivateKey.ed25519(fromOpenSSH: Self.fixture)
        let expected = try NIOSSHPublicKey(openSSHPublicKey: Self.fixturePublic)
        #expect(NIOSSHPrivateKey(ed25519Key: key).publicKey == expected)
    }

    @Test func rejectsForeignArmor() {
        #expect(throws: MCError.self) {
            _ = try SftpPrivateKey.ed25519(fromOpenSSH: "not a key at all")
        }
    }

    @Test func rejectsCorruptedBody() {
        let body = Self.fixture
            .replacingOccurrences(of: "b3BlbnNzaC1rZXktdjEAAAAA", with: "b3BlbnNzaC1rZXktdjEBAAAA")
        #expect(throws: MCError.self) {
            _ = try SftpPrivateKey.ed25519(fromOpenSSH: body)
        }
    }

    @Test func rejectsTruncatedContainer() {
        let cut = Self.fixture
            .components(separatedBy: "\n")
            .dropLast(2)
            .joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----"
        #expect(throws: MCError.self) {
            _ = try SftpPrivateKey.ed25519(fromOpenSSH: cut)
        }
    }
}
