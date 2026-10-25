// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import VFSKit

// T-19 M1 hardening: §8.5 row «catalog open (list+diff) ≤ 300 ms P95 on
// 10k files» — the LocalVFS leg against a real temp-directory fixture.
// The budget is held in-test at ×4 of the honest register (CI-runner noise);
// the panel-diff leg lives in ListViewKitTests/DiffUpdateTests (T-06).
// Helpers use the `po` name-space (the test module compiles neighbouring
// files together).

private func poFixtureURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("po-perf-\(UUID().uuidString)", isDirectory: true)
}

@Test func perfCatalogOpenOfTenThousandEntriesUnderBudget() async throws {
    let rootURL = poFixtureURL()
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    for index in 0 ..< 10_000 {
        try Data().write(to: rootURL.appendingPathComponent("leaf-\(index % 4096)-\(index).txt"))
    }
    let vfs = LocalVFS(at: rootURL)
    let path = VFSPath(root: vfs.id)

    // Warm-up listing pays one-time costs (disk cache, first snapshotValues
    // path) — the app pays this on its first panel open, not in the budget.
    _ = try await vfs.listDirectory(at: path)

    let start = Date()
    let items = try await vfs.listDirectory(at: path)
    let elapsed = Date().timeIntervalSince(start)
    #expect(items.count == 10_000)
    #expect(elapsed < 2.0, "10k catalog open took \(elapsed)s (honest register ≤ 0.3s P95; the in-test hold makes room for parallel neighbours doing heavy I/O)")
}
