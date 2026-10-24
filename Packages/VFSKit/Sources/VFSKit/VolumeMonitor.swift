// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation

// Contract: docs/SDD/05-DataModel-VFS.md §5.4 (`.volumeEvent`) and T-06
// (docs/SDD/12). Fan-out of NSWorkspace volume notifications onto a single
// `AsyncStream<WatchEvent>`. Owned by the App assembly; panels translate
// unmount events into a reload (surface errors through the status line) using
// their own view of mounted instances.

/// Bridges NSWorkspace mount/unmount notifications onto the §5.4 contract.
/// The notification center is injectable so tests can post synthetic
/// notifications without real disks. Observation stops when the consumer stops
/// iterating (stream termination removes both observers).
public final class VolumeMonitor: @unchecked Sendable {
    private let notificationCenter: NotificationCenter

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    /// Streams mount/unmount events. The stream stays open until the consumer
    /// breaks out of iteration (`onTermination` removes the NSWorkspace
    /// observers) or the monitor deallocates.
    public func subscribe() -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            let center = notificationCenter
            let mountObserver = center.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let event = VolumeMonitor.event(for: notification, mounted: true) else { return }
                continuation.yield(event)
            }
            let unmountObserver = center.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: nil
            ) { notification in
                guard let event = VolumeMonitor.event(for: notification, mounted: false) else { return }
                continuation.yield(event)
            }
            let tokens = ObserverTokens(mount: mountObserver, unmount: unmountObserver)
            continuation.onTermination = { _ in
                center.removeObserver(tokens.mount)
                center.removeObserver(tokens.unmount)
            }
        }
    }

    /// Sendable holder for the two NSWorkspace observer tokens; token removal
    /// (`NotificationCenter.removeObserver`) is thread-safe. Needed because
    /// `onTermination` is a `@Sendable` closure.
    private final class ObserverTokens: @unchecked Sendable {
        let mount: any NSObjectProtocol
        let unmount: any NSObjectProtocol

        init(mount: any NSObjectProtocol, unmount: any NSObjectProtocol) {
            self.mount = mount
            self.unmount = unmount
        }
    }

    /// Notification → contract event.
    static func event(for notification: Notification, mounted: Bool) -> WatchEvent? {
        guard let mountURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return nil
        }
        return .volumeEvent(volume: volumeInstance(of: mountURL, mounted: mounted), mounted: mounted)
    }

    /// Volume identity of a mount point: UUID string where the OS reports one
    /// (the same value `LocalVFS` derives for its instance), otherwise a stable
    /// path-derived spec so events for UUID-less network volumes still match.
    static func volumeInstance(of mountURL: URL, mounted: Bool) -> VFSInstanceID {
        let values = try? mountURL.resourceValues(forKeys: [.volumeUUIDStringKey])
        let specID = values?.volumeUUIDString ?? "\(mounted ? "mounted" : "removed"):\(mountURL.path)"
        return VFSInstanceID(kind: .localDisk, credentialRef: nil, specID: specID)
    }
}
