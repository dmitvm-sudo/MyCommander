// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import ZIPFoundation
import DomainKit
import VFSKit
@testable import FileOpsKit

// T-22 acceptance (F-12 pack, docs/SDD/12): LocalVFS round-trip (files + a
// nested tree) over the transfer queue, store/deflate method fidelity,
// overwrite/skip/keepBoth conflicts on the shared zip target, packing FROM an
// ArchiveVFS panel (materialization through openRead), the deterministic
// pause-then-cancel flow (published nothing, staged temp removed) and the
// planner's file-target refusal.

private func zpRoot(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("zppack-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func zpWrite(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

private func zpFixture(_ label: String) -> (LocalVFS, URL) {
    let root = zpRoot(label)
    return (LocalVFS(at: root), root)
}

/// Drives one plan to its finished summary.
private func zpRun(_ plan: TransferPlan, policy: ConflictPolicy, executor: OperationExecutor) async -> (Summary?, [TransferEvent]) {
    let (_, events) = await executor.enqueue(plan, policy: policy)
    var summary: Summary?
    var collected: [TransferEvent] = []
    for await event in events {
        collected.append(event)
        if case .finished(let result) = event.phase { summary = result }
    }
    return (summary, collected)
}

@Suite("ZipPack (F-12 pack, T-22)")
struct ZipPackTests {

    @Test func packFilesAndTreeRoundTrip() async throws {
        let (vfs, root) = zpFixture("rt")
        defer { try? FileManager.default.removeItem(at: root) }
        let payloadA = Data("alpha\n".utf8)
        let payloadNested = Data("nested payload\n".utf8)
        zpWrite(payloadA, to: root.appendingPathComponent("a.txt"))
        zpWrite(payloadNested, to: root.appendingPathComponent("sub/nested.txt"))

        let target = VFSPath(root: vfs.id)
        let sources = [
            VFSPath(root: vfs.id, components: ["a.txt"]),
            VFSPath(root: vfs.id, components: ["sub"])
        ]
        let plan = try await ZipPackPlanner.planPack(
            sources: sources, into: target, zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        #expect(plan.items.count == 2)
        #expect(plan.op == .packZip)
        #expect(plan.zipPack?.compression == .deflate)
        #expect(plan.items.allSatisfy { $0.target.components.last == "bundle.zip" })

        let journal = JournalStorage()
        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(defaultResolution: .keepBoth),
                                      executor: OperationExecutor(source: vfs, destination: vfs, journal: journal))
        #expect(summary?.succeededItems == 1)
        #expect(journal.popLast()?.op == .packZip)

        // Round-trip: mount the produced zip through ArchiveVFS.
        let zipURL = root.appendingPathComponent("bundle.zip")
        let archive = try ArchiveVFS(reading: zipURL, extractRoot: root.appendingPathComponent("extract", isDirectory: true))
        let listing = try await archive.listDirectory(at: VFSPath(root: archive.id))
        #expect(Set(listing.map { $0.name }) == ["a.txt", "sub"])

        let nested = try await archive.openRead(VFSPath(root: archive.id, components: ["sub", "nested.txt"]))
        var data = Data()
        while let chunk = try await nested.readChunk(max: 4096) { data.append(chunk) }
        #expect(data == payloadNested)
    }

    @Test func storeMethodKeepsEntriesUncompressed() async throws {
        let (vfs, root) = zpFixture("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0 * 13) })
        zpWrite(payload, to: root.appendingPathComponent("blob.bin"))

        let plan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: vfs.id, components: ["blob.bin"])],
            into: VFSPath(root: vfs.id), zipName: "store.zip",
            source: vfs, destination: vfs, compression: .store
        )
        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(),
                                      executor: OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage()))
        #expect(summary?.succeededItems == 1)

        let archive = try Archive(url: root.appendingPathComponent("store.zip"), accessMode: .read)
        var entries: [ZIPFoundation.Entry] = []
        for entry in archive { entries.append(entry) }
        #expect(entries.count == 1)
        #expect(!entries[0].isCompressed)

        // deflate keeps the entry compressed (the raw bytes differ for this payload).
        let deflatePlan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: vfs.id, components: ["blob.bin"])],
            into: VFSPath(root: vfs.id), zipName: "deflate.zip",
            source: vfs, destination: vfs, compression: .deflate
        )
        let (deflateSummary, _) = await zpRun(deflatePlan, policy: ConflictPolicy(),
                                              executor: OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage()))
        #expect(deflateSummary?.succeededItems == 1)
        let archiveDeflate = try Archive(url: root.appendingPathComponent("deflate.zip"), accessMode: .read)
        for entry in archiveDeflate {
            #expect(entry.isCompressed)
            break
        }
    }

    @Test func overwriteDeletesExistingZipOnce() async throws {
        let (vfs, root) = zpFixture("overwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        zpWrite(Data("fresh\n".utf8), to: root.appendingPathComponent("file.txt"))
        // A junk artifact occupies the zip path before planning.
        zpWrite(Data("junk-not-a-zip".utf8), to: root.appendingPathComponent("bundle.zip"))

        let plan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: vfs.id, components: ["file.txt"])],
            into: VFSPath(root: vfs.id), zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        #expect(plan.conflicts.count == 1)

        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(defaultResolution: .overwrite),
                                      executor: OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage()))
        #expect(summary?.succeededItems == 1)
        // The junk artifact is replaced by a valid zip.
        let archive = try Archive(url: root.appendingPathComponent("bundle.zip"), accessMode: .read)
        var hasFile = false
        for entry in archive where entry.path == "file.txt" { hasFile = true }
        #expect(hasFile)
    }

    @Test func keepBothAutoSuffixesTheZip() async throws {
        let (vfs, root) = zpFixture("keepboth")
        defer { try? FileManager.default.removeItem(at: root) }
        zpWrite(Data("one\n".utf8), to: root.appendingPathComponent("file.txt"))
        zpWrite(Data("existing-zip".utf8), to: root.appendingPathComponent("bundle.zip"))

        let plan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: vfs.id, components: ["file.txt"])],
            into: VFSPath(root: vfs.id), zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(defaultResolution: .keepBoth),
                                      executor: OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage()))
        #expect(summary?.succeededItems == 1)
        // The original artifact survived; the auto-suffixed zip appeared.
        #expect(try Data(contentsOf: root.appendingPathComponent("bundle.zip")) == Data("existing-zip".utf8))
        let suffixed = try Archive(url: root.appendingPathComponent("bundle(1).zip"), accessMode: .read)
        var hasFile = false
        for entry in suffixed where entry.path == "file.txt" { hasFile = true }
        #expect(hasFile)
    }

    @Test func skipLeavesExistingZipUntouched() async throws {
        let (vfs, root) = zpFixture("skip")
        defer { try? FileManager.default.removeItem(at: root) }
        zpWrite(Data("one\n".utf8), to: root.appendingPathComponent("file.txt"))
        zpWrite(Data("existing-zip".utf8), to: root.appendingPathComponent("bundle.zip"))

        let plan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: vfs.id, components: ["file.txt"])],
            into: VFSPath(root: vfs.id), zipName: "bundle.zip",
            source: vfs, destination: vfs
        )
        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(defaultResolution: .skip),
                                      executor: OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage()))
        #expect(summary?.skippedItems == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("bundle.zip")) == Data("existing-zip".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle(1).zip").path))
    }

    @Test func packFromArchivePanelMaterializesThroughOpenRead() async throws {
        let (vfs, root) = zpFixture("fromarchive")
        defer { try? FileManager.default.removeItem(at: root) }

        // Source panel: a mounted zip archive with one file + a nested file.
        let innerPayload = Data("from the archive\n".utf8)
        zpWrite(innerPayload, to: root.appendingPathComponent("src/inner.txt"))
        zpWrite(Data("top of archive\n".utf8), to: root.appendingPathComponent("src/top.txt"))
        let sourceZip = root.appendingPathComponent("panel-archive.zip")
        let buildingArchive = try Archive(url: sourceZip, accessMode: .create)
        try buildingArchive.addEntry(with: "top.txt", relativeTo: root.appendingPathComponent("src"))
        try buildingArchive.addEntry(with: "inner.txt", relativeTo: root.appendingPathComponent("src"))

        let panel = try ArchiveVFS(
            reading: sourceZip,
            extractRoot: root.appendingPathComponent("extract", isDirectory: true)
        )
        let target = VFSPath(root: vfs.id)
        let plan = try await ZipPackPlanner.planPack(
            sources: [VFSPath(root: panel.id, components: ["top.txt"]), VFSPath(root: panel.id, components: ["inner.txt"])],
            into: target, zipName: "picked.zip",
            source: panel, destination: vfs
        )
        let (summary, _) = await zpRun(plan, policy: ConflictPolicy(),
                                      executor: OperationExecutor(source: panel, destination: vfs, journal: JournalStorage()))
        #expect(summary?.succeededItems == 1)

        let picked = try Archive(url: root.appendingPathComponent("picked.zip"), accessMode: .read)
        var contents: [String: Data] = [:]
        let unpackDir = root.appendingPathComponent("picked-unpack", isDirectory: true)
        for entry in picked {
            let destinationURL = unpackDir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try picked.extract(entry, to: destinationURL, skipCRC32: true)
            contents[entry.path] = try? Data(contentsOf: destinationURL)
        }
        #expect(contents["top.txt"] == Data("top of archive\n".utf8))
        #expect(contents["inner.txt"] == innerPayload)
    }

    @Test func pauseThenCancelPublishesNothing() async throws {
        let (vfs, root) = zpFixture("pausecancel")
        defer { try? FileManager.default.removeItem(at: root) }
        zpWrite(Data("one\n".utf8), to: root.appendingPathComponent("one.txt"))
        zpWrite(Data("two\n".utf8), to: root.appendingPathComponent("two.txt"))
        zpWrite(Data("three\n".utf8), to: root.appendingPathComponent("three.txt"))

        let plan = try await ZipPackPlanner.planPack(
            sources: [
                VFSPath(root: vfs.id, components: ["one.txt"]),
                VFSPath(root: vfs.id, components: ["two.txt"]),
                VFSPath(root: vfs.id, components: ["three.txt"])
            ],
            into: VFSPath(root: vfs.id), zipName: "canceled.zip",
            source: vfs, destination: vfs
        )
        let executor = OperationExecutor(source: vfs, destination: vfs, journal: JournalStorage())
        let (id, events) = await executor.enqueue(plan, policy: ConflictPolicy())
        // Pause before the second entry → the run stalls inside the gate; a
        // cancel there must remove the staged temp and publish nothing.
        await executor.pause(id)
        await executor.cancel(id)
        var summary: Summary?
        for await event in events {
            if case .finished(let result) = event.phase { summary = result }
        }
        #expect(summary?.canceled == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("canceled.zip").path))
    }

    @Test func plannerRefusesFileTarget() async throws {
        let (vfs, root) = zpFixture("filetarget")
        defer { try? FileManager.default.removeItem(at: root) }
        zpWrite(Data("x".utf8), to: root.appendingPathComponent("plain.txt"))
        do {
            _ = try await ZipPackPlanner.planPack(
                sources: [VFSPath(root: vfs.id, components: ["plain.txt"])],
                into: VFSPath(root: vfs.id, components: ["plain.txt"]), zipName: "no.zip",
                source: vfs, destination: vfs
            )
            Issue.record("planning into a file target must be refused")
        } catch let error as TransferPlannerError {
            #expect(isInsideTargetNotADirectory(error))
        }
    }

    private func isInsideTargetNotADirectory(_ error: TransferPlannerError) -> Bool {
        if case .targetNotADirectory = error { return true }
        return false
    }
}
