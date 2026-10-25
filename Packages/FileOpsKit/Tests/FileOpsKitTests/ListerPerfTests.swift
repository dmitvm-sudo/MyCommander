// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import FileOpsKit

// T-19 M1 hardening: §8.5 rows owned by FileOpsKit — «lister open ≤ 200 ms
// to the first scroll» on a 4 GB sparse file (CI hold ×5) and the N-2 memory
// row «просмотр любого размера не буферизует файл» (windowed reads against
// the phys-footprint). Helpers use the `pl` name-space (the test module
// compiles neighbouring files together).

private func plFootprint() -> Int64 {
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

/// Sparse file via POSIX (create + ftruncate; the logical size grows without
/// allocating a single block on APFS/HFS+).
private func plSparseFile(_ url: URL, logicalSize: UInt64) -> Bool {
    let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return ftruncate(fd, off_t(logicalSize)) == 0
}

private func plFixture(rootName: String) throws -> (LocalVFS, URL) {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(rootName + "-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return (LocalVFS(at: rootURL), rootURL)
}

@Test func perfListerOpenOf4GBSparseFirstScrollUnderBudget() async throws {
    let (vfs, rootURL) = try plFixture(rootName: "pl-perf")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let huge = rootURL.appendingPathComponent("huge.txt")
    #expect(plSparseFile(huge, logicalSize: 4_294_967_296), "sparse fixture failed")
    let path = VFSPath(root: vfs.id, components: ["huge.txt"])

    // The honest «open to the first scroll» path: materialize (no copy for
    // LocalVFS) + the loader + the first 8 MB window.
    let start = Date()
    _ = await PreviewMaterializer.prepareFileURL(path: path, in: vfs)
    guard let source = await ListerLoader.open(path: path, in: vfs) else {
        Issue.record("loader failed")
        return
    }
    let firstWindow = try await source.read(0, 8 * 1024 * 1024)
    let elapsed = Date().timeIntervalSince(start)

    #expect(firstWindow.count > 0)
    #expect(elapsed < 1.0, "lister open+first window took \(elapsed)s (honest register ≤ 0.2s, CI ×5)")
}

@Test func perfListerStreamingDoesNotBufferWholeFile() async throws {
    let (vfs, rootURL) = try plFixture(rootName: "pl-mem")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let huge = rootURL.appendingPathComponent("huge.bin")
    #expect(plSparseFile(huge, logicalSize: 4_294_967_296), "sparse fixture failed")
    let path = VFSPath(root: vfs.id, components: ["huge.bin"])

    guard let source = await ListerLoader.open(path: path, in: vfs) else {
        Issue.record("loader failed")
        return
    }
    // NOTE (T-19): Foundation read APIs allocate buffers through the ObjC
    // runtime — inside ONE long-running async task those buffers ride the
    // task's autorelease pool and accumulate round-over-round (probes showed
    // +64 MB per round). Additionally, Swift Testing neighbours run their own
    // allocations concurrently — so the delta is measured INSIDE the short
    // nested Task (its own drained-by-completion pool, millisecond interference
    // window, start-snapshot right after a pressure relief).
    var bestDelta = Int64.max
    for _ in 0 ..< 3 {
        let offsets: [Int64] = [0, 1 << 30, 2 << 30, 3 << 30]
        let sourceRef = source
        do {
            let delta = try await Task<Int64, Error> { [offsets, sourceRef] in
                malloc_zone_pressure_relief(malloc_default_zone(), 0)
                let start = plFootprint()
                for offset in offsets {
                    let window = try await sourceRef.read(offset, 8 * 1024 * 1024)
                    _ = window.count   // keep the read side-effectful for Release runs
                }
                malloc_zone_pressure_relief(malloc_default_zone(), 0)
                return plFootprint() - start
            }.value
            bestDelta = min(bestDelta, delta)
        } catch {
            Issue.record("round read failed: \(error)")
            return
        }
    }

    #expect(bestDelta <= 64 * 1024 * 1024, "stream-window footprint delta \(bestDelta) bytes (N-2: no full-file buffering)")
}
