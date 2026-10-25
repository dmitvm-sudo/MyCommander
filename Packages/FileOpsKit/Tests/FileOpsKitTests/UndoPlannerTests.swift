// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
import VFSKit
@testable import FileOpsKit

// T-20: UndoPlanner (F-6) — the reverse plan per journal-record reversal:
// rename-back (.move back to the previous name), copy → `deleteCreated` undo,
// trash → `restoreFromTrash` undo (touching the REAL Trash via `fm.trashItem`),
// the permanent delete (no reversal → nil plan → App reports «undo недоступен»),
// the `targetExists` conflict the App surfaces in the conflicts dialog, and the
// executor's visible refusal of a planned `.mkdir`. Helpers use the `ju`
// name-space (the test module compiles neighbouring files together).

private func juFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
}

private func juPath(_ vfs: LocalVFS, _ name: String) -> VFSPath {
    VFSPath(root: vfs.id, components: [name])
}

/// planMove renames only when moving INTO another directory — the same-dir
/// rename behind F-6 `renameBack` is a hand-built plan (the executor then
/// publishes the renameBack reversal verbatim).
private func juRenamePlan(_ source: VFSPath, toName: String) -> TransferPlan {
    let item = VFSItem(
        id: source,
        instance: source.root,
        name: source.components.last ?? "",
        kind: .file,
        attributes: VFSItemAttributes(size: 7),
        revision: 1
    )
    let target = VFSPath(
        root: source.root,
        components: source.components.dropLast() + [toName],
        displayURL: source.displayURL?.deletingLastPathComponent().appendingPathComponent(toName)
    )
    return TransferPlan(op: .move, items: [TransferItem(source: source, target: target, item: item)])
}

private func juRun(_ executor: OperationExecutor, _ plan: TransferPlan) async -> (Summary, [MCError]) {
    let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy())
    var summary = Summary()
    var failures: [MCError] = []
    for await event in events {
        switch event.phase {
        case .itemFailed(let error): failures.append(error)
        case .finished(let finished): summary = finished
        default: break
        }
    }
    return (summary, failures)
}

@Test func undoRenameBackRestoresPreviousName() async throws {
    let rootURL = juFixtureURL("JURename")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    try Data("payload".utf8).write(to: rootURL.appendingPathComponent("old-name.txt"))

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
    let (runSummary, runFailures) = await juRun(executor, juRenamePlan(juPath(vfs, "old-name.txt"), toName: "new-name.txt"))
    #expect(runFailures.isEmpty)
    #expect(runSummary.succeededItems == 1)
    #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("old-name.txt").path))

    guard let record = journal.popLast() else {
        Issue.record("journal did not record the rename")
        return
    }
    guard case .renameBack(_, let previousName)? = record.reversals.first else {
        Issue.record("expected renameBack, got \(String(describing: record.reversals.first))")
        return
    }
    #expect(previousName == "old-name.txt")

    guard let undoPlan = await UndoPlanner.plan(record: record, source: vfs, destination: vfs) else {
        Issue.record("no undo plan for a renameBack record")
        return
    }
    #expect(undoPlan.op == .move)
    #expect(undoPlan.items[0].target.components.last == "old-name.txt")
    #expect(undoPlan.conflicts.isEmpty)

    let (undoSummary, undoFailures) = await juRun(executor, undoPlan)
    #expect(undoFailures.isEmpty)
    #expect(undoSummary.succeededItems == 1)
    #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("old-name.txt").path))
    #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("new-name.txt").path))
}

@Test func undoDeleteCreatedRemovesCopiedTarget() async throws {
    let rootURL = juFixtureURL("JUCopy")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    try Data("payload".utf8).write(to: rootURL.appendingPathComponent("src.txt"))
    try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("dst"), withIntermediateDirectories: true)

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
    let copyPlan = try await TransferPlanner.planCopy(
        sources: [juPath(vfs, "src.txt")],
        into: juPath(vfs, "dst"),
        source: vfs,
        destination: vfs
    )
    let (_, copyFailures) = await juRun(executor, copyPlan)
    #expect(copyFailures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("dst/src.txt").path))

    guard let record = journal.popLast() else {
        Issue.record("journal did not record the copy")
        return
    }
    guard case .deleteCreated(let created)? = record.reversals.first else {
        Issue.record("expected deleteCreated, got \(String(describing: record.reversals.first))")
        return
    }
    #expect(record.op == .copy)
    #expect(created.components == ["dst", "src.txt"])

    guard let undoPlan = await UndoPlanner.plan(record: record, source: vfs, destination: vfs) else {
        Issue.record("no undo plan for a deleteCreated record")
        return
    }
    #expect(undoPlan.op == .delete)

    let (undoSummary, undoFailures) = await juRun(executor, undoPlan)
    #expect(undoFailures.isEmpty)
    #expect(undoSummary.succeededItems == 1)
    #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("dst/src.txt").path))
    // The undo deletes the created COPY only.
    #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("src.txt").path))
}

@Test func undoRestoreFromTrashMovesFileBack() async throws {
    let rootURL = juFixtureURL("JUTrash")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    try Data("to trash".utf8).write(to: rootURL.appendingPathComponent("gone.txt"))

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)   // deleteToTrash defaults to true (F-5)
    let deletePlan = try await TransferPlanner.planDelete(sources: [juPath(vfs, "gone.txt")], source: vfs)
    let (_, deleteFailures) = await juRun(executor, deletePlan)
    #expect(deleteFailures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("gone.txt").path))

    guard let record = journal.popLast() else {
        Issue.record("journal did not record the trash delete")
        return
    }
    guard case .restoreFromTrash(let original, let trashURL)? = record.reversals.first else {
        Issue.record("expected restoreFromTrash, got \(String(describing: record.reversals.first))")
        return
    }
    // The trashed copy really landed in the Trash (reversal provenance).
    #expect(original == juPath(vfs, "gone.txt"))
    #expect(FileManager.default.fileExists(atPath: trashURL.path))

    guard let undoPlan = await UndoPlanner.plan(record: record, source: vfs, destination: vfs) else {
        Issue.record("no undo plan for a restoreFromTrash record")
        return
    }
    #expect(undoPlan.op == .move)
    #expect(undoPlan.items[0].target == juPath(vfs, "gone.txt"))

    let (undoSummary, undoFailures) = await juRun(executor, undoPlan)
    #expect(undoFailures.isEmpty)
    #expect(undoSummary.succeededItems == 1)
    #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("gone.txt").path))
    #expect(!FileManager.default.fileExists(atPath: trashURL.path))
    try? FileManager.default.removeItem(at: trashURL)   // keep the test clean
}

@Test func undoPermanentDeleteYieldsNoPlan() async throws {
    let rootURL = juFixtureURL("JUPermanent")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    try Data("gone forever".utf8).write(to: rootURL.appendingPathComponent("gone.txt"))

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal, deleteToTrash: false)
    let deletePlan = try await TransferPlanner.planDelete(sources: [juPath(vfs, "gone.txt")], source: vfs)
    let (_, deleteFailures) = await juRun(executor, deletePlan)
    #expect(deleteFailures.isEmpty)

    guard let record = journal.popLast() else {
        Issue.record("journal did not record the permanent delete")
        return
    }
    #expect(record.reversals.isEmpty)
    let undoPlan = await UndoPlanner.plan(record: record, source: vfs, destination: vfs)
    #expect(undoPlan == nil)
}

@Test func undoRenameBackSeedsTargetExistsConflict() async throws {
    let rootURL = juFixtureURL("JUOccupied")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    try Data("payload".utf8).write(to: rootURL.appendingPathComponent("a.txt"))

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
    _ = await juRun(executor, juRenamePlan(juPath(vfs, "a.txt"), toName: "b.txt"))

    // The previous name is now occupied by a foreign file — the reverse plan
    // must precompute the conflict like TransferPlanner does (F-6: the regular
    // conflicts dialog with apply-to-all).
    try Data("stranger".utf8).write(to: rootURL.appendingPathComponent("a.txt"))

    guard let record = journal.popLast() else {
        Issue.record("journal did not record the rename")
        return
    }
    guard let undoPlan = await UndoPlanner.plan(record: record, source: vfs, destination: vfs) else {
        Issue.record("no undo plan for a renameBack record")
        return
    }
    #expect(undoPlan.conflicts.count == 1)
    guard case .targetExists(let existing) = undoPlan.conflicts[0].kind else {
        Issue.record("expected targetExists, got \(String(describing: undoPlan.conflicts.first?.kind))")
        return
    }
    #expect(existing?.name == "a.txt")
    #expect(undoPlan.items.count == 1)
}

@Test func mkdirPlanItemsFailVisiblyInExecutor() async throws {
    let rootURL = juFixtureURL("JUMkdir")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let vfs = LocalVFS(at: rootURL)
    let path = juPath(vfs, "planned-dir")
    let item = VFSItem(
        id: path,
        instance: path.root,
        name: "planned-dir",
        kind: .directory,
        attributes: VFSItemAttributes(),
        revision: 1
    )
    let plan = TransferPlan(op: .mkdir, items: [TransferItem(source: path, target: path, item: item)])

    let journal = JournalStorage()
    let executor = OperationExecutor(source: vfs, destination: vfs, journal: journal)
    let (summary, failures) = await juRun(executor, plan)
    #expect(summary.failedItems == 1)
    #expect(journal.recent().isEmpty)   // a refused op writes nothing
    guard case .vfsUnsupported(_, _)? = failures.first else {
        Issue.record("expected vfsUnsupported, got \(String(describing: failures.first))")
        return
    }
}
