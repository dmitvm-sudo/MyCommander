// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.2 layer 2 «ConflictResolver» — the UI dialog gets
// a preview (name/size/date per side) over the planner's precomputed conflict
// list and returns a ConflictPolicy (per-item choices + «apply to all»).
// This file is the wire format between the planner's Conflict values and the
// ListViewKit dialog: it fills in the missing side metadata so the dialog
// never touches a VFS itself.

/// One dialog row: the conflict plus both sides' metadata for the preview.
public struct ConflictPreviewRow: Sendable {
    public let conflict: Conflict
    /// Source side (may be `nil` — e.g. a vanished source).
    public let sourceItem: VFSItem?
    /// Target side (`nil` when the kind does not carry it and the VFS lookup
    /// fails — the dialog shows «?»).
    public let targetItem: VFSItem?

    public init(conflict: Conflict, sourceItem: VFSItem?, targetItem: VFSItem?) {
        self.conflict = conflict
        self.sourceItem = sourceItem
        self.targetItem = targetItem
    }

    /// Display name: the source's last component (the dialog shows the
    /// name clash; full paths live in tooltips later, T-12 stub keeps it simple).
    public var name: String {
        sourceItem?.name ?? conflict.source.components.last ?? conflict.target.components.last ?? ""
    }
}

/// Resolves both preview sides for the planner's conflicts. The planner
/// already carries `sourceItem` (уточнение T-12) and `targetExists(existing:)`;
/// anything missing is fetched here, once, before the dialog opens.
public enum ConflictModels {
    public static func preparePreviewRows(
        _ conflicts: [Conflict],
        source: any VFS,
        destination: any VFS
    ) async -> [ConflictPreviewRow] {
        var rows: [ConflictPreviewRow] = []
        rows.reserveCapacity(conflicts.count)
        for conflict in conflicts {
            let sourceItem: VFSItem?
            if let carried = conflict.sourceItem {
                sourceItem = carried
            } else {
                sourceItem = try? await source.metadata(of: conflict.source)
            }
            var targetItem: VFSItem?
            if case .targetExists(let existing) = conflict.kind {
                if let existing {
                    targetItem = existing
                } else {
                    // A nil carried value (stale planner output) still gets a
                    // live fetch attempt.
                    targetItem = try? await destination.metadata(of: conflict.target)
                }
            } else {
                targetItem = try? await destination.metadata(of: conflict.target)
            }
            rows.append(ConflictPreviewRow(conflict: conflict, sourceItem: sourceItem, targetItem: targetItem))
        }
        return rows
    }

    /// Builds the executor policy from the dialog's per-row selections. The
    /// dialog's «apply to all» buttons set one choice for every row — it
    /// becomes the policy default (so runtime re-check conflicts get the same
    /// answer), and per-row overrides stay in the map when they differ
    /// (docs/SDD/05 §5.6 ConflictPolicy).
    public static func buildPolicy(
        rows: [ConflictPreviewRow],
        resolutions: [ConflictResolution],
        applyToAll: ConflictResolution?
    ) -> ConflictPolicy {
        precondition(rows.count == resolutions.count, "dialog state out of sync")
        var perTarget: [VFSPath: ConflictResolution] = [:]
        for (row, resolution) in zip(rows, resolutions) {
            guard case .targetExists = row.conflict.kind else { continue }   // only resolvable kinds
            if let applyAll = applyToAll, resolution == applyAll {
                continue   // covered by the default; keep the map minimal
            }
            perTarget[row.conflict.target] = resolution
        }
        return ConflictPolicy(
            defaultResolution: applyToAll ?? .keepBoth,
            perTargetPath: perTarget
        )
    }
}
