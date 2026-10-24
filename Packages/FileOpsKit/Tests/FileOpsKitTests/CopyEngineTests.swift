// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import FileOpsKit

// T-10: copy engine — the docs/SDD/08 §8.3 same-volume matrix (APFS clonefile
// branch + fcopyfile branch + VFS-generic stream), tree planning, conflict
// policies, pause/cancel, progress events, failure injection. Helpers are
// private and name-spaced (the module compiles files together).

@MainActor
private func foWaitFor(
    deadline interval: Double = 5,
    stepNanoseconds: UInt64 = 2_000_000,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        if condition() { return true }
        _ = try? await Task.sleep(nanoseconds: stepNanoseconds)
    }
    return condition()
}

/// Lock-protected event collector for pump tasks (Swift 6: mutable captures
/// across @Sendable closures are forbidden).
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sawProgress = false
    private var sawPaused = false
    private var sawResumed = false
    private var summary: Summary?
    private var failureTexts: [String] = []

    func record(_ event: TransferEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event.phase {
        case .itemProgress: sawProgress = true
        case .paused: sawPaused = true
        case .resumed: sawResumed = true
        case .itemFailed(let error): failureTexts.append(error.errorDescription ?? "\(error)")
        case .finished(let result): summary = result
        default: break
        }
    }

    func hasProgress() -> Bool { lock.lock(); defer { lock.unlock() }; return sawProgress }
    func hasPaused() -> Bool { lock.lock(); defer { lock.unlock() }; return sawPaused }
    func hasResumed() -> Bool { lock.lock(); defer { lock.unlock() }; return sawResumed }
    func finalSummary() -> Summary? { lock.lock(); defer { lock.unlock() }; return summary }
    func recordedFailures() -> [String] { lock.lock(); defer { lock.unlock() }; return failureTexts }
}

/// InMemoryVFS with a throttled read stream — makes pause/cancel observable
/// (the plain fake copies instantly, leaving no window to interrupt).
private final class ThrottledVFS: VFS, @unchecked Sendable {
    let inner: InMemoryVFS
    let throttleNanoseconds: UInt64

    var id: VFSInstanceID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    init(inner: InMemoryVFS, throttleMilliseconds: UInt64) {
        self.inner = inner
        self.throttleNanoseconds = throttleMilliseconds * 1_000_000
    }

    func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        try await inner.listDirectory(at: path)
    }

    func metadata(of path: VFSPath) async throws -> VFSItem {
        try await inner.metadata(of: path)
    }

    func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
        try await inner.directorySize(of: path, progress: progress)
    }

    func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        try await inner.createDirectory(name, in: parent)
    }

    func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        try await inner.rename(path, to: name)
    }

    func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        try await inner.delete(paths, toTrash: toTrash)
    }

    func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        try await inner.openWrite(path, replace: replace)
    }

    func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        try await inner.setAttributes(path, mutate: mutate)
    }

    func openRead(_ path: VFSPath) async throws -> any ByteStream {
        let stream = try await inner.openRead(path)
        return ThrottledStream(inner: stream, delay: throttleNanoseconds)
    }

    private struct ThrottledStream: ByteStream {
        let inner: any ByteStream
        let delay: UInt64

        var length: Int64 { get async throws { try await inner.length } }

        func readChunk(max: Int) async throws -> Data? {
            try await Task.sleep(nanoseconds: delay)
            return try await inner.readChunk(max: max)
        }
    }
}

    /// InMemoryVFS that fails `openWrite` for selected paths — per-item error
    /// injection (InMemoryVFS.injectFailure is operation-wide).
    private final class SelectiveFailVFS: VFS, @unchecked Sendable {
        let inner: InMemoryVFS
        let failingPaths: Set<VFSPath>

        var id: VFSInstanceID { inner.id }
        var capabilities: VFSCapabilities { inner.capabilities }

        init(inner: InMemoryVFS, failingPaths: Set<VFSPath>) {
            self.inner = inner
            self.failingPaths = failingPaths
        }

        func listDirectory(at path: VFSPath) async throws -> [VFSItem] { try await inner.listDirectory(at: path) }
        func metadata(of path: VFSPath) async throws -> VFSItem { try await inner.metadata(of: path) }
        func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 {
            try await inner.directorySize(of: path, progress: progress)
        }
        func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
            try await inner.createDirectory(name, in: parent)
        }
        func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
            try await inner.rename(path, to: name)
        }
        func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
            try await inner.delete(paths, toTrash: toTrash)
        }
        func openRead(_ path: VFSPath) async throws -> any ByteStream { try await inner.openRead(path) }
        func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
            try await inner.setAttributes(path, mutate: mutate)
        }

        func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
            if failingPaths.contains(path) {
                throw MCError.vfsAccessDenied(path, underlying: nil)
            }
            return try await inner.openWrite(path, replace: replace)
        }
    }

/// Test scaffolding: source and destination fakes + a file writer helper.
private struct Fixture {
    let source: InMemoryVFS
    let destination: InMemoryVFS
    let executor: OperationExecutor
    let journal: JournalStorage

    init(throttleMilliseconds: UInt64 = 0) {
        source = InMemoryVFS(name: "src")
        destination = InMemoryVFS(name: "dst")
        journal = JournalStorage()
        if throttleMilliseconds > 0 {
            executor = OperationExecutor(
                source: ThrottledVFS(inner: source, throttleMilliseconds: throttleMilliseconds),
                destination: destination,
                journal: journal
            )
        } else {
            executor = OperationExecutor(source: source, destination: destination, journal: journal)
        }
    }

    func putFile(_ name: String, in dir: VFSPath, bytes: Data, at sourceVFS: InMemoryVFS? = nil) async throws -> VFSPath {
        let vfs = sourceVFS ?? source
        let path = dir.appending(component: name)
        let writer = try await vfs.openWrite(path, replace: true)
        try await writer.write(bytes)
        try await writer.finish(committingTo: path)
        return path
    }

    func readAll(_ path: VFSPath, from vfs: InMemoryVFS? = nil) async throws -> Data {
        let target = vfs ?? destination
        let reader = try await target.openRead(path)
        var data = Data()
        while let chunk = try await reader.readChunk(max: 1 << 20) {
            data.append(chunk)
        }
        return data
    }

    func names(in dir: VFSPath, from vfs: InMemoryVFS? = nil) async throws -> [String] {
        let target = vfs ?? destination
        return try await target.listDirectory(at: dir).map(\.name).sorted()
    }
}

@Test func sameVolumeAPFSCloneBranchProducesSeparateInodeWithSameContent() async throws {
    // Real local filesystem: the temp dir lives on APFS, so `.auto` takes the
    // clonefile branch (docs/SDD/08 §8.3: «ctime/размер и inode разные»).
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MCFOClone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let vfs = LocalVFS(at: rootURL)
    let payload = Data("clone me — CoW must not duplicate bytes".utf8)
    let sourcePath = VFSPath(root: vfs.id, components: ["origin.txt"], displayURL: rootURL.appendingPathComponent("origin.txt"))
    let writer = try await vfs.openWrite(sourcePath, replace: true)
    try await writer.write(payload)
    try await writer.finish(committingTo: sourcePath)

    // The auto transport on this machine must be the APFS branch.
    #expect(CopyTransaction.autoTransportKind(sourceURL: rootURL) == "clonefile")

    let targetDir = VFSPath(root: vfs.id, components: ["dest"], displayURL: rootURL.appendingPathComponent("dest"))
    _ = try await vfs.createDirectory("dest", in: VFSPath(root: vfs.id))
    let plan = try await TransferPlanner.planCopy(sources: [sourcePath], into: targetDir, source: vfs, destination: vfs)
    #expect(plan.items.count == 1)

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
    let (id, events) = await executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite))
    _ = id
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)

    let targetURL = rootURL.appendingPathComponent("dest/origin.txt")
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourcePath.displayURL!.path)
    let targetAttributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
    #expect(sourceAttributes[.size] as? Int == payload.count)
    #expect(targetAttributes[.size] as? Int == payload.count)
    // CoW: the clone is a separate inode (a hardlink would share it).
    #expect(sourceAttributes[.systemFileNumber] as? UInt64 != targetAttributes[.systemFileNumber] as? UInt64)
    #expect(try Data(contentsOf: targetURL) == payload)
}

@Test func fcopyfileBranchCopiesByteWise() async throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MCFOFcopy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let vfs = LocalVFS(at: rootURL)
    let payload = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
    let sourcePath = VFSPath(root: vfs.id, components: ["binary.bin"], displayURL: rootURL.appendingPathComponent("binary.bin"))
    let writer = try await vfs.openWrite(sourcePath, replace: true)
    try await writer.write(payload)
    try await writer.finish(committingTo: sourcePath)

    let targetDir = VFSPath(root: vfs.id, components: ["out"], displayURL: rootURL.appendingPathComponent("out"))
    _ = try await vfs.createDirectory("out", in: VFSPath(root: vfs.id))
    let plan = try await TransferPlanner.planCopy(sources: [sourcePath], into: targetDir, source: vfs, destination: vfs)

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal, transportPreference: .forceFCopyFile)
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite))
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(try Data(contentsOf: rootURL.appendingPathComponent("out/binary.bin")) == payload)
}

@Test func byteStreamBranchCopiesAcrossInMemoryInstances() async throws {
    let fixture = Fixture()
    let sourceDir = VFSPath(root: fixture.source.id)
    _ = try await fixture.putFile("a.txt", in: sourceDir, bytes: Data("hello".utf8))
    let target = VFSPath(root: fixture.destination.id, components: ["inbox"])
    _ = try await fixture.destination.createDirectory("inbox", in: VFSPath(root: fixture.destination.id))

    let plan = try await TransferPlanner.planCopy(sources: [sourceDir.appending(component: "a.txt")], into: target, source: fixture.source, destination: fixture.destination)
    let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(try await fixture.readAll(target.appending(component: "a.txt")) == Data("hello".utf8))
}

@Test func treeExpansionFlattensNestedStructure() async throws {
    let fixture = Fixture()
    let root = VFSPath(root: fixture.source.id)
    let src = try await fixture.source.createDirectory("src", in: root)
    _ = try await fixture.putFile("a.txt", in: src, bytes: Data("1".utf8))
    let sub = try await fixture.source.createDirectory("sub", in: src)
    _ = try await fixture.putFile("deep.txt", in: sub, bytes: Data("22".utf8))

    let destinationRoot = VFSPath(root: fixture.destination.id)
    let plan = try await TransferPlanner.planCopy(sources: [src], into: destinationRoot, source: fixture.source, destination: fixture.destination)
    // src dir + a.txt + sub dir + deep.txt
    #expect(plan.items.count == 4)
    #expect(plan.items.contains { $0.target.components == ["src"] })
    #expect(plan.items.contains { $0.target.components == ["src", "sub", "deep.txt"] })

    let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())
    let collector = EventCollector()
    let pump = Task.detached {
        for await event in events {
            collector.record(event)
        }
    }
    #expect(await foWaitFor { collector.finalSummary() != nil })
    pump.cancel()
    let summary = collector.finalSummary()
    #expect(collector.recordedFailures().isEmpty)
    #expect(summary?.succeededItems == 4)
    #expect(try await fixture.names(in: destinationRoot) == ["src"])
    #expect(try await fixture.readAll(VFSPath(root: fixture.destination.id, components: ["src", "sub", "deep.txt"])) == Data("22".utf8))
}

@Test func conflictPoliciesOverwriteSkipKeepBothAndApplyToAll() async throws {
    let fixture = Fixture()
    let sourceDir = VFSPath(root: fixture.source.id)
    let target = VFSPath(root: fixture.destination.id, components: ["box"])
    _ = try await fixture.destination.createDirectory("box", in: VFSPath(root: fixture.destination.id))
    _ = try await fixture.putFile("same.txt", in: target, bytes: Data("old".utf8), at: fixture.destination)

    // Two sources: same.txt (conflicts) and new.txt (no conflict).
    _ = try await fixture.putFile("same.txt", in: sourceDir, bytes: Data("new".utf8))
    _ = try await fixture.putFile("new.txt", in: sourceDir, bytes: Data("n".utf8))
    let plan = try await TransferPlanner.planCopy(
        sources: [sourceDir.appending(component: "same.txt"), sourceDir.appending(component: "new.txt")],
        into: target,
        source: fixture.source,
        destination: fixture.destination
    )
    #expect(plan.conflicts.count == 1)

    // Overwrite replaces the content.
    do {
        let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite))
        for await _ in events {}
        #expect(try await fixture.readAll(target.appending(component: "same.txt")) == Data("new".utf8))
        #expect(try await fixture.names(in: target) == ["new.txt", "same.txt"])
    }

    // Re-conflict now (same.txt exists again): skip keeps the target content.
    // Note: the runtime re-check also sees new.txt now — both are skipped.
    do {
        let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .skip))
        for await _ in events {}
        #expect(try await fixture.readAll(target.appending(component: "same.txt")) == Data("new".utf8))
    }

    // keepBoth: auto-suffix «name(1).ext» (08 §8.3) for every existing target.
    do {
        let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .keepBoth))
        for await _ in events {}
        #expect(try await fixture.names(in: target) == ["new(1).txt", "new.txt", "same(1).txt", "same.txt"])
    }

    // applyToAll(skip) behaves like skip for every conflict — no new suffix.
    do {
        let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .applyToAll(.skip)))
        for await _ in events {}
        #expect(try await fixture.names(in: target) == ["new(1).txt", "new.txt", "same(1).txt", "same.txt"])
        #expect(try await fixture.readAll(target.appending(component: "same.txt")) == Data("new".utf8))
    }
}

@Test func uniqueTargetNameSuffSequentialSuffixes() async throws {
    let fixture = Fixture()
    let target = VFSPath(root: fixture.destination.id, components: ["box"])
    _ = try await fixture.destination.createDirectory("box", in: VFSPath(root: fixture.destination.id))
    _ = try await fixture.putFile("a.txt", in: target, bytes: Data("x".utf8), at: fixture.destination)

    let first = await TransferPlanner.uniqueTargetName(for: target.appending(component: "a.txt"), in: fixture.destination)
    #expect(first.components.last == "a(1).txt")
    _ = try await fixture.putFile("a(1).txt", in: target, bytes: Data("x".utf8), at: fixture.destination)
    let second = await TransferPlanner.uniqueTargetName(for: target.appending(component: "a.txt"), in: fixture.destination)
    #expect(second.components.last == "a(2).txt")
}

@Test func copyIntoOwnSubtreeIsRefused() async throws {
    let fixture = Fixture()
    let root = VFSPath(root: fixture.source.id)
    let src = try await fixture.source.createDirectory("src", in: root)
    _ = try await fixture.putFile("a.txt", in: src, bytes: Data("1".utf8))

    // Copy src into src/inner — the planner refuses the source.
    _ = try await fixture.source.createDirectory("inner", in: src)
    let plan = try await TransferPlanner.planCopy(sources: [src], into: src.appending(component: "inner"), source: fixture.source, destination: fixture.source)
    #expect(plan.items.isEmpty)
    #expect(plan.conflicts.count == 1)
    guard case .insideSelfMove = plan.conflicts[0].kind else {
        Issue.record("expected insideSelfMove, got \(plan.conflicts[0].kind)")
        return
    }
}

@Test func cancelMidCopyLeavesNoTargetFile() async throws {
    let fixture = Fixture(throttleMilliseconds: 40)
    let sourceDir = VFSPath(root: fixture.source.id)
    // ~16 MB → ~640 ms with 1 MB chunks at 40 ms throttle; cancel well before.
    let payload = Data(repeating: 0xAB, count: 16 << 20)
    _ = try await fixture.putFile("big.bin", in: sourceDir, bytes: payload)
    let target = VFSPath(root: fixture.destination.id, components: ["inbox"])
    _ = try await fixture.destination.createDirectory("inbox", in: VFSPath(root: fixture.destination.id))

    let plan = try await TransferPlanner.planCopy(sources: [sourceDir.appending(component: "big.bin")], into: target, source: fixture.source, destination: fixture.destination)
    let (id, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())

    let collector = EventCollector()
    let pump = Task.detached {
        for await event in events {
            collector.record(event)
        }
    }
    // Time-based mid-copy cancel: the copy needs ~640 ms (16 chunks × 40 ms),
    // so the cancel at 120 ms lands strictly inside the copy — independent of
    // event-pump scheduling under parallel test load.
    try await Task.sleep(nanoseconds: 120_000_000)
    await fixture.executor.cancel(id)
    #expect(await foWaitFor { collector.finalSummary() != nil })
    pump.cancel()

    let summary = collector.finalSummary()
    #expect(summary?.canceled == true)
    #expect(summary?.failedItems == 1)   // the interrupted item
    // 08 §8.3: cancel on 99 % must not leave a target file.
    let names = try await fixture.names(in: target)
    #expect(names.isEmpty)
}

@Test func pauseStallsAndResumeCompletes() async throws {
    let fixture = Fixture(throttleMilliseconds: 25)
    let sourceDir = VFSPath(root: fixture.source.id)
    let payload = Data(repeating: 0x5A, count: 20 << 20)
    _ = try await fixture.putFile("medium.bin", in: sourceDir, bytes: payload)
    let target = VFSPath(root: fixture.destination.id, components: ["inbox"])
    _ = try await fixture.destination.createDirectory("inbox", in: VFSPath(root: fixture.destination.id))

    let plan = try await TransferPlanner.planCopy(sources: [sourceDir.appending(component: "medium.bin")], into: target, source: fixture.source, destination: fixture.destination)
    let (id, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())

    let collector = EventCollector()
    let pump = Task.detached {
        for await event in events {
            collector.record(event)
        }
    }
    // Time-based pause: mid-copy at 120 ms (copy needs ~500 ms), then prove
    // the stall (no «finished» within the remaining window), then resume.
    try await Task.sleep(nanoseconds: 120_000_000)
    await fixture.executor.pause(id)
    try await Task.sleep(nanoseconds: 450_000_000)
    #expect(collector.finalSummary() == nil)   // stalled (unpaced copy = ~500 ms)

    await fixture.executor.resume(id)
    #expect(await foWaitFor { collector.finalSummary() != nil })
    #expect(await foWaitFor { collector.hasPaused() })
    #expect(await foWaitFor { collector.hasResumed() })
    pump.cancel()

    let summary = collector.finalSummary()
    #expect(summary?.canceled == false)
    #expect(summary?.succeededItems == 1)
    #expect(try await fixture.names(in: target) == ["medium.bin"])
}

@Test func failureInjectionSurfacesItemFailedAndContinues() async throws {
    let source = InMemoryVFS(name: "src")
    let destinationInner = InMemoryVFS(name: "dst")
    let sourceDir = VFSPath(root: source.id)
    _ = try await put(source, sourceDir, "good.txt", Data("g".utf8))
    _ = try await put(source, sourceDir, "bad.txt", Data("b".utf8))
    let target = VFSPath(root: destinationInner.id, components: ["inbox"])
    _ = try await destinationInner.createDirectory("inbox", in: VFSPath(root: destinationInner.id))

    // The destination refuses openWrite for exactly one item (per-path
    // errno-инъекция; InMemoryVFS.injectFailure is operation-wide).
    let destination = SelectiveFailVFS(inner: destinationInner, failingPaths: [target.appending(component: "bad.txt")])
    let journal = JournalStorage()
    let executor = OperationExecutor(source: source, destination: destination, journal: journal)

    let plan = try await TransferPlanner.planCopy(
        sources: [sourceDir.appending(component: "good.txt"), sourceDir.appending(component: "bad.txt")],
        into: target,
        source: source,
        destination: destination
    )
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var failures = 0
    var summary: Summary?
    for await event in events {
        switch event.phase {
        case .itemFailed: failures += 1
        case .finished(let result): summary = result
        default: break
        }
    }
    #expect(failures == 1)
    #expect(summary?.succeededItems == 1)
    #expect(summary?.failedItems == 1)
    #expect(try await destinationInner.listDirectory(at: target).map(\.name).sorted() == ["good.txt"])
}

/// Writes a file through the VFS staged writer (test helper).
private func put(_ vfs: InMemoryVFS, _ dir: VFSPath, _ name: String, _ bytes: Data) async throws -> VFSPath {
    let path = dir.appending(component: name)
    let writer = try await vfs.openWrite(path, replace: true)
    try await writer.write(bytes)
    try await writer.finish(committingTo: path)
    return path
}

@Test func progressEventsReportAggregatedBytes() async throws {
    let fixture = Fixture()
    let sourceDir = VFSPath(root: fixture.source.id)
    _ = try await fixture.putFile("one.bin", in: sourceDir, bytes: Data(repeating: 1, count: 2 << 20))
    _ = try await fixture.putFile("two.bin", in: sourceDir, bytes: Data(repeating: 2, count: 1 << 20))
    let target = VFSPath(root: fixture.destination.id, components: ["inbox"])
    _ = try await fixture.destination.createDirectory("inbox", in: VFSPath(root: fixture.destination.id))

    let plan = try await TransferPlanner.planCopy(
        sources: [sourceDir.appending(component: "one.bin"), sourceDir.appending(component: "two.bin")],
        into: target,
        source: fixture.source,
        destination: fixture.destination
    )
    let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())

    var started = false
    var progressEvents = 0
    var doneEvents = 0
    var lastCompleted: Int64 = 0
    var summary: Summary?
    for await event in events {
        switch event.phase {
        case .started: started = true
        case .itemProgress: progressEvents += 1
        case .itemDone: doneEvents += 1
        case .finished(let result): summary = result
        default: break
        }
        lastCompleted = event.completedBytes
    }
    #expect(started)
    #expect(progressEvents > 0)
    #expect(doneEvents == 2)
    #expect(lastCompleted == 3 << 20)   // aggregated completed bytes (§5.6)
    #expect(summary?.bytesTransferred == 3 << 20)
    #expect(summary?.succeededItems == 2)
}

@Test func journalRecordsEveryCommittedCopyAndRingsAtTwenty() async throws {
    let journal = JournalStorage(capacity: 20)
    for index in 0 ..< 25 {
        journal.append(JournalRecord(
            timestamp: Date(),
            op: .copy,
            reversals: [.deleteCreated(path: VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"), components: ["f\(index)"]))]
        ))
    }
    let recent = journal.recent()
    #expect(recent.count == 20)
    #expect(recent.first?.reversals.first == Reversal.deleteCreated(
        path: VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"), components: ["f5"])
    ))
    #expect(recent.last?.reversals.first == Reversal.deleteCreated(
        path: VFSPath(root: VFSInstanceID(kind: .localDisk, specID: "/"), components: ["f24"])
    ))
    journal.clear()
    #expect(journal.recent().isEmpty)
}

@Test func successfulCopyWritesJournalReversal() async throws {
    let fixture = Fixture()
    let sourceDir = VFSPath(root: fixture.source.id)
    _ = try await fixture.putFile("j.txt", in: sourceDir, bytes: Data("j".utf8))
    let target = VFSPath(root: fixture.destination.id, components: ["inbox"])
    _ = try await fixture.destination.createDirectory("inbox", in: VFSPath(root: fixture.destination.id))

    let plan = try await TransferPlanner.planCopy(sources: [sourceDir.appending(component: "j.txt")], into: target, source: fixture.source, destination: fixture.destination)
    let (_, events) = await fixture.executor.enqueue(plan, policy: ConflictPolicy())
    for await _ in events {}

    let records = fixture.journal.recent()
    #expect(records.count == 1)
    #expect(records[0].op == .copy)
    #expect(records[0].reversals.first == Reversal.deleteCreated(path: target.appending(component: "j.txt")))
}
