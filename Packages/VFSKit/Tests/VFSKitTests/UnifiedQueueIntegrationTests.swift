// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import EnginesKit
import FileOpsKit
import Foundation
import Testing
import VFSKit

// T-27 acceptance (M2 exit, docs/SDD/12): the UNIFIED queue/conflicts path —
// every transfer-class mutation (copy / move / delete / packZip / extract /
// undo reversals) rides ONE OperationExecutor; the smoke 8.4 п.6–7 automated
// cores (zip round-trip with RU/emoji names through the panel path; SFTP
// browse/copy/copy-back through the same path). Contract: 09 M2 exit уточнение
// T-27 + 08 §8.4 уточнение T-27.

private func uqTempRoot(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("unifiedq-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func uqWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// Drives one plan to its finished summary through the shared executor (the
/// per-run VFS pair rides enqueue — 05 §5.6 уточнение T-27).
private func uqRun(
    _ plan: TransferPlan,
    policy: ConflictPolicy,
    executor: OperationExecutor,
    source: (any VFS)? = nil,
    destination: (any VFS)? = nil
) async -> Summary? {
    let (_, events) = await executor.enqueue(plan, policy: policy, source: source, destination: destination)
    var summary: Summary?
    for await event in events {
        if case .finished(let result) = event.phase { summary = result }
    }
    return summary
}

@Suite("UnifiedQueue (M2 exit, T-27)")
struct UnifiedQueueIntegrationTests {

    /// Every transfer class rides the ONE executor: copy → move → delete →
    /// packZip in sequence; the journal records each op (queue + conflicts +
    /// journal = один путь).
    @Test func allTransferClassesRideOneExecutor() async throws {
        let root = uqTempRoot("classes")
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = VFSInstanceID(kind: .localDisk, specID: "uq-root")
        let vfs = LocalVFS(at: root, instanceID: rootID)
        try uqWrite(Data("alpha".utf8), to: root.appendingPathComponent("a.txt"))
        try uqWrite(Data("beta".utf8), to: root.appendingPathComponent("b.txt"))

        // A distinct destination directory (its OWN instance id — two local
        // dirs are two VFS instances, matching the App's one-workspace model).
        let destDir = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destID = VFSInstanceID(kind: .localDisk, specID: "uq-dest")
        let destVfs = LocalVFS(at: destDir, instanceID: destID)

        let journal = JournalStorage()
        // ONE executor for every class (the App's unified-queue model); the
        // per-run VFS pair rides enqueue (05 §5.6 уточнение T-27).
        let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
        let policy = ConflictPolicy(defaultResolution: .keepBoth)

        // COPY: a.txt → dest/a.txt (fresh directory — no conflict).
        let copyPlan = try await TransferPlanner.planCopy(
            sources: [VFSPath(root: rootID, components: ["a.txt"])],
            into: VFSPath(root: destID), source: vfs, destination: destVfs
        )
        let copySummary = await uqRun(copyPlan, policy: policy, executor: executor, source: vfs, destination: destVfs)
        #expect(copySummary?.succeededItems == 1 && copySummary?.failedItems == 0)
        #expect((FileManager.default.contents(atPath: destDir.appendingPathComponent("a.txt").path) ?? Data()) == Data("alpha".utf8))

        // MOVE: b.txt → dest/b.txt.
        let movePlan = try await TransferPlanner.planMove(
            sources: [VFSPath(root: rootID, components: ["b.txt"])],
            into: VFSPath(root: destID), source: vfs, destination: destVfs
        )
        let moveSummary = await uqRun(movePlan, policy: policy, executor: executor, source: vfs, destination: destVfs)
        #expect(moveSummary?.succeededItems == 1 && moveSummary?.failedItems == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        #expect((FileManager.default.contents(atPath: destDir.appendingPathComponent("b.txt").path) ?? Data()) == Data("beta".utf8))

        // DELETE: the copy made by step one.
        let deletePlan = try await TransferPlanner.planDelete(
            sources: [VFSPath(root: destID, components: ["a.txt"])],
            source: destVfs
        )
        let deleteSummary = await uqRun(deletePlan, policy: policy, executor: executor, source: destVfs, destination: destVfs)
        #expect(deleteSummary?.succeededItems == 1)
        #expect(!FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.txt").path))

        // PACK: the remaining original into one zip (the T-22 branch).
        let packPlan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: rootID, components: ["a.txt"])],
            into: VFSPath(root: rootID), zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        let packSummary = await uqRun(packPlan, policy: policy, executor: executor)
        // One plan = ONE zip artifact (06 §6.2 T-22), hence 1, not per-source.
        #expect(packSummary?.succeededItems == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle.zip").path))

        // The journal is the unified-path receipt: copy, move, delete, pack —
        // in the order they were enqueued (the executor is serial).
        var ops: [TransferOpKind] = []
        while let record = journal.popLast() {
            ops.append(record.op)
        }
        #expect(ops == [.packZip, .delete, .move, .copy])
    }

    /// Smoke 8.4 п.7 (ядро): SFTP copy / copy-back through the unified path
    /// (planCopy + the shared executor; the live in-process SFTP server).
    @Test func localToSftpCopyAndBackThroughExecutor() async throws {
        let fixture = try await SFFixture.start("uq-sftp")
        defer { Task { await fixture.stop() } }
        let connection = try await fixture.connect()

        let localID = VFSInstanceID(kind: .localDisk, specID: "uq-sftp-src")
        let local = LocalVFS(at: fixture.root, instanceID: localID)
        let remote = SftpVFS(connection: connection)
        try uqWrite(Data("sftp payload".utf8), to: fixture.root.appendingPathComponent("payload.txt"))

        // Local → SFTP (upload).
        let executor = OperationExecutor(source: local, destination: remote, journal: JournalStorage())
        let upPlan = try await TransferPlanner.planCopy(
            sources: [VFSPath(root: local.id, components: ["payload.txt"])],
            into: VFSPath(root: remote.id), source: local, destination: remote
        )
        let upSummary = await uqRun(upPlan, policy: ConflictPolicy(defaultResolution: .keepBoth), executor: executor)
        #expect(upSummary?.succeededItems == 1)

        // The remote side really has the bytes.
        let stream = try await remote.openRead(VFSPath(root: remote.id, components: ["payload.txt"]))
        var uploaded = Data()
        while let chunk = try await stream.readChunk(max: 4096) { uploaded.append(chunk) }
        #expect(uploaded == Data("sftp payload".utf8))

        // SFTP → Local (copy-back) — through the SAME executor shape.
        let backDir = uqTempRoot("uq-back")
        defer { try? FileManager.default.removeItem(at: backDir) }
        let backLocal = LocalVFS(at: backDir, instanceID: VFSInstanceID(kind: .localDisk, specID: "uq-sftp-back"))
        let backExecutor = OperationExecutor(source: remote, destination: backLocal, journal: JournalStorage())
        let backPlan = try await TransferPlanner.planCopy(
            sources: [VFSPath(root: remote.id, components: ["payload.txt"])],
            into: VFSPath(root: backLocal.id), source: remote, destination: backLocal
        )
        let backSummary = await uqRun(backPlan, policy: ConflictPolicy(defaultResolution: .keepBoth), executor: backExecutor)
        #expect(backSummary?.succeededItems == 1)
        #expect((FileManager.default.contents(atPath: backDir.appendingPathComponent("payload.txt").path) ?? Data()) == Data("sftp payload".utf8))
        await connection.close()
    }

    /// Smoke 8.4 п.6 (ядро): pack → mount → extract with RU/emoji names —
    /// the FULL panel path (executor for pack AND extract).
    @Test func zipRoundTripThroughUnifiedPathSurvivesUnicodeNames() async throws {
        let root = uqTempRoot("uq-unicode")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = LocalVFS(at: root)
        let names = ["Привет мир.txt", "каталог с ёлкой", "emoji 🚀 файл.md"]
        for (index, name) in names.enumerated() {
            try uqWrite(Data("payload-\(index)".utf8), to: root.appendingPathComponent(name))
        }

        let executor = OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage())
        let policy = ConflictPolicy(defaultResolution: .keepBoth)

        // PACK the three into one zip (the T-22 branch of the same executor).
        let packPlan = try await ZipPackPlanner.planPack(
            sources: names.map { VFSPath(root: vfs.id, components: [$0]) },
            into: VFSPath(root: vfs.id), zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        let packSummary = await uqRun(packPlan, policy: policy, executor: executor)
        // One plan = ONE zip artifact (06 §6.2 T-22), hence 1, not per-source 3.
        #expect(packSummary?.succeededItems == 1)

        // MOUNT the produced zip (the archive-interlude path).
        let archive = try ArchiveVFS(
            reading: root.appendingPathComponent("bundle.zip"),
            extractRoot: root.appendingPathComponent("extract", isDirectory: true)
        )
        let listing = try await archive.listDirectory(at: VFSPath(root: archive.id))
        #expect(Set(listing.map { $0.name }) == Set(names))

        // EXTRACT = planCopy from the archive into a fresh local dir through
        // the SAME executor shape (the panel's F5 from an archive panel).
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outVfs = LocalVFS(at: outDir, instanceID: VFSInstanceID(kind: .localDisk, specID: "uq-unicode-out"))
        let extractExecutor = OperationExecutor(source: archive, destination: outVfs, journal: JournalStorage())
        let extractPlan = try await TransferPlanner.planCopy(
            sources: names.map { VFSPath(root: archive.id, components: [$0]) },
            into: VFSPath(root: outVfs.id), source: archive, destination: outVfs
        )
        let extractSummary = await uqRun(extractPlan, policy: policy, executor: extractExecutor)
        #expect(extractSummary?.succeededItems == 3)

        // No name lost its identity (RU/emoji survive the full round trip).
        for (index, name) in names.enumerated() {
            let url = outDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect((FileManager.default.contents(atPath: url.path) ?? Data()) == Data("payload-\(index)".utf8))
        }
    }

    /// Unicode names survive the SFTP hop too (п.7 «без потери имён»).
    @Test func sftpCopyPreservesUnicodeNames() async throws {        let fixture = try await SFFixture.start("uq-sftp-uni")
        defer { Task { await fixture.stop() } }
        let connection = try await fixture.connect()
        let local = LocalVFS(at: fixture.root, instanceID: VFSInstanceID(kind: .localDisk, specID: "uq-sftp-uni-src"))
        let remote = SftpVFS(connection: connection)

        let names = ["Привет.txt", "эмодзи 🛰 файл.bin"]
        for (index, name) in names.enumerated() {
            try uqWrite(Data("uni-\(index)".utf8), to: fixture.root.appendingPathComponent(name))
        }

        let executor = OperationExecutor(source: local, destination: remote, journal: JournalStorage())
        let plan = try await TransferPlanner.planCopy(
            sources: names.map { VFSPath(root: local.id, components: [$0]) },
            into: VFSPath(root: remote.id), source: local, destination: remote
        )
        let summary = await uqRun(plan, policy: ConflictPolicy(defaultResolution: .keepBoth), executor: executor)
        #expect(summary?.succeededItems == 2)

        // The remote listing carries BOTH names intact (bytes verified for one).
        let listing = try await remote.listDirectory(at: VFSPath(root: remote.id))
        #expect(Set(listing.map { $0.name }).isSuperset(of: Set(names)))
        let stream = try await remote.openRead(VFSPath(root: remote.id, components: [names[0]]))
        var data = Data()
        while let chunk = try await stream.readChunk(max: 4096) { data.append(chunk) }
        #expect(data == Data("uni-0".utf8))
        await connection.close()
    }

    /// F-14 (T-28): the multi-rename plan rides the SAME unified queue —
    /// ONE `.move` plan built by RenamePlanner, executed with the panel's
    /// per-run VFS pair; the journal records `renameBack` (undo F-6).
    @Test func multiRenameThroughUnifiedQueue() async throws {
        let root = uqTempRoot("uq-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let panelID = VFSInstanceID(kind: .localDisk, specID: "uq-rename-panel")
        let vfs = LocalVFS(at: root, instanceID: panelID)
        let names = ["photo1.jpg", "photo2.jpg", "notes.md"]
        for (index, name) in names.enumerated() {
            try uqWrite(Data("content-\(index)".utf8), to: root.appendingPathComponent(name))
        }
        let listing = try await vfs.listDirectory(at: VFSPath(root: panelID))
        // Deterministic selection order (the panel sends visible order): the
        // counters ride it — «photo1, photo2, notes» → 01, 02, 03.
        let items = names.compactMap { name in listing.first { $0.name == name } }

        let rule = RenameRule(template: "trip_[C].[E]", counterStart: 1, counterStep: 1, counterPad: 2)
        let plan = RenamePlanner.plan(items: items, rule: rule, occupiedNames: Set(listing.map(\.name)))
        #expect(plan.isValid && plan.pairs.count == 3)
        let transfer = RenamePlanner.buildTransferPlan(pairs: plan.pairs, in: VFSPath(root: panelID))

        let journal = JournalStorage()
        let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
        let summary = await uqRun(transfer, policy: ConflictPolicy(defaultResolution: .skip), executor: executor, source: vfs, destination: vfs)
        #expect(summary?.succeededItems == 3)

        // The directory now holds exactly the renamed set (counters ride the
        // selection order).
        let after = try await vfs.listDirectory(at: VFSPath(root: panelID))
        let afterNames = Set(after.map(\.name))
        #expect(afterNames == ["trip_01.jpg", "trip_02.jpg", "trip_03.md"])

        // Undo receipt: the move branch journals PER ITEM (one .move record
        // with one renameBack each) — collect the whole receipt and union the
        // reversals (undo replays them bottom-up).
        var reversals: Set<Reversal> = []
        var recordOps: [TransferOpKind] = []
        while let record = journal.popLast() {
            recordOps.append(record.op)
            reversals.formUnion(record.reversals)
        }
        #expect(Set(recordOps) == [.move])
        let expected: Set<Reversal> = [
            .renameBack(at: VFSPath(root: panelID, components: ["trip_01.jpg"]), previousName: "photo1.jpg"),
            .renameBack(at: VFSPath(root: panelID, components: ["trip_02.jpg"]), previousName: "photo2.jpg"),
            .renameBack(at: VFSPath(root: panelID, components: ["trip_03.md"]), previousName: "notes.md")
        ]
        #expect(reversals == expected)
    }
}
