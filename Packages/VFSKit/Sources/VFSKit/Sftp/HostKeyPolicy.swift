// SPDX-License-Identifier: GPL-3.0-or-later

import Citadel
import Crypto
import DomainKit
import Foundation
import NIOCore
import NIOSSH

// Contract: docs/SDD/06 §6.5 (уточнение T-24) — host-key pinning for F-13.
// The policy is a plain `NIOSSHClientServerAuthenticationDelegate` plugged into
// Citadel via `SSHHostKeyValidator.custom(policy)`. Decisions NEVER live here:
// VFSKit stays AppKit-free — the App supplies an async decision handler
// (NSAlerts on the main actor); without a handler unknown fingerprints are
// declined (fail-closed). Every fingerprint is SHA-256 over the SSH wire
// format of the key, rendered OpenSSH-style: `SHA256:<base64 without padding>`.

/// The stable fingerprint of a host key (wire-format SHA-256).
public enum HostKeyFingerprint {
    /// `SHA256:<base64 without padding>` over `NIOSSHPublicKey.write(to:)`.
    public static func compute(_ key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        _ = key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
    }
}

/// The events a caller must decide on (06 §6.5: first use / fingerprint change).
public enum HostKeyEvent: Sendable, Equatable {
    /// No pin stored yet — the classic «first connection» dialog.
    case firstUse(fingerprint: String)
    /// The server presents a DIFFERENT key than the pinned one — the MITM
    /// red-screen case (F-13 acceptance). `pinned` vs `presented` fingerprints.
    case changed(pinned: String, presented: String)
}

/// The handshake error the policy fails the promise with when a key is not
/// trusted (Citadel's `InvalidHostKey` has an internal initializer).
public struct HostKeyRejectedError: Error, Equatable {}

/// Pinning host-key policy (docs/SDD/06 §6.5 уточнение T-24):
/// - pinned fingerprint matches → succeed silently;
/// - no pin → `firstUse` through the decision handler;
/// - different pin → `changed` through the handler (red screen in App);
/// - no handler (or handler returns `false`) → the handshake fails.
/// The async handler is bridged into the sync promise callback with a Task —
/// `EventLoopPromise` is thread-safe, so resuming from any executor is legal.
public final class HostKeyPolicy: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    /// The pin from `ConnectionRecord.hostKeyFingerprint` (nil = first use).
    public let pinnedFingerprint: String?
    /// Called for `firstUse`/`changed`; `true` = trust this key now.
    /// Set BEFORE the connection attempt; mutated afterwards is not supported.
    public nonisolated(unsafe) var decisionHandler: (@Sendable (HostKeyEvent) async -> Bool)?

    public init(pinnedFingerprint: String?, decisionHandler: (@Sendable (HostKeyEvent) async -> Bool)? = nil) {
        self.pinnedFingerprint = pinnedFingerprint
        self.decisionHandler = decisionHandler
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = HostKeyFingerprint.compute(hostKey)
        if fingerprint == pinnedFingerprint {
            validationCompletePromise.succeed(())
            return
        }
        let event: HostKeyEvent
        if let pinned = pinnedFingerprint {
            event = .changed(pinned: pinned, presented: fingerprint)
        } else {
            event = .firstUse(fingerprint: fingerprint)
        }
        guard let handler = decisionHandler else {
            // Fail-closed: no UI attached (headless/tests) → decline.
            validationCompletePromise.fail(HostKeyRejectedError())
            return
        }
        Task {
            if await handler(event) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejectedError())
            }
        }
    }
}
