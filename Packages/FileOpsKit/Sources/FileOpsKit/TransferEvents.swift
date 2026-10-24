// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/11 «TransferEvents.swift — public AsyncStream-канал
// прогресса»: app-wide fan-out of every operation's events, consumed by the
// progress window (F-5: «окно можно закрыть — операция живёт»).

/// Progress hub: the executor emits into it; any number of UI subscribers
/// observe the merged stream. Replays nothing — subscribers see live traffic
/// only (the per-operation AsyncStream from `enqueue` remains the source of
/// truth for a single window).
public final class TransferEvents: @unchecked Sendable {
    public typealias Entry = (operation: OperationID, event: TransferEvent)

    private final class Box {
        let lock = NSLock()
        var continuations: [UUID: AsyncStream<Entry>.Continuation] = [:]
    }
    private let box = Box()

    public init() {}

    /// Live feed of all operations. Cancel the iteration (or drop the stream)
    /// to unsubscribe.
    public func subscribe() -> AsyncStream<Entry> {
        let id = UUID()
        let stream = AsyncStream<Entry> { continuation in
            box.lock.lock()
            box.continuations[id] = continuation
            box.lock.unlock()
        }
        return stream
    }

    internal func emit(_ operation: OperationID, _ event: TransferEvent) {
        box.lock.lock()
        let continuations = Array(box.continuations.values)
        box.lock.unlock()
        for continuation in continuations {
            continuation.yield((operation, event))
        }
    }
}
