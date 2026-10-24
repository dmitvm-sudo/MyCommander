// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.2 layer 1 — the Planner builds a TransferPlan for
// the UI: expands trees (listDirectory recursively, streaming depth/size
// report via ProgressSink), precomputes conflicts (target stat), detects
// edge cases. T-10 scope: same-volume copy (move/delete arrive with T-11).

public enum TransferPlannerError: Error {
    /// The copy target is not a directory (metadata said otherwise).
    case targetNotADirectory(VFSPath)
}

public enum TransferPlanner {
    /// Plans a copy of `sources` into the directory `target`. Tree sources are
    /// expanded flat: every item keeps its fully-computed destination path
    /// (docs/SDD/05 §5.6 `TransferItem`). A source that contains the target is
    /// marked `insideSelfMove` — the executor refuses those items and the
    /// expansion skips the target subtree (no infinite copy).
    public static func planCopy(
        sources: [VFSPath],
        into target: VFSPath,
        source: any VFS,
        destination: any VFS,
        progress: ProgressSink? = nil
    ) async throws -> TransferPlan {
        let targetItem = try await destination.metadata(of: target)
        guard case .directory = targetItem.kind else {
            throw TransferPlannerError.targetNotADirectory(target)
        }

        var items: [TransferItem] = []
        var conflicts: [Conflict] = []

        for sourcePath in sources {
            let sourceItem = try await source.metadata(of: sourcePath)

            // Copying a directory into its own subtree is a classic operator
            // slip: refuse instead of recursing forever (06 §6.2 edge cases).
            if isInside(sourcePath, of: target) {
                conflicts.append(Conflict(
                    source: sourcePath,
                    target: target,
                    kind: .insideSelfMove
                ))
                continue
            }

            await expand(
                sourceItem,
                sourcePath: sourcePath,
                into: target.appending(component: sourceItem.name),
                source: source,
                destination: destination,
                progress: progress,
                items: &items,
                conflicts: &conflicts
            )
        }

        return TransferPlan(op: .copy, items: items, conflicts: conflicts)
    }

    /// «name(1).ext» auto-suffix (docs/SDD/02 F-5, 08 §8.3): the first free
    /// candidate starting at `proposed`.
    public static func uniqueTargetName(for proposed: VFSPath, in destination: any VFS) async -> VFSPath {
        guard let base = proposed.components.last else { return proposed }
        let nsName = base as NSString
        let stem = nsName.deletingPathExtension
        let suffix = nsName.pathExtension
        var counter = 1
        while counter < 10_000 {
            let candidateName = suffix.isEmpty
                ? "\(stem)(\(counter))"
                : "\(stem)(\(counter)).\(suffix)"
            let candidate = VFSPath(
                root: proposed.root,
                components: proposed.components.dropLast() + [candidateName],
                displayURL: proposed.displayURL?.deletingLastPathComponent().appendingPathComponent(candidateName)
            )
            if (try? await destination.metadata(of: candidate)) == nil {
                return candidate
            }
            counter += 1
        }
        return proposed   // pathological; the item will fail visibly
    }

    // MARK: expansion

    private static func expand(
        _ item: VFSItem,
        sourcePath: VFSPath,
        into targetPath: VFSPath,
        source: any VFS,
        destination: any VFS,
        progress: ProgressSink?,
        items: inout [TransferItem],
        conflicts: inout [Conflict]
    ) async {
        // Conflict precomputation: does something occupy the target?
        if let existing = try? await destination.metadata(of: targetPath) {
            conflicts.append(Conflict(
                source: sourcePath,
                target: targetPath,
                kind: .targetExists(existing: existing)
            ))
        }

        items.append(TransferItem(source: sourcePath, target: targetPath, item: item))
        progress?(ProgressUpdate(completedItems: items.count, message: item.name))

        guard case .directory = item.kind else { return }
        guard let children = try? await source.listDirectory(at: sourcePath) else { return }
        for child in children {
            await expand(
                child,
                sourcePath: child.id,
                into: targetPath.appending(component: child.name),
                source: source,
                destination: destination,
                progress: progress,
                items: &items,
                conflicts: &conflicts
            )
        }
    }

    /// `target` lives inside `source`'s subtree (or equals it).
    private static func isInside(_ source: VFSPath, of target: VFSPath) -> Bool {
        guard source.root == target.root else { return false }
        guard source.components.count <= target.components.count else { return false }
        return Array(target.components.prefix(source.components.count)) == source.components
    }
}
