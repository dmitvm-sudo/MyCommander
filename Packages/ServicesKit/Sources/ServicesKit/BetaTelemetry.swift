// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// T-38 (docs/SDD/06 §6.9 «BetaTelemetry»): локальный учёт беты. Contract
// (03 N-9): НЕТ сети и авто-отправок — crash-free метрика считается по
// локальному леджеру (beta-sessions.jsonl) и локальному throws-лаг
// (beta-crash.txt); юзер сам экспортирует сводку (App: help-меню →
// NSSavePanel). Tombstone-записи хранят только вид отказа и время — без
// пользовательских и персональных данных.

/// One session line of `beta-sessions.jsonl`. Foreign/corrupt lines are
/// skipped on load (store-style tolerance, 06 §6.9).
public struct BetaSession: Codable, Sendable, Equatable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval?
    public var crash: Bool?

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval? = nil, crash: Bool? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.crash = crash
    }
}

/// Crash-free picture over the ledger (06 §6.9 formula v1): clean / (clean
/// + crashed) — unterminated (kill/force-quit, NO tombstone inside the
/// window) sessions are user-initiated interruptions and never count as
/// crashes. ATTRIBUTION is a launch-time operation (`beginSession` writes
/// the crash flag when a tombstone lands inside the prior open window);
/// `crashStats` is a pure flag read (deterministic, no side effects). An
/// empty/clean ledger is vacuously crash-free (rate 1.0).
public struct BetaStats: Sendable, Equatable {
    public let total: Int
    public let clean: Int
    public let crashed: Int
    public let unterminated: Int
    /// clean / (clean + crashed); 1.0 when both are zero.
    public let crashFreeRate: Double
}

public final class BetaTelemetryStore {
    /// `…/MyCommander/beta-sessions.jsonl`; the crash log lives beside it.
    private let storageURL: URL
    private var crashLogURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("beta-crash.txt") }

    public static func defaultStorageURL() -> URL {
        let support: URL
        if #available(macOS 13.0, *) {
            support = URL.applicationSupportDirectory
        } else {
            support = try! FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        }
        return support
            .appendingPathComponent("MyCommander", isDirectory: true)
            .appendingPathComponent("beta-sessions.jsonl")
    }

    public init(storageURL: URL = BetaTelemetryStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    // MARK: ledger

    /// Loads the (capped) ledger; foreign/corrupt lines are skipped.
    private func loadSessions() -> [BetaSession] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        var sessions: [BetaSession] = []
        var openHead: BetaSession?   // defensive: keep at most ONE open head
        for raw in data.split(separator: 0x0A) {
            guard let session = try? JSONDecoder().decode(BetaSession.self, from: Data(raw)) else { continue }
            if session.end == nil && session.crash != true {
                if openHead != nil { continue }   // malformed tail — ignore extra open entries
                openHead = session
            }
            sessions.append(session)
        }
        return Array(sessions.suffix(Self.sessionCap))
    }

    private func saveSessions(_ sessions: [BetaSession]) {
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let lines = sessions.map { (try? encoder.encode($0)) as Data? }
            .compactMap { $0 }
            .map { data -> Data in
                var line = data
                line.append(0x0A)
                return line
            }
        var payload = Data()
        for line in lines { payload.append(line) }
        try? payload.write(to: storageURL, options: [.atomic])
    }

    /// Starts a session (called on launch): attributes a crash to a previous
    /// still-open session when a tombstone lands inside its window, then
    /// appends the fresh open entry (ledger rewrite happens ONLY for the
    /// attribution, otherwise it stays append-only).
    public func beginSession(at date: Date = Date()) {
        var sessions = loadSessions()
        var dirty = false
        for index in sessions.indices where sessions[index].end == nil && sessions[index].crash != true {
            if let crashTime = lastCrashTime(), previously(attributableTo: sessions[index], at: crashTime) {
                sessions[index].crash = true
                dirty = true
            }
        }
        sessions.append(BetaSession(start: date.timeIntervalSince1970))
        if dirty {
            saveSessions(Cap(sessions))
        } else {
            // append-only fast path: suffix already respects the cap.
            saveSessions(Array(sessions.suffix(Self.sessionCap)))
        }
    }

    /// Ends the CURRENT (open head) session cleanly — from
    /// `applicationWillTerminate`. Kill/force-quit simply skips this (the
    /// session stays unterminated; a real crash additionally leaves a
    /// tombstone line the next `beginSession` attributes).
    public func endSessionClean(at date: Date = Date()) {
        var sessions = loadSessions()
        guard sessions.last?.end == nil else { return }
        sessions[sessions.count - 1].end = date.timeIntervalSince1970
        sessions[sessions.count - 1].crash = false
        saveSessions(sessions)
    }

    // MARK: stats

    public func crashStats() -> BetaStats {
        let sessions = loadSessions()
        var clean = 0, crashed = 0, unterminated = 0
        for session in sessions {
            if session.crash == true {
                crashed += 1
            } else if session.end == nil {
                unterminated += 1
            } else {
                clean += 1
            }
        }
        let denominator = clean + crashed
        let rate: Double = denominator == 0 ? 1.0 : Double(clean) / Double(denominator)
        return BetaStats(
            total: sessions.count, clean: clean, crashed: crashed,
            unterminated: unterminated, crashFreeRate: rate
        )
    }

    /// Crash attribution rule for the open head at `beginSession` re-entry:
    /// any tombstone inside the (unbounded) open window marks the crash.
    private func previously(attributableTo session: BetaSession, at crashTime: TimeInterval?) -> Bool {
        guard let crashTime else { return false }
        return crashTime >= TimeInterval(Int(session.start))
    }

    // MARK: tombstones

    /// Parses tombstone lines «mc-crash <kind> t=<unix>»; kind ∈
    /// {sig-abrt, sig-segv, sig-bus, sig-ill, sig-fpe, sig-trap, exception}.
    private func crashTimes() -> [TimeInterval] {
        guard let text = try? String(contentsOf: crashLogURL, encoding: .utf8) else { return [] }
        var times: [TimeInterval] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ")
            guard tokens.count >= 3, tokens[0] == "mc-crash",
                  tokens[2].hasPrefix("t="),
                  let seconds = TimeInterval(tokens[2].dropFirst(2))
            else { continue }
            times.append(seconds)
        }
        return times
    }

    private func lastCrashTime() -> TimeInterval? {
        crashTimes().max()
    }

    // MARK: feedback report (App hands it over to NSSavePanel)

    /// Builds the beta export (06 §6.9): no personal data — versions, session
    /// summary, the latest tombstones. Plain English (GitHub issues).
    public func makeFeedbackReport(
        appVersion: String, osVersion: String,
        now: Date = Date(), crashLimit: Int = 10
    ) -> String {
        let stats = crashStats()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var report = """
        # MyCommander beta report
        app: \(appVersion)
        os: \(osVersion)
        generated: \(formatter.string(from: now))
        sessions: total=\(stats.total) clean=\(stats.clean) crashed=\(stats.crashed) unterminated=\(stats.unterminated)
        crashFreeRate: \(String(format: "%.1f", stats.crashFreeRate * 100))% (target ≥ 99.5%)

        """
        let crashLines = crashLinesText(limit: crashLimit)
        if crashLines.isEmpty {
            report += "## Crashes\n- none recorded\n"
        } else {
            report += "## Crashes (last \(crashLimit))\n"
            report += crashLines.joined(separator: "\n")
            report += "\n"
        }
        return report
    }

    private func crashLinesText(limit: Int) -> [String] {
        guard let text = try? String(contentsOf: crashLogURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("mc-crash ") }
            .suffix(limit)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: caps (06 §6.9: ledger 500)

    private static let sessionCap = 500

    private func Cap(_ sessions: [BetaSession]) -> [BetaSession] {
        Array(sessions.suffix(Self.sessionCap))
    }
}

// MARK: - Crash hooks (async-signal-safe tombstones, 06 §6.9)

// The tombstone path must write from signal context: a single per-process
// fd opened at install (O_APPEND), a preallocated global scratch buffer and
// pre-encoded kind prologues — the handler only fills bytes and calls
// write(2)/time(2). Signal-time formatting allocates nothing afterwards;
// a tombstone may be lost in a malloc-interlocked crash — graceful
// degradation for v1 (witnessed only in tests via the foreground writer).
nonisolated(unsafe) private var mcCrashHooksFD: Int32 = -1
nonisolated(unsafe) private var mcKindPrologues: [ContiguousArray<UInt8>] = []
nonisolated(unsafe) private var mcScratch = [UInt8](repeating: 0, count: 64)

private func mcEncodePrologue(kind: String) -> ContiguousArray<UInt8> {
    ContiguousArray("mc-crash \(kind) t=".utf8)
}

private func mcSignalKindMarker(_ signo: Int32) -> ContiguousArray<UInt8> {
    switch signo {
    case SIGABRT: mcEncodePrologue(kind: "sig-abrt")
    case SIGSEGV: mcEncodePrologue(kind: "sig-segv")
    case SIGBUS: mcEncodePrologue(kind: "sig-bus")
    case SIGILL: mcEncodePrologue(kind: "sig-ill")
    case SIGFPE: mcEncodePrologue(kind: "sig-fpe")
    case SIGTRAP: mcEncodePrologue(kind: "sig-trap")
    default: mcEncodePrologue(kind: "sig-\(signo)")
    }
}

/// Handler-friendly fwrite of a byte range into the pre-opened fd.
/// Alloc-free post-install: bytes go into the preallocated global scratch
/// (prefix prologue → unix-seconds digits → newline), one write(2) call.
private func mcEmit(kind: ContiguousArray<UInt8>, seconds: Int) {
    guard mcCrashHooksFD >= 0, seconds >= 0, mcScratch.count >= 40 else { return }
    var cursor = 0
    for byte in kind { mcScratch[cursor] = byte; cursor += 1 }
    // Digit count first, then rear-fill — no allocation, no reversal buffer.
    var digits = 0
    var probe = seconds
    repeat { digits += 1; probe /= 10 } while probe > 0
    var value = seconds
    var pos = cursor + digits - 1
    repeat { mcScratch[pos] = UInt8(0x30 + value % 10); pos -= 1; value /= 10 } while value > 0
    cursor += digits
    mcScratch[cursor] = 0x0A
    cursor += 1
    mcScratch.withContiguousStorageIfAvailable { body in
        _ = write(mcCrashHooksFD, body.baseAddress, cursor)
    }
}

private func mcSignalHandler(_ signo: Int32) {
    mcEmit(kind: mcSignalKindMarker(signo), seconds: Int(time(nil)))
    // Hand the process back to the kernel: a returning handler would just
    // refault (the reason this tombstone path exists is that the process is
    // already dying). Restore the default disposition and re-raise so the
    // crash actually terminates (and engages the system crash reporter).
    signal(signo, SIG_DFL)
    kill(getpid(), signo)
}

private func mcUncaughtExceptionHandler(_ exception: NSException) {
    mcEmit(kind: mcEncodePrologue(kind: "exception"), seconds: Int(time(nil)))
    // name/reason deliberately NOT recorded (06 §6.9: no user data).
    // Belt-and-braces: the NSException route MUST die too; abort re-enters
    // the SIGABRT handler which appends the second tombstone kind and then
    // the re-raise step terminates the process.
    abort()
}

extension BetaTelemetryStore {
    /// One-time install (App bootstrap, BEFORE any heavy work): opens the
    /// crash-log fd, registers the uncaught-exception hook and the six
    /// signal handlers. Never throws; misconfigured tombstones degrade to a
    /// silent no-op (stats then treat those sessions as unterminated only).
    public func installCrashHooks() {
        guard mcCrashHooksFD < 0 else { return }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(crashLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        mcCrashHooksFD = fd
        NSSetUncaughtExceptionHandler(mcUncaughtExceptionHandler)
        for signo in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = mcSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            sigaction(signo, &action, nil)
        }
    }
}

extension BetaTelemetryStore {
    /// Foreground tombstone writer — the SAME file/format the signal path
    /// emits, exercised by the headless tests (the process-level handlers
    /// are smoke-checked live by the app, 06 §6.9).
    func recordCrashLine(kind: String, at date: Date = Date()) {
        let directory = crashLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "mc-crash \(kind) t=\(Int(date.timeIntervalSince1970))\n"
        if let handle = FileHandle(forWritingAtPath: crashLogURL.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: crashLogURL)
        }
    }
}
