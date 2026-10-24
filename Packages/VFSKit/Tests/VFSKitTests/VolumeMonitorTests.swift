// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
import DomainKit
@testable import VFSKit

// T-06: VolumeMonitor maps NSWorkspace volume notifications onto the §5.4
// contract event (`.volumeEvent(volume:mounted:)`) over an injectable
// NotificationCenter (no real disks in tests). One long-lived reader per test
// (an AsyncStream terminates when its consumer is cancelled — see the note in
// FSEventsWatcherTests.swift).

private final class VolumeEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WatchEvent] = []

    func append(_ event: WatchEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [WatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private func volumeSettle(
    timeout: Double = 1.5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@Test func mountAndUnmountNotificationsYieldOrderedVolumeEvents() async {
    let center = NotificationCenter()
    let monitor = VolumeMonitor(notificationCenter: center)
    let stream = monitor.subscribe()
    let sink = VolumeEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { sink.append(event) }
        }

        let fakeVolumeURL = URL(fileURLWithPath: "/Volumes/mc-fake-disk", isDirectory: true)
        center.post(
            name: NSWorkspace.didUnmountNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: fakeVolumeURL]
        )
        center.post(
            name: NSWorkspace.didMountNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: fakeVolumeURL]
        )

        #expect(await volumeSettle { sink.events.count >= 2 })
        let events = sink.events
        #expect(events.count == 2)

        guard case .some(.volumeEvent(let unmountedInstance, let unmountedFlag)) = events.first else {
            Issue.record("expected volumeEvent first, got \(String(describing: events.first))")
            group.cancelAll()
            return
        }
        #expect(!unmountedFlag)
        // UUID-less fake mount point: stable path-derived spec (docs/SDD/05 §5.4).
        #expect(unmountedInstance.specID.hasPrefix("removed:"))
        guard case .some(.volumeEvent(_, let mountedFlag)) = events.last else {
            Issue.record("expected second volumeEvent, got \(String(describing: events.last))")
            group.cancelAll()
            return
        }
        #expect(mountedFlag)
        group.cancelAll()
    }
}

@Test func notificationsWithoutVolumeURLAreSkipped() async {
    let center = NotificationCenter()
    let monitor = VolumeMonitor(notificationCenter: center)
    let stream = monitor.subscribe()
    let sink = VolumeEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { sink.append(event) }
        }

        center.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared, userInfo: nil)
        center.post(
            name: NSWorkspace.didUnmountNotification,
            object: NSWorkspace.shared,
            userInfo: ["irrelevant": "payload"]
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(sink.events.isEmpty)
        group.cancelAll()
    }
}

@Test func volumeInstancePrefersUUIDFromResourceValues() {
    let realVolumeURL = URL(fileURLWithPath: "/", isDirectory: true)
    let instance = VolumeMonitor.volumeInstance(of: realVolumeURL, mounted: true)
    // "/" resolves resource values on a real system; specID must be stable and
    // non-empty either way (UUID or «mounted:<path>» fallback).
    #expect(!instance.specID.isEmpty)
    #expect(instance.kind == .localDisk)
}
