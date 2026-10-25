// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import FileOpsKit
@testable import ListViewKit

// T-12: the dialog's decision logic (policy building) and the finish report
// accumulator — pure parts, testable without a running modal loop. Helpers
// are file-private with the `cd` name-space (the test module compiles
// neighbouring files together).

private func cdItem(_ name: String, root: VFSInstanceID) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: ["box", name]),
        instance: root,
        name: name,
        kind: .file,
        attributes: VFSItemAttributes(size: 10, modified: Date(timeIntervalSince1970: 1_700_000_000))
    )
}

private func cdRow(_ name: String, root: VFSInstanceID, target: VFSItem?) -> ConflictPreviewRow {
    let item = cdItem(name, root: root)
    return ConflictPreviewRow(
        conflict: Conflict(
            source: VFSPath(root: root, components: ["src", name]),
            target: VFSPath(root: root, components: ["box", name]),
            kind: .targetExists(existing: target),
            sourceItem: item
        ),
        sourceItem: item,
        targetItem: target
    )
}

@MainActor
@Test func conflictDialogBuildsPolicyFromSelections() async throws {
    let root = VFSInstanceID(kind: .localDisk, specID: "cd-dialog")
    let rows = [cdRow("a.txt", root: root, target: cdItem("a.txt", root: root)),
                cdRow("b.txt", root: root, target: cdItem("b.txt", root: root))]

    // Defaults: every row keeps both, no «apply to all» — the policy keeps
    // runtime re-checks safe too.
    let dialog = ConflictDialogController(rows: rows)
    let defaults = dialog.buildPolicy()
    #expect(defaults.defaultResolution == .keepBoth)
    #expect(defaults.perTargetPath.count == 2)

    // «Overwrite all»: becomes the default, identical rows stay out of the map.
    dialog.applyAll(.overwrite)
    let allOverwrite = dialog.buildPolicy()
    #expect(allOverwrite.defaultResolution == .overwrite)
    #expect(allOverwrite.perTargetPath.isEmpty)
}

@MainActor
@Test func operationReportAccumulatesOkSkipFailAndReasons() {
    var report = OperationReport()

    let root = VFSInstanceID(kind: .localDisk, specID: "cd-report")
    let targetPath = VFSPath(root: root, components: ["box", "x.txt"])
    // Two failures (with real MCError reasons), one skip, then the finish
    // summary counts the successes.
    report.record(TransferEvent(phase: .itemFailed(.vfsAccessDenied(targetPath, underlying: nil)), queuePosition: 0, completedBytes: 0, totalBytes: 100))
    report.record(TransferEvent(phase: .itemDone, queuePosition: 0, completedBytes: 10, totalBytes: 100))
    report.record(TransferEvent(phase: .itemFailed(.vfsNotFound(targetPath)), queuePosition: 0, completedBytes: 10, totalBytes: 100))
    report.record(TransferEvent(phase: .finished(Summary(
        startedItems: 5, succeededItems: 3, failedItems: 2, skippedItems: 1,
        bytesTransferred: 100, canceled: false
    )), queuePosition: 0, completedBytes: 100, totalBytes: 100))

    #expect(report.succeeded == 3)
    #expect(report.skipped == 1)
    #expect(report.failed == 2)
    #expect(report.canceled == false)
    #expect(report.reasons.count == 2)
    #expect(report.reasons[0].contains("access denied") || !report.reasons[0].isEmpty)

    // Cancellation is visible in the report (F-5 отмена).
    var canceledReport = OperationReport()
    canceledReport.record(TransferEvent(phase: .finished(Summary(canceled: true)), queuePosition: 0, completedBytes: 0, totalBytes: 0))
    #expect(canceledReport.canceled)
}

@MainActor
@Test func conflictPreviewTextFormatsSizeAndDate() {
    let root = VFSInstanceID(kind: .localDisk, specID: "cd-preview")
    var item = cdItem("doc.bin", root: root)
    item.attributes = VFSItemAttributes(size: 1536, modified: Date(timeIntervalSince1970: 1_700_000_000))

    let text = conflictPreviewText(item)
    // «1.2 KB · date time» — both parts present, separator joined.
    #expect(text.contains("KB") || text.contains("kB") || text.contains("kB"))
    #expect(text.contains("·"))

    // Absent side renders a localized placeholder, not an empty cell.
    #expect(!conflictPreviewText(nil).isEmpty)
}
