// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.8 «Контракт v1 (T-14)» — the exec branch of
// ShellSession: one-shot `/bin/sh -c` runs backing the command bar's `!`
// command (F-17а). The interactive PTY branch (SwiftTerm host) is F-17 (M3)
// and arrives separately.

/// One finished run: the two output streams and the shell's exit code.
public struct ShellOutcome: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ShellSession {
    /// Runs `command` through `/bin/sh -c` in `workingDirectory` (nil = the
    /// process's own cwd). Errors of the harness itself (spawn failure) map to
    /// `MCError`; the child's non-zero exit is a normal outcome, not a throw.
    /// Streams are collected live (readability handlers), flushed after exit.
    public static func exec(
        command: String,
        workingDirectory: URL?,
        environment: [String: String]? = nil
    ) async throws -> ShellOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice

        let outputCollector = OutputCollector()
        let errorCollector = OutputCollector()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        try run(process)

        let outcome = ShellOutcome(
            exitCode: await termination(process),
            standardOutput: outputCollector.drain(pipe: outputPipe),
            standardError: errorCollector.drain(pipe: errorPipe)
        )
        return outcome
    }

    /// Spawn failure is a harness error (missing /bin/sh, spawn limits).
    private static func run(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw MCError.unexpected(underlying: error)
        }
    }

    /// Suspends until the child exits (termination callback from any thread —
    /// resume is allowed from anywhere).
    private static func termination(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { terminated in
                continuation.resume(returning: terminated.terminationStatus)
            }
        }
    }
}

/// Stream buffer for the readability handlers (arbitrary thread) drained by
/// the awaiting caller (§6.8 v1).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
    }

    /// Kills the live handler, reads the EOF tail, returns the whole stream.
    func drain(pipe: Pipe) -> String {
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        buffer.append(tail)
        let text = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        return text
    }
}
