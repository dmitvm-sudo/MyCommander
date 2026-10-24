// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import DomainKit

// T-06 (docs/SDD/06 §6.1, «Уточнение T-05» +5): diff batching for the panel
// table. Positions carry new-table semantics: `inserted`/`updated` index the NEW
// order, `removed` indexes the OLD order — callers apply beginUpdates → remove
// → insert → reload → endUpdates exactly in that sequence.

/// Row-level change set between two listings (visible order).
public struct FileListDelta: Sendable, Equatable {
    public var inserted: [Int]
    public var removed: [Int]
    public var updated: [Int]
    public var oldCount: Int
    public var newCount: Int

    public init(inserted: [Int] = [], removed: [Int] = [], updated: [Int] = [], oldCount: Int = 0, newCount: Int = 0) {
        self.inserted = inserted
        self.removed = removed
        self.updated = updated
        self.oldCount = oldCount
        self.newCount = newCount
    }

    public var isEmpty: Bool {
        inserted.isEmpty && removed.isEmpty && updated.isEmpty
    }

    /// Validates against a stale table state: if the row count drifted from the
    /// recorded old snapshot, the batch cannot apply (the view reloads instead).
    public func isValidAgainst(rowCount: Int) -> Bool {
        rowCount == oldCount
    }
}

/// Pure, allocation-frugal diff (O(n)): identity dictionary + one equivalence
/// comparison per kept row. Gate: ≤ 100 ms on 50k rows / 100 changed (N-1/F-1).
public enum DiffUpdate {
    public static func diff(old: [VFSItem], new: [VFSItem]) -> FileListDelta {
        var oldIndexByID: [VFSPath: Int] = [:]
        oldIndexByID.reserveCapacity(old.count)
        for (index, item) in old.enumerated() where oldIndexByID[item.id] == nil {
            oldIndexByID[item.id] = index
        }

        var newIndexByID: [VFSPath: Int] = [:]
        newIndexByID.reserveCapacity(new.count)
        var inserted: [Int] = []
        var updated: [Int] = []
        inserted.reserveCapacity(new.count / 8)
        for (index, item) in new.enumerated() {
            guard newIndexByID[item.id] == nil else { continue }
            newIndexByID[item.id] = index
            if let oldIndex = oldIndexByID[item.id] {
                if !old[oldIndex].isContentEquivalent(to: item) {
                    updated.append(index)
                }
            } else {
                inserted.append(index)
            }
        }

        var removed: [Int] = []
        for (index, item) in old.enumerated() where newIndexByID[item.id] == nil {
            removed.append(index)
        }

        return FileListDelta(
            inserted: inserted,
            removed: removed,
            updated: updated,
            oldCount: old.count,
            newCount: new.count
        )
    }
}
