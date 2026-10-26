// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
@testable import ListViewKit

// T-34 (M3 hardening, F-14): the dialog layer above the pure planner —
// 100-name preview, foreign-name conflicts disable Apply and render red
// (F-14 acceptance), and the dry run (Apply click) builds the `.move`
// TransferPlan without a single disk operation. Headless like every
// ListViewKit window test; smoke 8.4 п.8 visual part stays manual
// (T-27/T-31 precedent). Helpers carry the `mrn` name-space (the test
// module compiles neighbouring files together).

private func mrnItem(_ name: String, isDirectory: Bool = false) -> VFSItem {
    let root = VFSInstanceID(kind: .localDisk, specID: "mrn-tests")
    let path = VFSPath(root: root, components: name.isEmpty ? [] : [name])
    return VFSItem(
        id: path,
        instance: root,
        name: name,
        kind: isDirectory ? .directory : .file,
        attributes: VFSItemAttributes(
            size: 10, created: nil, modified: nil, posixPermissions: nil,
            owner: nil, group: nil, isHidden: false, isReadOnly: false, tags: [], urlResourceMeta: [:]
        )
    )
}

@MainActor
@Test func mrnPreviewBuildsHundredPairsAndEnablesApply() {
    let items = (0 ..< 100).map { mrnItem("file-\($0).txt") }
    let dialog = MultiRenameDialogController(items: items, occupiedNames: Set(items.map(\.name)))
    dialog.templateField.stringValue = "photo_[C].[E]"
    dialog.refreshPreview()

    #expect(dialog.numberOfRows(in: dialog.table) == 100)
    #expect(dialog.applyButton.isEnabled)
    // The dry run has not committed anything yet.
    #expect(dialog.applyResult == nil)
}

@MainActor
@Test func mrnForeignConflictsDisableApplyAndRenderRed() throws {
    // 5 of the 100 new names land on foreign occupied names (doc_1.txt …
    // doc_5.txt — .keep preserves the original suffix) → targetExists,
    // Apply disabled, EXACTLY those five rows render red in the «new»
    // column.
    let items = (0 ..< 100).map { mrnItem("file-\($0).txt") }
    let occupied = Set(items.map(\.name) + (1 ... 5).map { "doc_\($0).txt" })
    let dialog = MultiRenameDialogController(items: items, occupiedNames: occupied)
    dialog.templateField.stringValue = "doc_[C]"
    dialog.refreshPreview()

    #expect(dialog.plan.pairs.count == 100)
    #expect(dialog.plan.conflicts.count == 5)
    #expect(dialog.plan.conflicts.allSatisfy { if case .targetExists = $0.kind { return true }; return false })
    #expect(!dialog.applyButton.isEnabled)

    let newColumn = try #require(dialog.table.tableColumns.first { $0.identifier.rawValue == "new" })
    for row in 0 ..< dialog.plan.pairs.count {
        let cell = try #require(dialog.tableView(dialog.table, viewFor: newColumn, row: row) as? NSTextField)
        // The counter starts at 1: rows 0…4 produce doc_1…doc_5 (taken).
        let expectedRed = (1 ... 5).contains(row + 1)
        #expect(cell.textColor == (expectedRed ? NSColor.systemRed : NSColor.labelColor))
    }
}

@MainActor
@Test func mrnUnchangedBaselineDisablesApplyAndCancelKeepsResultNil() {
    let items = [mrnItem("a.txt"), mrnItem("b.txt")]
    let dialog = MultiRenameDialogController(items: items, occupiedNames: ["a.txt", "b.txt"])
    // The literal default «[N]» renames everything to itself → planned
    // nothing, Apply disabled (unchanged names are never planned, T-28).
    #expect(dialog.plan.pairs.isEmpty)
    #expect(!dialog.applyButton.isEnabled)

    dialog.templateField.stringValue = "renamed_[C]"
    dialog.refreshPreview()
    #expect(dialog.applyButton.isEnabled)

    dialog.cancelClicked()
    #expect(dialog.applyResult == nil)
}

@MainActor
@Test func mrnDryRunApplyBuildsMovePlanWithoutDiskWrites() throws {
    let items = [mrnItem("a.txt"), mrnItem("b.txt")]
    let dialog = MultiRenameDialogController(items: items, occupiedNames: ["a.txt", "b.txt"])
    dialog.templateField.stringValue = "renamed_[C]"
    dialog.refreshPreview()

    dialog.applyClicked()
    let transfer = try #require(dialog.applyResult)
    #expect(transfer.op == .move)
    #expect(transfer.items.count == 2)
    #expect(transfer.conflicts.isEmpty)
    // Counters follow the selection order; the plan targets the clicked
    // panel's parent (an empty-components root here; execution sorts the
    // pairs stable by old name, 06 §6.6).
    #expect(transfer.items[0].source.components.last == "a.txt")
    #expect(transfer.items[0].target.components == ["renamed_1.txt"])   // [E] keeps «txt»
    #expect(transfer.items[1].target.components == ["renamed_2.txt"])
    // The dry run is pure planning: the «mrn-tests» root never exists on
    // disk and no VFS engine was invoked — nothing to stat, nothing was
    // written. The commit itself rides the unified queue (App-side).
}
