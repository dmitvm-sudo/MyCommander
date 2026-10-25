// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import ListViewKit

// T-19 M1 hardening: the N-2 memory row of §8.5 v1 — panel data for 100k
// rows (+ ≤ 100 MB phys-footprint, «lazy-атрибуты, без инстанцирования ячеек
// для всех строк»; the cell-side structural guard lives in T-05 perf tests).
// Helpers use the `pf` name-space (the test module compiles neighbouring
// files together).

private func pfFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { typed in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), typed, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

private func pfItems(_ count: Int) -> [VFSItem] {
    let instance = VFSInstanceID(kind: .localDisk, specID: "perf-mem")
    var items: [VFSItem] = []
    items.reserveCapacity(count)
    for index in 0 ..< count {
        let name = "leaf-\(index % 4096)-\(index).\(index % 3 == 0 ? "png" : "txt")"
        items.append(VFSItem(
            id: VFSPath(root: instance, components: [name]),
            instance: instance,
            name: name,
            kind: .file,
            attributes: VFSItemAttributes(size: Int64(index % 99), modified: .now),
            revision: 1
        ))
    }
    return items
}

@MainActor
@Test func perfPanelMemoryOf100kRowsUnderBudget() {
    // Swift Testing runs tests concurrently: a foreign test's allocations may
    // land inside the measurement window and ONLY inflate the delta — so the
    // honest number is the minimum over 3 independent rounds (each builds a
    // fresh panel, then relief returns the round's freed pages).
    var bestDelta = Int64.max
    for _ in 0 ..< 3 {
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let before = pfFootprint()
        let viewModel = PanelViewModel(source: InMemoryVFS(name: "perf-mem"))
        viewModel.setItems(pfItems(100_000), at: nil)
        _ = viewModel.rawItems.count
        bestDelta = min(bestDelta, pfFootprint() - before)
    }
    malloc_zone_pressure_relief(malloc_default_zone(), 0)

    #expect(bestDelta <= 100 * 1024 * 1024, "100k rows footprint delta \(bestDelta) bytes (N-2 budget + ≤ 100 MB)")
}
