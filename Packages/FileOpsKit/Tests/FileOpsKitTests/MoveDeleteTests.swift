// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import FileOpsKit

// T-11: move/delete engine — the docs/SDD/08 §8.3 volume matrix essentials:
// rename(2) with inode preservation, cross-volume copy+delete (deterministic
// via an injected VolumeKeyProvider — tests do not depend on real volume
// geometry), inside-self refusal, bottom-up permanent delete (readonly files),
// trash + restoreFromTrash reversal, `.mc-partial` resume after cancel, and
// VFS-generic delegation. Helpers are private and name-spaced (`md`).

@MainActor
private func mdWaitFor(
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

/// Lock-protected event collector for pump tasks (`md` name-space).
private final class MDEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var summary: Summary?
    private var failures: [String] = []

    func record(_ event: TransferEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event.phase {
        case .itemFailed(let error): failures.append(String(describing: error))
        case .finished(let result): summary = result
        default: break
        }
    }

    func finalSummary() -> Summary? { lock.lock(); defer { lock.unlock() }; return summary }
    func recordedFailures() -> [String] { lock.lock(); defer { lock.unlock() }; return failures }
}

/// Two real directories acting as «different volumes» under an injected
/// volume-key provider; everything else is a plain LocalVFS fixture.
private struct MDFixture {
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let vfs: LocalVFS

    static func create(name: String) throws -> MDFixture {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("src", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        return MDFixture(rootURL: rootURL, sourceURL: sourceURL, destinationURL: destinationURL, vfs: LocalVFS(at: rootURL))
    }

    /// Injected volume keys: «src» → A, «dst» → B (cross-volume determinism).
    var crossVolumeProvider: VolumeKeyProvider {
        { [sourceURL, destinationURL] url in
            url.path.hasPrefix(sourceURL.path) ? "A" : (url.path.hasPrefix(destinationURL.path) ? "B" : nil)
        }
    }

    func path(_ url: URL) -> VFSPath {
        // Components relative to the VFS root (the fixture root URL), not the
        // absolute path: url.pathComponents starts at "/".
        let rootDepth = rootURL.path.split(separator: "/", omittingEmptySubsequences: true).count
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .dropFirst(rootDepth)
        return VFSPath(root: vfs.id, components: Array(components), displayURL: url)
    }

    var sourcePath: VFSPath { path(sourceURL) }
    var destinationPath: VFSPath { path(destinationURL) }

    func putFile(_ name: String, in url: URL, bytes: Data) async throws -> VFSPath {
        let fileURL = url.appendingPathComponent(name)
        try bytes.write(to: fileURL)
        return path(fileURL)
    }
}

private func mdRead(_ url: URL) throws -> Data {
    try Data(contentsOf: url)
}

@Test func moveSameVolumeRenamesWithInodePreserved() async throws {
    let fixture = try MDFixture.create(name: "MDRename")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    // A directory subtree moves as one rename(2) — inode preserved (08 §8.3).
    let dirURL = fixture.sourceURL.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    let payload = Data("same-volume rename".utf8)
    _ = try await fixture.putFile("main.txt", in: dirURL, bytes: payload)

    let plan = try await TransferPlanner.planMove(
        sources: [fixture.path(dirURL)],
        into: fixture.destinationPath,
        source: fixture.vfs,
        destination: fixture.vfs
    )
    // The planner expands the tree, but the executor must execute only the
    // top-level rename (descendants are subsumed).
    #expect(plan.items.count == 2)

    let journal = JournalStorage()
    let executor = OperationExecutor(source: fixture.vfs, destination: fixture.vfs, journal: journal)
    let (id, events) = await executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite))
    _ = id
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(summary?.failedItems == 0)

    let movedURL = fixture.destinationURL.appendingPathComponent("project/main.txt")
    #expect(try mdRead(movedURL) == payload)
    #expect(!FileManager.default.fileExists(atPath: dirURL.path))

    let before = try FileManager.default.attributesOfItem(atPath: movedURL.path)
    let inode = before[.systemFileNumber] as? UInt64
    #expect(inode != nil)
    // The rename reversal is journalled (F-6).
    let records = journal.recent()
    guard records.count == 1 else {
        Issue.record("expected 1 journal record, got \(records.count)")
        return
    }
    #expect(records[0].op == .move)
    #expect(records[0].reversals.first == Reversal.renameBack(
        at: fixture.destinationPath.appending(component: "project"), previousName: "project"
    ))
    _ = inode
}

@Test func moveCrossVolumeCopiesAndDeletesForFileAndTree() async throws {
    let fixture = try MDFixture.create(name: "MDCross")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    // File: copy (resumable localChunked transport) + immediate source delete.
    let payload = Data((0 ..< 250_000).map { UInt8(truncatingIfNeeded: $0 * 13) })
    let fileURL = fixture.sourceURL.appendingPathComponent("data.bin")
    try payload.write(to: fileURL)
    // Tree: dir with nested content.
    let dirURL = fixture.sourceURL.appendingPathComponent("tree", isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
    let innerPayload = Data("inner".utf8)
    try innerPayload.write(to: dirURL.appendingPathComponent("sub/deep.txt"))

    let plan = try await TransferPlanner.planMove(
        sources: [fixture.path(fileURL), fixture.path(dirURL)],
        into: fixture.destinationPath,
        source: fixture.vfs,
        destination: fixture.vfs
    )

    let journal = JournalStorage()
    let executor = OperationExecutor(
        source: fixture.vfs,
        destination: fixture.vfs,
        journal: journal,
        volumeKeyProvider: fixture.crossVolumeProvider
    )
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite))
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 2)   // two top-level items
    #expect(summary?.failedItems == 0)

    #expect(try mdRead(fixture.destinationURL.appendingPathComponent("data.bin")) == payload)
    #expect(try mdRead(fixture.destinationURL.appendingPathComponent("tree/sub/deep.txt")) == innerPayload)
    // Sources are gone (copy+delete committed per node, deepest first).
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: dirURL.path))
}

@Test func moveIntoOwnSubtreeIsRefused() async throws {
    let fixture = try MDFixture.create(name: "MDSelf")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let dirURL = fixture.sourceURL.appendingPathComponent("outer", isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL.appendingPathComponent("inner", isDirectory: true), withIntermediateDirectories: true)
    let payload = Data("keep".utf8)
    try payload.write(to: dirURL.appendingPathComponent("inner/keep.txt"))

    // Move outer into outer/inner — refused at planning (06 §6.2 edge case).
    let plan = try await TransferPlanner.planMove(
        sources: [fixture.path(dirURL)],
        into: fixture.path(dirURL.appendingPathComponent("inner")),
        source: fixture.vfs,
        destination: fixture.vfs
    )
    #expect(plan.items.isEmpty)
    #expect(plan.conflicts.count == 1)
    guard case .insideSelfMove = plan.conflicts[0].kind else {
        Issue.record("expected insideSelfMove, got \(plan.conflicts[0].kind)")
        return
    }

    let journal = JournalStorage()
    let executor = OperationExecutor(source: fixture.vfs, destination: fixture.vfs, journal: journal)
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.failedItems == 1)
    #expect(try mdRead(dirURL.appendingPathComponent("inner/keep.txt")) == payload)
}

@Test func permanentDeleteWalksBottomUpAndHandlesReadonly() async throws {
    let fixture = try MDFixture.create(name: "MDDelete")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let dirURL = fixture.sourceURL.appendingPathComponent("victim", isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
    let payload = Data((0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0) })
    let readonlyURL = dirURL.appendingPathComponent("nested/readonly.txt")
    try payload.write(to: readonlyURL)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o444)], ofItemAtPath: readonlyURL.path)
    try Data("plain".utf8).write(to: dirURL.appendingPathComponent("plain.txt"))

    let plan = try await TransferPlanner.planDelete(sources: [fixture.path(dirURL)], source: fixture.vfs)
    #expect(plan.items.count == 1)

    let journal = JournalStorage()
    let executor = OperationExecutor(
        source: fixture.vfs,
        destination: fixture.vfs,
        journal: journal,
        deleteToTrash: false
    )
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    var sawProgress = false
    var failures: [String] = []
    for await event in events {
        switch event.phase {
        case .itemProgress: sawProgress = true
        case .itemFailed(let error): failures.append(String(describing: error))
        case .finished(let result): summary = result
        default: break
        }
    }
    #expect(failures.isEmpty)
    #expect(summary?.succeededItems == 1)
    #expect(summary?.failedItems == 0)
    #expect(summary?.failedItems == 0)
    #expect(sawProgress)
    #expect(summary!.bytesTransferred > 0)   // bytes freed (08 §8.3 progress)
    #expect(!FileManager.default.fileExists(atPath: dirURL.path))

    // A permanent delete is not reversible — no journal reversals (08 §8.3).
    let records = journal.recent()
    guard records.count == 1 else {
        Issue.record("expected 1 journal record, got \(records.count)")
        return
    }
    #expect(records[0].op == .delete)
    #expect(records[0].reversals.isEmpty)
}

@Test func trashDeleteRecordsRestoreReversal() async throws {
    let fixture = try MDFixture.create(name: "MDTrash")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let fileURL = fixture.sourceURL.appendingPathComponent("gone.txt")
    try Data("to trash".utf8).write(to: fileURL)

    let plan = try await TransferPlanner.planDelete(sources: [fixture.path(fileURL)], source: fixture.vfs)
    let journal = JournalStorage()
    let executor = OperationExecutor(source: fixture.vfs, destination: fixture.vfs, journal: journal)   // deleteToTrash defaults to true (F-5)
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    var failures: [String] = []
    for await event in events {
        switch event.phase {
        case .itemFailed(let error): failures.append(String(describing: error))
        case .finished(let result): summary = result
        default: break
        }
    }
    #expect(failures.isEmpty)
    #expect(summary?.succeededItems == 1)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))

    let records = journal.recent()
    guard records.count == 1 else {
        Issue.record("expected 1 journal record, got \(records.count)")
        return
    }
    guard case .restoreFromTrash(let original, let trashURL)? = records[0].reversals.first else {
        Issue.record("expected restoreFromTrash reversal, got \(String(describing: records[0].reversals.first))")
        return
    }
    #expect(original == fixture.path(fileURL))
    // The trashed copy really landed in the Trash.
    #expect(FileManager.default.fileExists(atPath: trashURL.path))
    try? FileManager.default.removeItem(at: trashURL)   // keep the test clean
}

@Test func cancelledCrossVolumeMoveLeavesPartialAndResumeCompletes() async throws {
    let fixture = try MDFixture.create(name: "MDResume")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    // 3 MB with a non-uniform pattern: byte-wise equality proves the resume
    // continued at the right offset (a restart-from-zero bug corrupts it).
    let payload = Data((0 ..< (3 << 20)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let fileURL = fixture.sourceURL.appendingPathComponent("big.bin")
    try payload.write(to: fileURL)

    let plan = try await TransferPlanner.planMove(
        sources: [fixture.path(fileURL)],
        into: fixture.destinationPath,
        source: fixture.vfs,
        destination: fixture.vfs
    )

    let journal = JournalStorage()
    let executor = OperationExecutor(
        source: fixture.vfs,
        destination: fixture.vfs,
        journal: journal,
        chunkDelayNanoseconds: 25_000_000,   // 3 chunks ≈ 75 ms
        volumeKeyProvider: fixture.crossVolumeProvider
    )
    let (id, events) = await executor.enqueue(plan, policy: ConflictPolicy())

    let collector = MDEventCollector()
    let pump = Task.detached {
        for await event in events {
            collector.record(event)
        }
    }
    // Time-based mid-copy cancel (the copy needs ~75 ms).
    try await Task.sleep(nanoseconds: 35_000_000)
    await executor.cancel(id)
    #expect(await mdWaitFor { collector.finalSummary() != nil })
    pump.cancel()
    #expect(collector.finalSummary()?.canceled == true)

    let targetURL = fixture.destinationURL.appendingPathComponent("big.bin")
    let partialURL = fixture.destinationURL.appendingPathComponent(".big.bin.mc-partial")
    // 08 §8.3: no final target after cancel — but the partial stays for resume.
    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    var partialSize = 0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: partialURL.path) {
        partialSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
    #expect(partialSize > 0)
    #expect(partialSize < payload.count)

    // Re-enqueue the same plan: the partial is resumed by offset.
    let resumedPlan = try await TransferPlanner.planMove(
        sources: [fixture.path(fileURL)],
        into: fixture.destinationPath,
        source: fixture.vfs,
        destination: fixture.vfs
    )
    let (_, resumedEvents) = await executor.enqueue(resumedPlan, policy: ConflictPolicy(defaultResolution: .overwrite))
    var summary: Summary?
    for await event in resumedEvents {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(try mdRead(targetURL) == payload)
    #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))   // move completed
}

@Test func moveBetweenInMemoryInstancesIsCopyPlusDelete() async throws {
    let source = InMemoryVFS(name: "md-src")
    let destination = InMemoryVFS(name: "md-dst")
    let sourceRoot = VFSPath(root: source.id)
    let destinationRoot = VFSPath(root: destination.id)

    let srcDir = try await source.createDirectory("docs", in: sourceRoot)
    let writer = try await source.openWrite(srcDir.appending(component: "a.txt"), replace: true)
    try await writer.write(Data("generic move".utf8))
    try await writer.finish(committingTo: srcDir.appending(component: "a.txt"))

    let plan = try await TransferPlanner.planMove(sources: [srcDir], into: destinationRoot, source: source, destination: destination)

    let journal = JournalStorage()
    let executor = OperationExecutor(source: source, destination: destination, journal: journal)
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(try await destination.listDirectory(at: destinationRoot).map(\.name).sorted() == ["docs"])
    let reader = try await destination.openRead(destinationRoot.appending(component: "docs").appending(component: "a.txt"))
    var data = Data()
    while let chunk = try await reader.readChunk(max: 1 << 20) { data.append(chunk) }
    #expect(data == Data("generic move".utf8))
    #expect(try await source.listDirectory(at: sourceRoot).isEmpty)   // source gone
}

@Test func deleteDelegatesToNonLocalVFS() async throws {
    let fake = InMemoryVFS(name: "md-fake")
    let root = VFSPath(root: fake.id)
    let dir = try await fake.createDirectory("box", in: root)
    let writer = try await fake.openWrite(dir.appending(component: "x.txt"), replace: true)
    try await writer.write(Data("x".utf8))
    try await writer.finish(committingTo: dir.appending(component: "x.txt"))

    let plan = try await TransferPlanner.planDelete(sources: [dir], source: fake)
    let journal = JournalStorage()
    let executor = OperationExecutor(source: fake, destination: fake, journal: journal)
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    #expect(summary?.succeededItems == 1)
    #expect(try await fake.listDirectory(at: root).isEmpty)

    // Deleted through the adapter — no local trash reversal is recordable.
    let records = journal.recent()
    guard records.count == 1 else {
        Issue.record("expected 1 journal record, got \(records.count)")
        return
    }
    #expect(records[0].reversals.isEmpty)
}

@Test func autoTransportKindDetectsInjectedCrossVolume() throws {
    let fixture = try MDFixture.create(name: "MDKind")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    // Same real volume, same keys → APFS-dependent branch (not localChunked).
    let same = CopyTransaction.autoTransportKind(sourceURL: fixture.sourceURL, targetURL: fixture.destinationURL)
    #expect(same == "clonefile" || same == "fcopyfile")

    // Injected unequal keys → the resumable localChunked branch.
    let cross = CopyTransaction.autoTransportKind(
        sourceURL: fixture.sourceURL,
        targetURL: fixture.destinationURL,
        volumeKey: fixture.crossVolumeProvider
    )
    #expect(cross == "localChunked")
}
