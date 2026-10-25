// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import TerminalKit

// T-14: the exec branch of ShellSession (06 §6.8 v1) — spawn, cwd, stream
// capture and exit codes. Helpers use the `sh` name-space (the test module
// compiles neighbouring files together).

private func shTempDir(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func shExecCapturesStreamsAndExit() async throws {
    let outcome = try await ShellSession.exec(
        command: "echo out-here; echo err-there 1>&2; exit 3",
        workingDirectory: nil
    )
    #expect(outcome.exitCode == 3)
    #expect(outcome.standardOutput == "out-here\n")
    #expect(outcome.standardError == "err-there\n")
    #expect(!outcome.succeeded)
}

@Test func shExecRunsInGivenWorkingDirectory() async throws {
    let dir = try shTempDir("sh-cwd")
    let outcome = try await ShellSession.exec(command: "pwd", workingDirectory: dir)
    #expect(outcome.succeeded)
    // The child's pwd points into the given directory component (TMPDIR
    // symlink spellings differ, aliases stay).
    let reported = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported.hasSuffix(dir.lastPathComponent))

    // The cwd is a real child-process state, not just text: a relative
    // listing sees the file created in that directory.
    try Data("touch-me\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
    let listing = try await ShellSession.exec(command: "cat file.txt", workingDirectory: dir)
    #expect(listing.standardOutput == "touch-me\n")
    #expect(listing.succeeded)
}

@Test func shSpawnFailureMapsToMCError() async throws {
    // A command string is always routable; harness failure is simulated by a
    // non-existent executable through a crafted /bin/sh invocation is not
    // possible, so the honest check is the error type of a zero-arg-free fail:
    // an empty cwd that got deleted meanwhile.
    let dir = try shTempDir("sh-gone")
    try FileManager.default.removeItem(at: dir)
    await #expect(throws: MCError.self) {
        _ = try await ShellSession.exec(command: "true", workingDirectory: dir)
    }
}
