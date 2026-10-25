// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.2 «Journal» — every committed change appends a
// JournalRecord (§5.6) to a ring buffer (20 entries); undo replays the reverse
// plan through the same OperationExecutor (F-6, later task).

/// Ring buffer of undo records. Thread-safe: executor worker tasks append
/// concurrently.
public final class JournalStorage: @unchecked Sendable {
    private let capacity: Int
    private final class Box {
        let lock = NSLock()
        var records: [JournalRecord] = []
    }
    private let box = Box()

    public init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    public func append(_ record: JournalRecord) {
        box.lock.lock()
        box.records.append(record)
        if box.records.count > capacity {
            box.records.removeFirst(box.records.count - capacity)
        }
        box.lock.unlock()
    }

    /// Oldest-last snapshot (for the undo stack UI, F-6).
    public func recent() -> [JournalRecord] {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.records
    }

    /// Undo semantics (T-20/F-6): take the newest record out of the ring.
    /// Returns `nil` on an empty journal. A failed undo re-appends the record
    /// at the top (App side), so the next ⌘Z retries it or moves on.
    public func popLast() -> JournalRecord? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.records.popLast()
    }

    public func clear() {
        box.lock.lock()
        box.records.removeAll()
        box.lock.unlock()
    }
}
