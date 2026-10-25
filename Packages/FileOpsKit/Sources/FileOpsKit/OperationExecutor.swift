// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.2 layer 3 + docs/SDD/05 §5.6 OperationExecutorProtocol:
// worker pool (≤ 4 concurrent item transactions), per-item transactions, pause
// semaphore in the copy loop (≤ 500 ms reaction), cancel via Task.cancel +
// temp cleanup, per-item + aggregated progress, journal records for undo (F-6).

/// Pause primitive of one operation: the copy loop awaits it between chunks;
/// pause/resume/cancel react immediately regardless of chunk size (F-5).
public final class OperationGate: Sendable {
    private struct State {
        var paused = false
        var aborted = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let lock = NSLock()
    private nonisolated(unsafe) var state = State()

    public init() {}

    /// Blocks the loop until `resume()`/`abort()`.
    public func pause() {
        lock.lock()
        state.paused = true
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        state.paused = false
        let waiters = state.waiters
        state.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    /// Wake every paused waiter (cancellation is observed via Task.isCancelled
    /// right after the wait returns).
    public func abort() {
        lock.lock()
        state.aborted = true
        state.paused = false
        let waiters = state.waiters
        state.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    public func waitIfPaused() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !state.paused {
                lock.unlock()
                continuation.resume()
                return
            }
            state.waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// The operation executor (docs/SDD/05 §5.6). One instance serves one
/// source/destination VFS pair (both panels of MyCommander share the local
/// VFS; per-adapter executors arrive with the VFSRegistry task).
public actor OperationExecutor: OperationExecutorProtocol {
    private let source: any VFS
    private let destination: any VFS
    private let journal: JournalStorage
    private let events: TransferEvents?
    private let transportPreference: TransportPreference
    private let maxConcurrentItems: Int
    /// F-5 default: local deletes go to the Trash (F-5 «в корзину по умолчанию»).
    private let deleteToTrash: Bool
    /// Inter-chunk delay hook (T-11 tests make pause/cancel/resume timing
    /// deterministic without throttled VFS wrappers).
    private let chunkDelayNanoseconds: UInt64
    /// Volume identity for same-volume vs cross-volume decisions (T-11);
    /// `nil` = the default statfs provider.
    private let volumeKeyProvider: VolumeKeyProvider?

    /// Actor-confined run state (mutable only from within the actor).
    private final class Run {
        let id: OperationID
        let continuation: AsyncStream<TransferEvent>.Continuation
        let gate = OperationGate()
        let totalBytes: Int64
        var completedBytes: Int64 = 0
        var itemBytes: [Int: Int64] = [:]
        var summary = Summary()
        var task: Task<Void, Never>?
        /// Runtime re-check results gathered in ONE pass before any item
        /// executes (T-12 fix): a sibling's `ensureAncestors` materializing a
        /// parent directory mid-operation must not turn into a false «target
        /// exists» for that directory's own item.
        var runtimeConflicts: [VFSPath: Conflict] = [:]

        init(id: OperationID, continuation: AsyncStream<TransferEvent>.Continuation, totalBytes: Int64) {
            self.id = id
            self.continuation = continuation
            self.totalBytes = totalBytes
        }
    }

    private var runs: [OperationID: Run] = [:]

    public init(
        source: any VFS,
        destination: any VFS,
        journal: JournalStorage,
        events: TransferEvents? = nil,
        transportPreference: TransportPreference = .auto,
        maxConcurrentItems: Int = 4,
        deleteToTrash: Bool = true,
        chunkDelayNanoseconds: UInt64 = 0,
        volumeKeyProvider: VolumeKeyProvider? = nil
    ) {
        self.source = source
        self.destination = destination
        self.journal = journal
        self.events = events
        self.transportPreference = transportPreference
        self.maxConcurrentItems = max(1, maxConcurrentItems)
        self.deleteToTrash = deleteToTrash
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.volumeKeyProvider = volumeKeyProvider
    }

    // MARK: OperationExecutorProtocol

    public func enqueue(_ plan: TransferPlan, policy: ConflictPolicy) async -> (id: OperationID, events: AsyncStream<TransferEvent>) {
        let id = OperationID()
        var continuationRef: AsyncStream<TransferEvent>.Continuation!
        let stream = AsyncStream<TransferEvent> { continuation in
            continuationRef = continuation
        }
        let totalBytes = plan.items.reduce(0) { $0 + ($1.item.attributes.size ?? 0) }
        let run = Run(id: id, continuation: continuationRef, totalBytes: totalBytes)
        runs[id] = run
        run.task = Task {
            await perform(plan, policy: policy, run: run)
        }
        return (id, stream)
    }

    public func pause(_ id: OperationID) async {
        guard let run = runs[id] else { return }
        run.gate.pause()
        emit(run, .paused)
    }

    public func resume(_ id: OperationID) async {
        guard let run = runs[id] else { return }
        run.gate.resume()
        emit(run, .resumed)
    }

    public func cancel(_ id: OperationID) async {
        guard let run = runs[id] else { return }
        run.task?.cancel()
        run.gate.abort()   // unblock paused waiters; they observe cancellation
    }

    // MARK: run loop

    private func perform(_ plan: TransferPlan, policy: ConflictPolicy, run: Run) async {
        emit(run, .started)
        switch plan.op {
        case .copy:
            await executeItems(plan, policy: policy, run: run)
        case .move:
            await executeMove(plan, policy: policy, run: run)
        case .delete:
            await executeDelete(plan, policy: policy, run: run)
        case .link:
            // Hard/symbolic link operations arrive with a later task; every
            // item fails visibly instead of silently copying (§5.6 .link).
            for index in plan.items.indices {
                await failItem(run, index: index, error: .vfsUnsupported(plan.items[index].source.root, "link operations are not implemented yet"))
            }
        }

        run.summary.canceled = Task.isCancelled || run.summary.canceled
        run.summary.bytesTransferred = run.completedBytes
        emit(run, .finished(run.summary))
        run.continuation.finish()
        runs[run.id] = nil
    }

    /// Windowed worker pool: at most `maxConcurrentItems` item transactions in
    /// flight; the FIFO order of *starts* is preserved (docs/SDD/06 §6.2).
    private func executeItems(_ plan: TransferPlan, policy: ConflictPolicy, run: Run) async {
        let runID = run.id
        // Runtime re-check pass BEFORE any item mutates the destination
        // (06 §6.2 «runtime re-check still happens» — targets may appear
        // between planning and execution).
        for item in plan.items {
            if let existing = try? await destination.metadata(of: item.target) {
                run.runtimeConflicts[item.target] = Conflict(
                    source: item.source,
                    target: item.target,
                    kind: .targetExists(existing: existing),
                    sourceItem: item.item
                )
            }
        }
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            func spawnNext() {
                guard next < plan.items.count else { return }
                let index = next
                next += 1
                group.addTask {
                    await self.executeItem(plan.items[index], index: index, plan: plan, policy: policy, runID: runID)
                }
            }
            for _ in 0 ..< min(maxConcurrentItems, plan.items.count) {
                spawnNext()
            }
            while let _ = await group.next() {
                if Task.isCancelled { break }
                spawnNext()
            }
            group.cancelAll()
        }
    }

    // MARK: move (T-11)

    /// Move = rename(2) vs copy+delete, decided per top-level item by the
    /// MoveTransaction. Only top-level entries are executed: a same-volume
    /// rename subsumes its whole subtree (descendants would fail with ENOENT
    /// after the parent moved); cross-volume directories recurse internally
    /// (mkdir staging + per-child copy+delete, deepest-first source cleanup).
    private func executeMove(_ plan: TransferPlan, policy: ConflictPolicy, run: Run) async {
        let topLevel = Self.topLevelIndices(of: plan.items)
        // Same single-pass runtime re-check as the copy path (T-12).
        for index in topLevel {
            let item = plan.items[index]
            if let existing = try? await destination.metadata(of: item.target) {
                run.runtimeConflicts[item.target] = Conflict(
                    source: item.source,
                    target: item.target,
                    kind: .targetExists(existing: existing),
                    sourceItem: item.item
                )
            }
        }
        let runID = run.id
        await runPool(indices: topLevel) { [weak self] index in
            await self?.executeMoveItem(plan.items[index], index: index, plan: plan, policy: policy, runID: runID)
        }
        // Planner conflicts without an item (insideSelfMove refuses the whole
        // source at planning time) surface as failed items (06 §6.2).
        let itemSources = Set(plan.items.map(\.source))
        for conflict in plan.conflicts where !itemSources.contains(conflict.target) {
            if case .insideSelfMove = conflict.kind {
                await failItem(run, index: -1, error: .vfsUnsupported(conflict.source.root, "target is inside the source tree"))
            } else {
                await failItem(run, index: -1, error: .vfsNotFound(conflict.source))
            }
        }
    }

    private func executeMoveItem(
        _ planned: TransferItem,
        index: Int,
        plan: TransferPlan,
        policy: ConflictPolicy,
        runID: OperationID
    ) async {
        guard let transfer = await resolveConflicts(planned, index: index, plan: plan, policy: policy, runID: runID), let run = runs[runID] else { return }

        do {
            let outcome = try await MoveTransaction.run(
                transfer,
                source: source,
                destination: destination,
                gate: run.gate,
                progress: { [weak self] fraction, bytes in
                    await self?.recordProgress(runID, index: index, fraction: fraction, bytes: bytes)
                },
                volumeKey: volumeKeyProvider,
                chunkDelay: chunkDelayNanoseconds
            )
            run.summary.startedItems += 1
            run.summary.succeededItems += 1

            let movedBytes: Int64
            switch outcome {
            case .renamed:
                movedBytes = transfer.item.attributes.size ?? 0
                journal.append(JournalRecord(
                    timestamp: Date(),
                    op: .move,
                    reversals: [.renameBack(at: transfer.target, previousName: transfer.source.components.last ?? "")]
                ))
            case .movedCrossVolume(let files, let bytes):
                movedBytes = bytes
                _ = files
                // Undo granularity v1: the created target subtree is deletable;
                // a full «move back» reversal plan arrives with F-6.
                journal.append(JournalRecord(
                    timestamp: Date(),
                    op: .move,
                    reversals: [.deleteCreated(path: transfer.target)]
                ))
            }
            recordBytes(run.id, index: index, bytes: movedBytes)
            emit(run, .itemDone)
        } catch is CancellationError {
            run.summary.startedItems += 1
            run.summary.failedItems += 1
            run.summary.canceled = true
            emit(run, .itemFailed(.canceled))
        } catch let error as MCError {
            await failItem(run, index: index, error: error)
        } catch {
            await failItem(run, index: index, error: .unexpected(underlying: error))
        }
    }

    // MARK: delete (T-11)

    /// Delete: local → trash (reversible) or bottom-up permanent walk;
    /// other adapters delegate to `VFS.delete`. Items are top-level paths —
    /// trees are handled inside one transaction.
    private func executeDelete(_ plan: TransferPlan, policy: ConflictPolicy, run: Run) async {
        let indices = Array(plan.items.indices)
        let runID = run.id
        await runPool(indices: indices) { [weak self] index in
            await self?.executeDeleteItem(plan.items[index], index: index, plan: plan, policy: policy, runID: runID)
        }
        // Planner-recorded vanished sources have no item to hang the failure
        // on (planDelete stores no VFSItem for them) — surface them as failed
        // items so the summary reports the loss honestly (08 §8.3).
        let itemSources = Set(plan.items.map(\.source))
        for conflict in plan.conflicts where !itemSources.contains(conflict.target) {
            await failItem(run, index: -1, error: .vfsNotFound(conflict.target))
        }
    }

    private func executeDeleteItem(
        _ planned: TransferItem,
        index: Int,
        plan: TransferPlan,
        policy: ConflictPolicy,
        runID: OperationID
    ) async {
        guard let transfer = await resolveConflicts(planned, index: index, plan: plan, policy: policy, runID: runID), let run = runs[runID] else { return }

        do {
            let outcome = try await DeleteTransaction.run(
                transfer,
                source: source,
                toTrash: deleteToTrash,
                gate: run.gate,
                progress: { [weak self] _, bytes in
                    await self?.recordProgress(runID, index: index, fraction: 0, bytes: bytes)
                }
            )
            run.summary.startedItems += 1
            run.summary.succeededItems += 1

            let freedBytes: Int64
            switch outcome {
            case .trashed(let trashURL, let files, let bytes):
                freedBytes = bytes
                _ = files
                journal.append(JournalRecord(
                    timestamp: Date(),
                    op: .delete,
                    reversals: [.restoreFromTrash(original: transfer.source, trashURL: trashURL)]
                ))
            case .removed(let files, let bytes):
                freedBytes = bytes
                _ = files
                // A permanent delete is not reversible — no journal reversals.
                journal.append(JournalRecord(timestamp: Date(), op: .delete, reversals: []))
            }
            recordBytes(run.id, index: index, bytes: freedBytes)
            emit(run, .itemDone)
        } catch is CancellationError {
            run.summary.startedItems += 1
            run.summary.failedItems += 1
            run.summary.canceled = true
            emit(run, .itemFailed(.canceled))
        } catch let error as MCError {
            await failItem(run, index: index, error: error)
        } catch {
            await failItem(run, index: index, error: .unexpected(underlying: error))
        }
    }

    /// Shared conflict resolution (docs/SDD/05 §5.6): the precomputed conflict
    /// wins; otherwise a runtime re-check — for copy/move the *target* is
    /// stat'ed (06 §6.2 «runtime re-check still happens»), for delete the
    /// *source* (a vanished source fails the item). Returns the transfer to
    /// execute, or `nil` when the conflict path already accounted for the item
    /// (skip / fail / cancel).
    private func resolveConflicts(
        _ planned: TransferItem,
        index: Int,
        plan: TransferPlan,
        policy: ConflictPolicy,
        runID: OperationID
    ) async -> TransferItem? {
        guard let run = runs[runID] else { return nil }
        var transfer = planned
        var conflict = plan.conflicts.first { $0.target == planned.target }
            ?? run.runtimeConflicts[planned.target]
        if conflict == nil, plan.op == .delete {
            // The source may have vanished between planning and execution.
            if (try? await source.metadata(of: planned.source)) == nil {
                conflict = Conflict(source: planned.source, target: planned.target, kind: .sourceVanished)
            }
        }

        if let conflict {
            switch conflict.kind {
            case .insideSelfMove:
                await failItem(run, index: index, error: .vfsUnsupported(transfer.source.root, "target is inside the source tree"))
                return nil
            case .sourceVanished:
                await failItem(run, index: index, error: .vfsNotFound(transfer.source))
                return nil
            case .targetExists:
                switch policy.resolve(for: transfer.target) {
                case .overwrite:
                    do { try await destination.delete([transfer.target], toTrash: false) }
                    catch { await failItem(run, index: index, error: normalize(error)); return nil }
                case .skip:
                    run.summary.startedItems += 1
                    run.summary.skippedItems += 1
                    emit(run, .itemDone)
                    return nil
                case .keepBoth:
                    transfer.target = await TransferPlanner.uniqueTargetName(for: transfer.target, in: destination)
                case .cancel:
                    run.summary.canceled = true
                    await cancel(run.id)
                    return nil
                case .applyToAll:
                    break   // unwrapped by ConflictPolicy.resolve
                }
            }
        }
        return transfer
    }

    /// Items whose source has no ancestor directory among the plan's sources —
    /// the renameable «roots» of a move; descendants are subsumed.
    private static func topLevelIndices(of items: [TransferItem]) -> [Int] {
        var roots: [Int] = []
        for (index, item) in items.enumerated() {
            let isDescendant = items.contains { other in
                guard case .directory = other.item.kind else { return false }
                return other.source.root == item.source.root
                    && other.source.components.count < item.source.components.count
                    && Array(item.source.components.prefix(other.source.components.count)) == other.source.components
            }
            if !isDescendant { roots.append(index) }
        }
        return roots
    }

    /// Windowed worker pool over explicit indices (shared by copy/move/delete).
    private func runPool(indices: [Int], _ body: @escaping @Sendable (Int) async -> Void) async {
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            func spawnNext() {
                guard next < indices.count else { return }
                let index = indices[next]
                next += 1
                group.addTask { await body(index) }
            }
            for _ in 0 ..< min(maxConcurrentItems, indices.count) {
                spawnNext()
            }
            while let _ = await group.next() {
                if Task.isCancelled { break }
                spawnNext()
            }
            group.cancelAll()
        }
    }

    private func executeItem(
        _ planned: TransferItem,
        index: Int,
        plan: TransferPlan,
        policy: ConflictPolicy,
        runID: OperationID
    ) async {
        guard let run = runs[runID], let transfer = await resolveConflicts(planned, index: index, plan: plan, policy: policy, runID: runID) else { return }

        do {
            try await CopyTransaction.run(
                transfer,
                source: source,
                destination: destination,
                preference: transportPreference,
                gate: run.gate,
                progress: { [weak self] fraction, bytes in
                    await self?.recordProgress(runID, index: index, fraction: fraction, bytes: bytes)
                },
                volumeKey: volumeKeyProvider,
                chunkDelay: chunkDelayNanoseconds
            )
            run.summary.startedItems += 1
            run.summary.succeededItems += 1
            run.itemBytes[index] = transfer.item.attributes.size ?? 0
            run.completedBytes = run.itemBytes.values.reduce(0, +)
            journal.append(JournalRecord(
                timestamp: Date(),
                op: plan.op,
                reversals: [.deleteCreated(path: transfer.target)]
            ))
            emit(run, .itemDone)
        } catch is CancellationError {
            run.summary.failedItems += 1
            run.summary.canceled = true
            emit(run, .itemFailed(.canceled))
        } catch let error as MCError {
            await failItem(run, index: index, error: error)
        } catch {
            await failItem(run, index: index, error: .unexpected(underlying: error))
        }
    }

    private func failItem(_ run: Run, index: Int, error: MCError) async {
        run.summary.startedItems += 1
        run.summary.failedItems += 1
        emit(run, .itemFailed(error))
    }

    private func recordProgress(_ id: OperationID, index: Int, fraction: Double, bytes: Int64) {
        guard let run = runs[id] else { return }
        let previous = run.itemBytes[index] ?? 0
        if bytes > previous {
            run.completedBytes += bytes - previous
        }
        run.itemBytes[index] = bytes
        emit(run, .itemProgress(file: fraction))
    }

    /// Byte accounting without an event (the transaction total, committed at
    /// item completion — move/delete report totals rather than fractions).
    private func recordBytes(_ id: OperationID, index: Int, bytes: Int64) {
        guard let run = runs[id] else { return }
        let previous = run.itemBytes[index] ?? 0
        if bytes > previous {
            run.completedBytes += bytes - previous
        }
        run.itemBytes[index] = bytes
    }

    private func emit(_ run: Run, _ phase: TransferEvent.Phase) {
        let event = TransferEvent(
            phase: phase,
            queuePosition: 0,
            completedBytes: run.completedBytes,
            totalBytes: run.totalBytes
        )
        run.continuation.yield(event)
        events?.emit(run.id, event)
    }

    private func normalize(_ error: Error) -> MCError {
        error as? MCError ?? .unexpected(underlying: error)
    }
}
