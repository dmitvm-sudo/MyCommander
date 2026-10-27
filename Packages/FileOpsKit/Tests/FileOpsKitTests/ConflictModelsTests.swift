// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import FileOpsKit

// T-12: the ConflictResolver wire format — planner conflicts carry the source
// preview metadata, the row builder fills missing sides, the dialog decisions
// map back into the executor's ConflictPolicy (per-item + «apply to all»).
// Helpers are private and name-spaced (`cm`).

private func cmWrite(_ vfs: InMemoryVFS, _ dir: VFSPath, _ name: String, _ bytes: Data) async throws -> VFSPath {
    let path = dir.appending(component: name)
    let writer = try await vfs.openWrite(path, replace: true)
    try await writer.write(bytes)
    try await writer.finish(committingTo: path)
    return path
}

@Test func planConflictsCarrySourceItemForPreview() async throws {
    let source = InMemoryVFS(name: "cm-src")
    let destination = InMemoryVFS(name: "cm-dst")
    let sourceDir = VFSPath(root: source.id)
    let target = try await destination.createDirectory("box", in: VFSPath(root: destination.id))

    _ = try await cmWrite(source, sourceDir, "clash.txt", Data("new".utf8))
    _ = try await cmWrite(destination, target, "clash.txt", Data("old".utf8))

    let plan = try await TransferPlanner.planCopy(
        sources: [sourceDir.appending(component: "clash.txt")],
        into: target, source: source, destination: destination
    )
    #expect(plan.conflicts.count == 1)
    // The preview needs both sides: the source item is carried by the planner
    // (уточнение T-12), the existing target by .targetExists.
    #expect(plan.conflicts[0].sourceItem != nil)
    #expect(plan.conflicts[0].sourceItem?.name == "clash.txt")
    guard case .targetExists(let existing) = plan.conflicts[0].kind else {
        Issue.record("expected targetExists")
        return
    }
    #expect(existing != nil)
}

@Test func preparePreviewRowsFillMissingSides() async throws {
    let source = InMemoryVFS(name: "cm-src")
    let destination = InMemoryVFS(name: "cm-dst")
    let sourceDir = VFSPath(root: source.id)
    let target = try await destination.createDirectory("box", in: VFSPath(root: destination.id))

    _ = try await cmWrite(source, sourceDir, "known.txt", Data("abc".utf8))
    _ = try await cmWrite(destination, target, "existing.txt", Data("xyz".utf8))

    // A manually built conflict without carried metadata: preparePreviewRows
    // fetches both sides through the VFS adapters (the dialog itself never
    // touches a VFS).
    let conflict = Conflict(
        source: sourceDir.appending(component: "known.txt"),
        target: target.appending(component: "existing.txt"),
        kind: .targetExists(existing: nil)
    )
    let rows = await ConflictModels.preparePreviewRows([conflict], source: source, destination: destination)
    #expect(rows.count == 1)
    #expect(rows[0].sourceItem?.attributes.size == 3)
    #expect(rows[0].targetItem != nil)
    #expect(rows[0].name == "known.txt")

    // A vanished source stays without source metadata.
    let vanished = Conflict(
        source: sourceDir.appending(component: "gone.txt"),
        target: target.appending(component: "whatever.txt"),
        kind: .sourceVanished
    )
    let rows2 = await ConflictModels.preparePreviewRows([vanished], source: source, destination: destination)
    #expect(rows2[0].sourceItem == nil)
}

@Test func buildPolicyMapsPerItemAndApplyToAll() async throws {
    let root = VFSInstanceID(kind: .localDisk, specID: "cm")
    func path(_ name: String) -> VFSPath {
        VFSPath(root: root, components: ["box", name])
    }
    let item = VFSItem(
        id: path("x"),
        instance: root,
        name: "x",
        kind: .file,
        attributes: VFSItemAttributes(size: 1)
    )
    func conflict(_ name: String) -> Conflict {
        Conflict(source: path(name), target: path(name), kind: .targetExists(existing: item), sourceItem: item)
    }

    let rows = [ConflictPreviewRow(conflict: conflict("a"), sourceItem: item, targetItem: item),
                ConflictPreviewRow(conflict: conflict("b"), sourceItem: item, targetItem: item)]

    // Per-item choices without «apply to all»: both targets overridden,
    // default stays the safe keepBoth (runtime re-checks).
    do {
        let policy = ConflictModels.buildPolicy(
            rows: rows,
            resolutions: [.overwrite, .skip],
            applyToAll: nil
        )
        #expect(policy.defaultResolution == .keepBoth)
        #expect(policy.resolve(for: path("a")) == .overwrite)
        #expect(policy.resolve(for: path("b")) == .skip)
    }

    // «Apply to all» becomes the default; rows agreeing with it stay out of
    // the override map (06 §6.2: the map holds only the differing choices).
    do {
        let policy = ConflictModels.buildPolicy(
            rows: rows,
            resolutions: [.skip, .skip],
            applyToAll: .skip
        )
        #expect(policy.defaultResolution == .skip)
        #expect(policy.perTargetPath.isEmpty)
    }

    // «Apply to all» + one manual per-row exception: both flow through.
    do {
        let policy = ConflictModels.buildPolicy(
            rows: rows,
            resolutions: [.overwrite, .skip],
            applyToAll: .skip
        )
        #expect(policy.defaultResolution == .skip)
        #expect(policy.resolve(for: path("a")) == .overwrite)
        #expect(policy.resolve(for: path("b")) == .skip)
    }
}
