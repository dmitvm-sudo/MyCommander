// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
import DomainKit
import VFSKit
@testable import ListViewKit

// T-05 perf gate (docs/SDD/12: «скролл 50k строк без hitching (fixtures)», N-1).
// In an off-screen test the honest proxy is: fixed row height, view-based cell
// reuse, icons through the LRU cache, no autolayout per row. We exercise the
// visible-cell pipeline for 5 000 scattered rows (a hard scroll over the whole
// 50k table) and budget per-row/aggregate costs generously above the 60 fps
// line (a single row > ~33 ms would drop more than 2 frames).

private func perfFixtureItems(count: Int) -> [VFSItem] {
    let instance = VFSInstanceID(kind: .localDisk, specID: "perf-unit")
    var items: [VFSItem] = []
    items.reserveCapacity(count)
    for index in 0 ..< count {
        let isTree = index % 50 == 0
        let name = isTree
            ? "tree\(index)"
            : "leaf-\(index % 4096)-\(index).\(index % 3 == 0 ? "png" : "txt")"
        items.append(VFSItem(
            id: VFSPath(root: instance, components: [name]),
            instance: instance,
            name: name,
            kind: isTree ? .directory : .file,
            attributes: VFSItemAttributes(size: Int64(index % 99), modified: .now),
            revision: 1
        ))
    }
    return items
}

@MainActor
@Test func reloadAndScrollSimulationOfFiftyThousandRowsStayUnderBudgets() async {
    let viewModel = PanelViewModel(source: InMemoryVFS(name: "perf"))
    let fileView = FileListView(viewModel: viewModel, iconCache: ItemCache())

    // 1) The 50k listing lands in the panel: setItems → onContentsChanged → reload.
    let listingStart = Date()
    viewModel.setItems(perfFixtureItems(count: 50_000), at: nil)
    let listingElapsed = Date().timeIntervalSince(listingStart)
    #expect(viewModel.visibleCount == 50_000)
    #expect(listingElapsed < 1.0, "50k reload took \(listingElapsed)s")

    // 2) Structure guards (N-1): constant row height, three fixed columns.
    #expect(fileView.listTableView.rowHeight == FileListView.rowHeight)
    #expect(fileView.listTableView.numberOfColumns == 3)

    // 3) Hard scroll pipeline: the table asks its delegate for visible cells.
    guard let delegate = fileView.listTableView.delegate,
          fileView.listTableView.tableColumns.count == 3
    else {
        Issue.record("table delegate/columns missing")
        return
    }
    let columns = fileView.listTableView.tableColumns

    // Warm-up: the very first cells pay one-time costs (view class loading,
    // first NSWorkspace type lookups). The app pays this once at launch, so
    // the hitch budget measures the steady-state cell pipeline.
    for column in columns {
        _ = delegate.tableView?(fileView.listTableView, viewFor: column, row: 0)
    }

    // 4) Hard scroll: simulate a pass over 5 000 scattered rows × 3 columns
    //    (name/size/date) — the whole 50k table from top to bottom.
    let scrollStart = Date()
    var slowestRow: TimeInterval = 0
    for row in stride(from: 8, to: 50_000, by: 10) {
        let rowStart = Date()
        for column in columns {
            _ = delegate.tableView?(fileView.listTableView, viewFor: column, row: row)
        }
        let rowElapsed = Date().timeIntervalSince(rowStart)
        slowestRow = max(slowestRow, rowElapsed)
    }
    let scrollElapsed = Date().timeIntervalSince(scrollStart)
    #expect(scrollElapsed < 4.0, "5k-row scroll sweep took \(scrollElapsed)s")
    // No single row may cost more than ~2 frames (33 ms): no per-row hitches.
    #expect(slowestRow < 0.033, "slowest row took \(slowestRow)s")
}
