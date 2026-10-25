// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.2 «Journal» (уточнение T-20) — undo replays the
// reverse plan of a journal record through the SAME OperationExecutor path
// (planner → conflicts dialog → transactions, F-6). One reversal per record
// in v1: copy/move records are per-item, a trash delete wraps one `fm.trashItem`
// tree, mkdir appends exactly one `deleteCreated`. A record without reversals
// (permanent delete, link/mkdir rejection) yields no plan — the App reports
// «undo недоступен» and re-appends the record.
//
// VFS semantics: `renameBack`/`deleteCreated` work on any VFS pair; the trash
// reversal addresses the item by its REAL trash URL (`displayURL` drives the
// local rename fast path, §6.2 T-16 lesson: root stays the workspace identity,
// so `checkOwn` accepts the path).

public enum UndoPlanner {
    /// Builds the reverse plan for the newest (popped) journal record.
    /// - Returns `nil` when the record has no reversal — F-6 «undo недоступен».
    public static func plan(
        record: JournalRecord,
        source: any VFS,
        destination: any VFS
    ) async -> TransferPlan? {
        // v1: one reversal per record (05 §5.6 уточнение T-20).
        guard let reversal = record.reversals.first else { return nil }

        switch reversal {
        case let .renameBack(at, previousName):
            // Move the object back to its previous name in the same parent
            // (planMove renames only when moving INTO a directory — the
            // same-dir rename is constructed by hand, like the F-4 flow).
            let target = VFSPath(
                root: at.root,
                components: at.components.dropLast() + [previousName],
                displayURL: at.displayURL?.deletingLastPathComponent().appendingPathComponent(previousName)
            )
            return await reverseMovePlan(from: at, to: target, source: source, destination: destination)

        case let .restoreFromTrash(original, trashURL):
            // The trashed item is addressed by its real URL; the components
            // carry the absolute POSIX segments (on the root-at-«/» workspace
            // `resolveURL` reproduces the trash path verbatim).
            let trashPath = VFSPath(
                root: source.id,
                components: VFSPath.normalizedComponents(from: trashURL),
                displayURL: trashURL
            )
            return await reverseMovePlan(from: trashPath, to: original, source: source, destination: destination)

        case let .deleteCreated(path):
            // The object WE created (copy target, cross-volume move target,
            // mkdir) — remove it on the created-side workspace (v1: both
            // workspaces are the same local instance).
            return try? await TransferPlanner.planDelete(sources: [path], source: destination)
        }
    }

    /// Shared `.move`-shaped reversal (rename-back / trash restore): one item,
    /// a precomputed `targetExists` conflict exactly like `TransferPlanner`
    /// expand does — the App then routes the plan into the regular conflicts
    /// dialog («частичный undo» = apply-to-all on the reverse plan).
    private static func reverseMovePlan(
        from: VFSPath,
        to: VFSPath,
        source: any VFS,
        destination: any VFS
    ) async -> TransferPlan? {
        // Real metadata when the source resolves through its VFS; a URL-based
        // stub for trash URLs outside a workspace root (the local rename fast
        // path reads only the URL pair).
        let item = (try? await source.metadata(of: from)) ?? stubItem(from)

        var conflicts: [Conflict] = []
        if let existing = try? await destination.metadata(of: to) {
            conflicts.append(Conflict(
                source: from,
                target: to,
                kind: .targetExists(existing: existing),
                sourceItem: item
            ))
        }
        return TransferPlan(
            op: .move,
            items: [TransferItem(source: from, target: to, item: item)],
            conflicts: conflicts
        )
    }

    /// Minimal item for a source the VFS cannot stat (a trash URL outside the
    /// workspace root). Name/kind come straight from the real URL.
    private static func stubItem(_ path: VFSPath) -> VFSItem {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        if let url = path.displayURL {
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        }
        let size = path.displayURL.flatMap { try? fm.attributesOfItem(atPath: $0.path) }?[.size] as? Int64
        return VFSItem(
            id: path,
            instance: path.root,
            name: path.components.last ?? (path.displayURL?.lastPathComponent ?? ""),
            kind: isDirectory.boolValue ? .directory : .file,
            attributes: VFSItemAttributes(size: size),
            revision: 0
        )
    }
}
