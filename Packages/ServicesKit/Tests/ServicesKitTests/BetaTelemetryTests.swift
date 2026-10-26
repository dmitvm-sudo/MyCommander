// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import ServicesKit

// T-38 (docs/SDD/06 §6.9 «BetaTelemetry»): the local beta ledger facts —
// clean/crashed/unterminated classification, crash attribution by a
// tombstone line inside the session window, ledger caps, foreign-line
// tolerance and the export report shape. Process-level signal hooks are
// smoke-checked live by the app (installCrashHooks — headless tests must
// not rewire the test runner's signal disposition).

private func btkTempURL(_ test: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MCBetaTests-\(test)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("beta-sessions.jsonl")
}

@Test func btkCleanCycleYieldsTheFullRate() {
    let url = btkTempURL("clean")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BetaTelemetryStore(storageURL: url)
    store.beginSession()
    store.endSessionClean()

    let stats = store.crashStats()
    #expect(stats.total == 1)
    #expect(stats.clean == 1)
    #expect(stats.crashed == 0)
    #expect(stats.unterminated == 0)
    #expect(stats.crashFreeRate == 1.0)
}

@Test func btkCrashLineAttributesTheOpenHead() {
    let url = btkTempURL("crash")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    // Session 1: opens, then a crash tombstone lands, then the process dies
    // (no clean end). The NEXT launch re-runs the store from the same dir.
    let first = BetaTelemetryStore(storageURL: url)
    first.beginSession()
    first.recordCrashLine(kind: "sig-segv")

    // And a fresh store instance now: the open head must be crash-marked.
    first.beginSession()
    let stats = first.crashStats()
    #expect(stats.crashed == 1)
    // The fresh head is RUNNING (open with no tombstone of its own).
    #expect(stats.unterminated == 1)
    #expect(stats.total == 2)
    #expect(stats.crashFreeRate == 0.0)   // 0 clean / (0 clean + 1 crash)
}

@Test func btkUnterminatedWithNoTombstoneIsNotACrash() {
    let url = btkTempURL("unterminated")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BetaTelemetryStore(storageURL: url)
    store.beginSession()

    // Kill/force-quit semantics: open head, NO tombstone inside the window.
    let stats = store.crashStats()
    #expect(stats.unterminated == 1)
    #expect(stats.crashed == 0)
    // Vacuously crash-free — no closed-with-crash sessions at all.
    #expect(stats.crashFreeRate == 1.0)
}

@Test func btkLedgerCapKeepsTheLastFiveHundred() throws {
    let url = btkTempURL("cap")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    // Hand-write 502 sessions straight to the ledger (fast path); a fresh
    // begin appends one more — the cap keeps the last 500.
    let encoder = JSONEncoder()
    var payload = Data()
    for index in 0..<502 {
        let session = BetaSession(
            id: UUID(),
            start: 1_700_000_000 + TimeInterval(index),
            end: 1_700_000_000 + TimeInterval(index) + 60,
            crash: false
        )
        var line = try encoder.encode(session)
        line.append(0x0A)
        payload.append(line)
    }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try payload.write(to: url)

    let store = BetaTelemetryStore(storageURL: url)
    store.beginSession()
    store.endSessionClean()

    let stats = store.crashStats()
    #expect(stats.total == 500)
    #expect(stats.clean == 500)   // all 500 closed cleanly after the append+close
}

@Test func btkForeignLinesAreTolerated() throws {
    let url = btkTempURL("foreign")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let today = Date().timeIntervalSince1970
    let junk = Data("[not-json]\n{\"id\":\"zzz\",}\n".utf8)
    let good = Data("{\"id\":\"A1B2C3D4-EF56-7890-ABCD-000000000000\",\"start\":\(today),\"end\":null,\"crash\":null}\n".utf8)
    try (junk + good).write(to: url)
    // A tombstone beside it — parseable lines only.
    let crash = Data("mc-crash sig-abrt t=\(Int(today))\ngarbage\n".utf8)
    try crash.write(to: directory.appendingPathComponent("beta-crash.txt"))

    let store = BetaTelemetryStore(storageURL: url)
    // Attribution is a launch-time operation: beginSession marks the prior
    // open head with the freshly parsed tombstone (foreign lines evaporate).
    store.beginSession()
    let stats = store.crashStats()
    #expect(stats.total == 2)      // attributed session + the fresh open head
    #expect(stats.crashed == 1)
    #expect(stats.unterminated == 1)
}

@Test func btkStaleCrashLineIsNotAttributed() {
    let url = btkTempURL("oldcrash")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    // A tombstone written long BEFORE the hand-crafted open session: the
    // stats are a pure flag read — no invented crash flag.
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stale = Data("mc-crash sig-bus t=1000000000\n".utf8)
    try? stale.write(to: directory.appendingPathComponent("beta-crash.txt"))
    let today = Date().timeIntervalSince1970
    let session = Data("{\"id\":\"AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111\",\"start\":\(today),\"end\":null,\"crash\":null}\n".utf8)
    try? session.write(to: url)

    let store = BetaTelemetryStore(storageURL: url)
    let stats = store.crashStats()
    #expect(stats.unterminated == 1)
    #expect(stats.crashed == 0)
}

@Test func btkFeedbackReportCarriesTheSummary() throws {
    let url = btkTempURL("report")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BetaTelemetryStore(storageURL: url)
    store.beginSession()
    store.endSessionClean()
    store.recordCrashLine(kind: "sig-abrt")
    // A second crashed session via the fresh-store trick of the prior test.
    store.beginSession()

    let report = store.makeFeedbackReport(appVersion: "1.2.3 (7)", osVersion: "macOS 15.1")
    #expect(report.contains("app: 1.2.3 (7)"))
    #expect(report.contains("os: macOS 15.1"))
    #expect(report.contains("crashFreeRate:"))
    #expect(report.contains("mc-crash sig-abrt"))
    #expect(report.contains("target ≥ 99.5%"))
}
