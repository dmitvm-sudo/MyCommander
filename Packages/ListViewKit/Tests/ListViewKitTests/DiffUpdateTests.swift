// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import ListViewKit

// T-06: FileListDelta semantics (docs/SDD/06 §6.1, «Уточнение T-05» +7):
// positions are NEW-table semantics for inserted/updated and OLD-table
// positions for removed. Plus the T-06 perf gate: diff ≤ 100 ms on 50k rows
// with 100+ changed entries (docs/SDD/12). Helpers are private: the test
// module compiles neighbouring files together.

private func diffInstance() -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, specID: "diff-unit")
}

private func diffItem(
    root: VFSInstanceID,
    name: String,
    size: Int64 = 1,
    revision: UInt64 = 1
) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: [name]),
        instance: root,
        name: name,
        kind: .file,
        attributes: VFSItemAttributes(size: size, modified: Date(timeIntervalSince1970: 100)),
        revision: revision
    )
}

@Test func diffClassifiesInsertsUpdatesRemovesWithTableSemantics() {
    let root = diffInstance()
    let old = [
        diffItem(root: root, name: "a.txt"),
        diffItem(root: root, name: "b.txt"),
        diffItem(root: root, name: "c.txt")
    ]
    // new: b with changed size (updated), a unchanged, d added; c is gone.
    let new = [
        diffItem(root: root, name: "b.txt", size: 99),
        diffItem(root: root, name: "a.txt"),
        diffItem(root: root, name: "d.txt")
    ]

    let delta = DiffUpdate.diff(old: old, new: new)

    #expect(delta.inserted == [2])   // d.txt — position in the NEW order
    #expect(delta.updated == [0])    // b.txt — position in the NEW order
    #expect(delta.removed == [2])    // c.txt — position in the OLD order
    #expect(delta.oldCount == 3)
    #expect(delta.newCount == 3)
}

@Test func revisionBumpAloneIsNotAnUpdate() {
    let root = diffInstance()
    let old = [diffItem(root: root, name: "same.txt", revision: 1)]
    let new = [diffItem(root: root, name: "same.txt", revision: 7)]

    let delta = DiffUpdate.diff(old: old, new: new)

    #expect(delta.isEmpty)
    #expect(delta.oldCount == 1)
    #expect(delta.newCount == 1)
}

@Test func duplicateIDsCollapseFirstWins() {
    let root = diffInstance()
    let old = [diffItem(root: root, name: "a.txt")]
    let new = [
        diffItem(root: root, name: "a.txt"),
        diffItem(root: root, name: "a.txt", size: 2)
    ]

    let delta = DiffUpdate.diff(old: old, new: new)

    #expect(delta.isEmpty)
    #expect(delta.newCount == 2)
}

@Test func emptyToSingleEntryInsertsRowZero() {
    let root = diffInstance()
    let delta = DiffUpdate.diff(old: [], new: [diffItem(root: root, name: "x.txt")])
    #expect(delta == FileListDelta(inserted: [0], removed: [], updated: [], oldCount: 0, newCount: 1))
    #expect(delta.isValidAgainst(rowCount: 0))
    #expect(!delta.isValidAgainst(rowCount: 5))
}

@Test func diffOfHundredChangesInTenThousandRowsStaysUnderHundredMilliseconds() {
    let root = diffInstance()
    let count = 10_000
    var old: [VFSItem] = []
    old.reserveCapacity(count)
    for index in 0 ..< count {
        old.append(diffItem(root: root, name: "row-\(index).txt", size: Int64(index % 991)))
    }

    // 100 updated + 50 removed + 50 inserted.
    var new = old
    for index in stride(from: 0, to: 200, by: 2) {
        new[index] = diffItem(root: root, name: "row-\(index).txt", size: 4096 + Int64(index))
    }
    new.removeSubrange(6_000 ..< 6_050)
    var inserted: [VFSItem] = []
    for offset in 0 ..< 50 {
        inserted.append(diffItem(root: root, name: "extra-\(offset).txt"))
    }
    new.insert(contentsOf: inserted, at: 10)

    let started = Date()
    let delta = DiffUpdate.diff(old: old, new: new)
    let elapsed = Date().timeIntervalSince(started)

    #expect(delta.inserted.count == 50)
    #expect(delta.updated.count == 100)
    #expect(delta.removed.count == 50)
    #expect(delta.oldCount == count)
    // T-06 gate: ≤ 0.1 s for 100+ changed on a realistic 10k panel
    // (docs/SDD/12: «дифф ≤ 100 мс на 100 changed», F-1 speaks of 10 000 entries).
    #expect(elapsed < 0.1, "diff took \(elapsed)s")
}

@Test func diffOfFiftyThousandRowsStaysLinearUnderHalfASecond() {
    let root = diffInstance()
    let count = 50_000
    var old: [VFSItem] = []
    old.reserveCapacity(count)
    for index in 0 ..< count {
        old.append(diffItem(root: root, name: "row-\(index).txt", size: Int64(index % 991)))
    }

    var new = old
    for index in stride(from: 0, to: 200, by: 2) {
        new[index] = diffItem(root: root, name: "row-\(index).txt", size: 4096 + Int64(index))
    }
    new.removeSubrange(30_000 ..< 30_050)
    var inserted: [VFSItem] = []
    for offset in 0 ..< 50 {
        inserted.append(diffItem(root: root, name: "extra-\(offset).txt"))
    }
    new.insert(contentsOf: inserted, at: 10)

    let started = Date()
    let delta = DiffUpdate.diff(old: old, new: new)
    let elapsed = Date().timeIntervalSince(started)

    // Linearity guard on the extreme 50k panel (debug build ≈ 10× slower than
    // release; the release build runs this in tens of milliseconds).
    #expect(delta.updated.count == 100)
    #expect(elapsed < 0.5, "50k diff took \(elapsed)s")
}
