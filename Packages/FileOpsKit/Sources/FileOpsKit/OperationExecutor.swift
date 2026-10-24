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
        maxConcurrentItems: Int = 4
    ) {
        self.source = source
        self.destination = destination
        self.journal = journal
        self.events = events
        self.transportPreference = transportPreference
        self.maxConcurrentItems = max(1, maxConcurrentItems)
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
        await executeItems(plan, policy: policy, run: run)

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

    private func executeItem(
        _ planned: TransferItem,
        index: Int,
        plan: TransferPlan,
        policy: ConflictPolicy,
        runID: OperationID
    ) async {
        guard let run = runs[runID] else { return }
        // Conflict resolution (docs/SDD/05 §5.6): precomputed conflict wins;
        // otherwise a runtime re-check (06 §6.2 «runtime re-check still
        // happens» — targets may appear between planning and execution).
        var transfer = planned
        var conflict = plan.conflicts.first { $0.target == planned.target }
        if conflict == nil, let existing = try? await destination.metadata(of: planned.target) {
            conflict = Conflict(source: planned.source, target: planned.target, kind: .targetExists(existing: existing))
        }

        if let conflict {
            switch conflict.kind {
            case .insideSelfMove:
                await failItem(run, index: index, error: .vfsUnsupported(transfer.source.root, "target is inside the source tree"))
                return
            case .sourceVanished:
                await failItem(run, index: index, error: .vfsNotFound(transfer.source))
                return
            case .targetExists:
                switch policy.resolve(for: transfer.target) {
                case .overwrite:
                    do { try await destination.delete([transfer.target], toTrash: false) }
                    catch { await failItem(run, index: index, error: normalize(error)); return }
                case .skip:
                    run.summary.skippedItems += 1
                    emit(run, .itemDone)
                    return
                case .keepBoth:
                    transfer.target = await TransferPlanner.uniqueTargetName(for: transfer.target, in: destination)
                case .cancel:
                    run.summary.canceled = true
                    await cancel(runID)
                    return
                case .applyToAll:
                    break   // unwrapped by ConflictPolicy.resolve
                }
            }
        }

        do {
            try await CopyTransaction.run(
                transfer,
                source: source,
                destination: destination,
                preference: transportPreference,
                gate: run.gate,
                progress: { [weak self] fraction, bytes in
                    await self?.recordProgress(runID, index: index, fraction: fraction, bytes: bytes)
                }
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
