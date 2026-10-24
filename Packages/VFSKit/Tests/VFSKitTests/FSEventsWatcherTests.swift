// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import VFSKit

// T-06: FSEventsWatcher against the real file system (docs/SDD/06 §6.3):
// external changes surface as `itemsChanged` diffs within the F-1 budget
// (≤ 1 s of reflection, ≤ 3 s CI budget), coalescing collapses storms,
// self-suppression silences own writes until cleared, and fan-out serves
// multiple consumers from one physical FSEventStream.
//
// IMPORTANT testing pattern: an AsyncStream TERMINATES when its consumer is
// cancelled (contract §5.4 semantics). So every test owns ONE long-lived
// reader task accumulating into a sink, cancelled only at the end — waiting
// helpers poll the sink instead of racing the reader. Helpers are private —
// the test module compiles its files together.

private final class WatchEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WatchEvent] = []

    func append(_ event: WatchEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var itemsChangedDiffs: [DirectoryDiff] {
        lock.lock()
        defer { lock.unlock() }
        return items.compactMap { event in
            if case .itemsChanged(let diff) = event { return diff }
            return nil
        }
    }
}

/// Polls `condition` until true or timeout (the reader task keeps running).
private func watcherSettle(
    timeout: Double = 3.0,
    stepMilliseconds: UInt64 = 20,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: stepMilliseconds * 1_000_000)
    }
    return await condition()
}

private func watcherTempDir(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("mc-fsw-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func watchPath(of vfs: LocalVFS, url: URL) -> VFSPath {
    VFSPath(root: vfs.id, components: [], displayURL: url)
}

private func writeWatcherFile(_ url: URL, named name: String) throws {
    try Data("watch".utf8).write(to: url.appendingPathComponent(name))
}

@Test func externalFileCreateSurfacesAsItemsChangedWithinThreeSeconds() async throws {
    let dir = watcherTempDir("edit")
    defer { try? FileManager.default.removeItem(at: dir) }
    let vfs = LocalVFS(at: dir, instanceID: VFSInstanceID(kind: .localDisk, specID: "fsw-test"))
    let watcher = FSEventsWatcher(vfs: vfs)
    let stream = watcher.watch(watchPath(of: vfs, url: dir), options: WatchOptions(coalescingMilliseconds: 80))
    let sink = WatchEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { sink.append(event) }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)   // FSEventStream start grace
        try? writeWatcherFile(dir, named: "fresh.txt")

        #expect(await watcherSettle { !sink.itemsChangedDiffs.isEmpty })
        #expect(sink.itemsChangedDiffs.last?.added.contains { $0.name == "fresh.txt" } == true)
        group.cancelAll()
    }
}

@Test func coalescingCollapsesRapidWritesIntoFewEvents() async throws {
    let dir = watcherTempDir("coalesce")
    defer { try? FileManager.default.removeItem(at: dir) }
    let vfs = LocalVFS(at: dir, instanceID: VFSInstanceID(kind: .localDisk, specID: "fsw-test"))
    let watcher = FSEventsWatcher(vfs: vfs)
    let stream = watcher.watch(watchPath(of: vfs, url: dir), options: WatchOptions(coalescingMilliseconds: 300))
    let sink = WatchEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { sink.append(event) }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        for index in 0 ..< 4 {
            try? writeWatcherFile(dir, named: "storm-\(index).txt")
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        #expect(await watcherSettle { !sink.itemsChangedDiffs.isEmpty })
        // Drain window beyond the last possible diff emission: four writes
        // ~60 ms apart inside one 300 ms coalescing window must yield ≤ 2.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(sink.itemsChangedDiffs.count <= 2, "got \(sink.itemsChangedDiffs.count) events")
        group.cancelAll()
    }
}

@Test func suppressionSilencesOwnWritesUntilCleared() async throws {
    let dir = watcherTempDir("suppress")
    defer { try? FileManager.default.removeItem(at: dir) }
    let vfs = LocalVFS(at: dir, instanceID: VFSInstanceID(kind: .localDisk, specID: "fsw-test"))
    let path = watchPath(of: vfs, url: dir)
    let watcher = FSEventsWatcher(vfs: vfs)
    let stream = watcher.watch(path, options: WatchOptions(coalescingMilliseconds: 80))
    let sink = WatchEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream { sink.append(event) }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        watcher.suppress([path], until: Date().addingTimeInterval(0.8))
        try? writeWatcherFile(dir, named: "selfwrite.txt")

        // Past the suppression deadline + FSEvents latency: still silent.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(sink.itemsChangedDiffs.isEmpty, "suppressed write leaked: \(sink.itemsChangedDiffs)")

        watcher.clearSuppression([path])
        try? writeWatcherFile(dir, named: "external.txt")
        #expect(await watcherSettle { !sink.itemsChangedDiffs.isEmpty })
        #expect(sink.itemsChangedDiffs.last?.added.contains { $0.name == "external.txt" } == true)
        group.cancelAll()
    }
}

@Test func twoSubscribersOnOneDirectoryFanOutTheSameEvent() async throws {
    let dir = watcherTempDir("fanout")
    defer { try? FileManager.default.removeItem(at: dir) }
    let vfs = LocalVFS(at: dir, instanceID: VFSInstanceID(kind: .localDisk, specID: "fsw-test"))
    let watcher = FSEventsWatcher(vfs: vfs)
    let streamA = watcher.watch(watchPath(of: vfs, url: dir), options: WatchOptions(coalescingMilliseconds: 80))
    let streamB = watcher.watch(watchPath(of: vfs, url: dir), options: WatchOptions(coalescingMilliseconds: 80))
    let sinkA = WatchEventSink()
    let sinkB = WatchEventSink()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in streamA { sinkA.append(event) }
        }
        group.addTask {
            for await event in streamB { sinkB.append(event) }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        try? writeWatcherFile(dir, named: "shared.txt")

        #expect(await watcherSettle { !sinkA.itemsChangedDiffs.isEmpty })
        #expect(await watcherSettle { !sinkB.itemsChangedDiffs.isEmpty })
        #expect(sinkA.itemsChangedDiffs.last?.added.contains { $0.name == "shared.txt" } == true)
        #expect(sinkB.itemsChangedDiffs.last?.added.contains { $0.name == "shared.txt" } == true)
        group.cancelAll()
    }
}

@Test func pathWithoutDisplayURLYieldsFinishedStream() async {
    let watcher = FSEventsWatcher(vfs: InMemoryVFS())
    let virtualPath = VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "virtual"))
    let stream = watcher.watch(virtualPath, options: WatchOptions())

    // §5.4: non-watchable VFS returns an empty (finished) stream.
    let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream {}
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    #expect(finished)
}
