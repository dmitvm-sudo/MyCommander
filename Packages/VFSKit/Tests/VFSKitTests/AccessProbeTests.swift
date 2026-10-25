// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import VFSKit

// T-17: the access probe (F-20, 06 §6.10 v1). The probe runs against a
// synthetic home (a temp dir) — the real-machine FDA state must never make
// these tests flaky. Helpers use the `ap` name-space (the test module
// compiles neighbouring files together).

private func apHome() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ap-home-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func apProbe(
    home: URL,
    fileManager: FileManager = .default
) -> AccessReport {
    AccessProbe.probe(home: home, fileManager: fileManager)
}

@Test func apSyntheticFDAProbeDetectsGuardFileRead() {
    let home = apHome()
    let report = apProbe(home: home)
    #expect(!report.hasFullDiskAccess)

    // The TCC-guarded library file: readable content ⇒ Full Disk Access.
    let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
    try? FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
    try? Data("plist-bytes".utf8).write(to: preferences.appendingPathComponent("com.apple.dock.plist"))
    let granted = apProbe(home: home)
    #expect(granted.hasFullDiskAccess)
}

@Test func apZoneGrantedByListableDirectory() {
    let home = apHome()
    try? FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    let report = apProbe(home: home)
    #expect(report.grantedZones == [.desktop])

    // An unreadable/missing zone never counts as granted.
    try? FileManager.default.removeItem(at: home.appendingPathComponent("Desktop"))
    let empty = apProbe(home: home)
    #expect(empty.grantedZones.isEmpty)
}

@Test func apClassifyProducesTotalModes() {
    // full → full.
    #expect(AccessProbe.classify(AccessReport(hasFullDiskAccess: true, grantedZones: [])) ==
        AccessMode.full)

    // No FDA but granted zones → safe mode carrying them.
    #expect(AccessProbe.classify(AccessReport(hasFullDiskAccess: false, grantedZones: [.desktop, .documents])) ==
        AccessMode.safe(knownZones: [.desktop, .documents]))

    // Nothing granted — the app stays alive (restricted), never crashes.
    #expect(AccessProbe.classify(AccessReport(hasFullDiskAccess: false, grantedZones: [])) ==
        AccessMode.restricted)
}

@Test func apSeedPathPicksFirstZoneUnderSafe() {
    #expect(AccessProbe.seedPath(in: .full) == nil)
    #expect(AccessProbe.seedPath(in: .restricted) == nil)
    #expect(AccessProbe.seedPath(in: .safe(knownZones: [.documents, .desktop])) == .documents)
}
