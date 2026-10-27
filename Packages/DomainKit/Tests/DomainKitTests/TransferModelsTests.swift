// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DomainKit

// TransferModels (05 §5.6): wire-format locks. JournalRecord persists into
// JournalStorage (FileOpsKit T-10+), so Reversal/VFSPath/op must survive JSON.

private let instance = VFSInstanceID(kind: .localDisk, specID: "journal-test")

@Test func journalRecordRoundTripsThroughJSON() throws {
    let record = JournalRecord(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        op: .move,
        reversals: [
            .renameBack(at: VFSPath(root: instance, components: ["docs"]), previousName: "old.txt"),
            .restoreFromTrash(
                original: VFSPath(root: instance, components: ["bin"]),
                trashURL: URL(fileURLWithPath: "/tmp/mc-trash/x.bin")
            ),
            .deleteCreated(path: VFSPath(root: instance, components: ["staged", ".a.mc-partial"]))
        ]
    )

    let decoded = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
    #expect(record.reversals.count == 3)
}

@Test func journalOpKindRoundTripsEveryVariant() throws {
    for op in [TransferOpKind.copy, .move, .delete, .link] {
        let decoded = try JSONDecoder().decode(TransferOpKind.self, from: JSONEncoder().encode(op))
        #expect(decoded == op)
    }
}

@Test func conflictPolicyUnwrapsApplyToAllChains() {
    let target = VFSPath(root: instance, components: ["occupied.txt"])
    let policy = ConflictPolicy(
        defaultResolution: .keepBoth,
        perTargetPath: [target: .applyToAll(.overwrite)]
    )
    #expect(policy.resolve(for: target) == .overwrite)
    #expect(policy.resolve(for: VFSPath(root: instance, components: ["other.txt"])) == .keepBoth)
}

@Test func executorIDAndEventModelStayPlain() {
    let id = OperationID()
    #expect(OperationID() != id)   // fresh UUID per instance

    let summary = Summary(startedItems: 4, succeededItems: 3, failedItems: 1, bytesTransferred: 256)
    let event = TransferEvent(phase: .finished(summary), queuePosition: 2, completedBytes: 256, totalBytes: 300)
    #expect(event.completedBytes == 256)
    if case .finished(let record) = event.phase {
        #expect(record.succeededItems == 3)
        #expect(record.failedItems == 1)
    } else {
        Issue.record("expected finished phase")
    }
}
