// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/05-DataModel-VFS.md §5.6 — the operations engine vocabulary.
// Planner/ConflictResolver/OperationExecutor are implemented in FileOpsKit
// (docs/SDD/06 §6.2); these models are their wire format.

public enum TransferOpKind: Codable, Sendable, Hashable {
    case copy
    case move
    case delete
    case link
}

/// One planned unit: the resolved source object (tree already expanded by Planner)
/// and its fully-computed destination path.
public struct TransferItem: Sendable {
    public var source: VFSPath
    public var target: VFSPath
    public var item: VFSItem

    public init(source: VFSPath, target: VFSPath, item: VFSItem) {
        self.source = source
        self.target = target
        self.item = item
    }
}

public struct Conflict: Sendable {
    public enum Kind: Sendable {
        /// Something occupies the target; resolved via overwrite/skip/keepBoth.
        case targetExists(existing: VFSItem?)
        /// Панель переносится в собственную подпапку — запрет (06 §6.2).
        case insideSelfMove
        /// Source disappeared between planning and execution.
        case sourceVanished
    }

    public var source: VFSPath
    public var target: VFSPath
    public var kind: Kind

    public init(source: VFSPath, target: VFSPath, kind: Kind) {
        self.source = source
        self.target = target
        self.kind = kind
    }
}

/// One UI answer. `applyToAll` wraps an underlying resolution («для всех»).
public indirect enum ConflictResolution: Sendable, Hashable {
    case overwrite
    case skip
    case keepBoth
    case cancel
    case applyToAll(ConflictResolution)
}

/// Default answer + per-target overrides chosen in the conflict dialog.
public struct ConflictPolicy: Sendable {
    public var defaultResolution: ConflictResolution
    public var perTargetPath: [VFSPath: ConflictResolution]

    public init(
        defaultResolution: ConflictResolution = .skip,
        perTargetPath: [VFSPath: ConflictResolution] = [:]
    ) {
        self.defaultResolution = defaultResolution
        self.perTargetPath = perTargetPath
    }

    /// Unwraps `applyToAll` chains towards the concrete resolution.
    public func resolve(for target: VFSPath) -> ConflictResolution {
        let chosen = perTargetPath[target] ?? defaultResolution
        switch chosen {
        case .applyToAll(let underlying): return underlying
        default: return chosen
        }
    }
}

public struct TransferPlan: Sendable {
    public var op: TransferOpKind
    public var items: [TransferItem]
    /// Precomputed at planning time (06 §6.2); runtime re-check still happens.
    public var conflicts: [Conflict]

    public init(op: TransferOpKind, items: [TransferItem], conflicts: [Conflict] = []) {
        self.op = op
        self.items = items
        self.conflicts = conflicts
    }
}

/// Aggregate of one finished (or canceled) operation — «finished(Summary)» §5.6.
public struct Summary: Sendable {
    public var startedItems: Int
    public var succeededItems: Int
    public var failedItems: Int
    public var skippedItems: Int
    public var bytesTransferred: Int64
    public var canceled: Bool

    public init(
        startedItems: Int = 0,
        succeededItems: Int = 0,
        failedItems: Int = 0,
        skippedItems: Int = 0,
        bytesTransferred: Int64 = 0,
        canceled: Bool = false
    ) {
        self.startedItems = startedItems
        self.succeededItems = succeededItems
        self.failedItems = failedItems
        self.skippedItems = skippedItems
        self.bytesTransferred = bytesTransferred
        self.canceled = canceled
    }
}

public struct TransferEvent: Sendable {
    public enum Phase: Sendable {
        case started
        case itemProgress(file: Double)
        case itemDone
        case itemFailed(MCError)
        case paused
        case resumed
        case finished(Summary)
    }

    public var phase: Phase
    public var queuePosition: Int
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(phase: Phase, queuePosition: Int, completedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.queuePosition = queuePosition
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Handle for pause/resume/cancel (§5.6 `pause(_ id:) / resume / cancel`).
public struct OperationID: Hashable, Sendable {
    public let value: UUID

    public init(value: UUID = UUID()) {
        self.value = value
    }
}

/// Undo: only reversal-operations are undoable (F-6); everything else reports
/// «undo недоступен». Fields carry VFSPath (now Codable) so records persist
/// into JournalStorage (FileOpsKit, T-10+).
public enum Reversal: Codable, Sendable, Hashable {
    /// Rename the object at `at` back to `previousName`.
    case renameBack(at: VFSPath, previousName: String)
    /// Move the trashed item at `trashURL` back to `original`.
    case restoreFromTrash(original: VFSPath, trashURL: URL)
    /// Delete the object we created (including leftover `.mc-partial` temps).
    case deleteCreated(path: VFSPath)
}

public struct JournalRecord: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var op: TransferOpKind
    public var reversals: [Reversal]

    public init(timestamp: Date, op: TransferOpKind, reversals: [Reversal]) {
        self.timestamp = timestamp
        self.op = op
        self.reversals = reversals
    }
}

/// docs/SDD/05 §5.6. Real implementation — `OperationExecutor` actor (FileOpsKit,
/// T-10): worker pool N=4, per-item transactions, pause semaphore, cancel via
/// `Task.cancel` + temp cleanup.
public protocol OperationExecutorProtocol: Actor {
    func enqueue(_ plan: TransferPlan, policy: ConflictPolicy) -> AsyncStream<TransferEvent>
    func pause(_ id: OperationID) async
    func resume(_ id: OperationID) async
    func cancel(_ id: OperationID) async
}
