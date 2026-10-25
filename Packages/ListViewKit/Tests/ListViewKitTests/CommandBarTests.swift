// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import ListViewKit

// T-14: command bar pure logic (06 §6.8 v1) — keyword routing before
// placeholder expansion, %-substitutions with shell quoting, unquoting for
// the vfs-style commands and the ↑/↓ history draft model. Helpers use the
// `cb` name-space (the test module compiles neighbouring files together).

private func cbContext(
    cursorName: String? = "report.pdf",
    cursorPath: String? = "/Users/dmit/Docs/report.pdf",
    activeDir: String = "/Users/dmit/Docs",
    oppositeDir: String = "/Volumes/USB",
    selection: [String] = ["a.txt", "b c.txt"]
) -> CommandPlaceholderContext {
    CommandPlaceholderContext(
        cursorName: cursorName,
        cursorPath: cursorPath,
        activeDirectory: activeDir,
        oppositeDirectory: oppositeDir,
        selectionNames: selection
    )
}

@Test func cbRoutesKeywordsBeforeExpansion() {
    // Keyword classes come from the first word; the argument stays raw for
    // expansion (spaces in substituted paths must not break tokenization).
    #expect(CommandBarParser.parse(line: "cd %d", context: cbContext()) == .command(.cd(path: "/Users/dmit/Docs")))
    #expect(CommandBarParser.parse(line: "mkdir   new-dir", context: cbContext()) == .command(.mkdir(name: "new-dir")))
    #expect(CommandBarParser.parse(line: "open %f", context: cbContext()) == .command(.open(path: "report.pdf")))
    #expect(CommandBarParser.parse(line: "open %F", context: cbContext()) == .command(.open(path: "/Users/dmit/Docs/report.pdf")))
    #expect(CommandBarParser.parse(line: "! exit 0", context: cbContext()) == .command(.shell(command: "exit 0")))
    #expect(CommandBarParser.parse(line: "!echo hi", context: cbContext()) == .command(.shell(command: "echo hi")))

    // Case-insensitive keywords.
    #expect(CommandBarParser.parse(line: "CD /tmp", context: cbContext()) == .command(.cd(path: "/tmp")))

    // Empty/degenerate lines behave like the collapse contract.
    #expect(CommandBarParser.parse(line: "", context: cbContext()) == .empty)
    #expect(CommandBarParser.parse(line: "   ", context: cbContext()) == .empty)

    // Empty `!` body is a readable failure.
    if case .invalid = CommandBarParser.parse(line: "!", context: cbContext()) {} else {
        Issue.record("empty ! must fail")
    }

    // Missing argument and unknown commands produce readable failures.
    if case let .invalid(message) = CommandBarParser.parse(line: "cd", context: cbContext()) {
        #expect(!message.isEmpty)
    } else {
        Issue.record("cd without arg must fail")
    }
    if case let .invalid(message) = CommandBarParser.parse(line: "rm -rf", context: cbContext()) {
        #expect(!message.isEmpty)
    } else {
        Issue.record("unknown keyword must fail")
    }
}

@Test func cbPlaceholdersExpandAndQuote() {
    let context = cbContext()
    #expect(CommandPlaceholders.expand("%d", context: context) == "/Users/dmit/Docs")
    #expect(CommandPlaceholders.expand("%D", context: context) == "/Volumes/USB")
    #expect(CommandPlaceholders.expand("copy %f %d", context: context) == "copy report.pdf /Users/dmit/Docs")
    // Selection list: names with spaces get shell quotation.
    #expect(CommandPlaceholders.expand("touch %s", context: context) == "touch a.txt 'b c.txt'")
    // Empty selection falls back to the cursor item.
    #expect(CommandPlaceholders.expand("rm %s", context: cbContext(selection: [])) == "rm report.pdf")

    // `%%` is a literal, unknown `%x` copies through both characters.
    #expect(CommandPlaceholders.expand("100%%ok", context: context) == "100%ok")
    #expect(CommandPlaceholders.expand("%w", context: context) == "%w")
    // Placeholders in front: shell escape 「it's」 spins into the POSIX interleave.
    #expect(CommandPlaceholders.expand("%f!", context: cbContext(cursorName: "it's")) == "'it'\\''s'!")

    // Without context the line keeps its tokens (history preview).
    #expect(CommandPlaceholders.expand("cd %d", context: nil) == "cd %d")
    // A trailing `%` stays literal.
    #expect(CommandPlaceholders.expand("cd %", context: context) == "cd %")
}

@Test func cbUnquoteRestoresPlainPaths() {
    #expect(CommandBarParser.unquote("'/Users/dmit/Docs'") == "/Users/dmit/Docs")
    #expect(CommandBarParser.unquote("plain-path") == "plain-path")
    #expect(CommandBarParser.unquote("'it'\\''s'") == "it's")
    #expect(CommandBarParser.unquote("\"a \\\"quoted\\\" name\"") == "a \"quoted\" name")
    // Round trip through the quoting helper.
    let quoted = CommandPlaceholders.quoteIfNeeded("a b")
    #expect(CommandBarParser.unquote(quoted) == "a b")
}

@Test func cbHistoryDraftCycle() {
    var history = CommandHistory()
    // Nothing recorded: arrows do nothing.
    #expect(history.up() == nil)
    #expect(history.down("") == nil)

    history.record("cd /tmp")
    history.record("mkdir docs")
    history.record("cd /tmp")          // non-consecutive — kept
    history.record("open readme")
    history.record("open readme")      // consecutive duplicate — skipped
    #expect(history.entries == ["cd /tmp", "mkdir docs", "cd /tmp", "open readme"])

    // ↑ walks from the draft to the newest, then older, clamped.
    #expect(history.up() == "open readme")
    #expect(history.up() == "cd /tmp")     // entries[2]
    #expect(history.up() == "mkdir docs")  // entries[1]
    #expect(history.up() == "cd /tmp")     // clamped at entries[0]

    // ↓ returns forward, then the draft comes back.
    #expect(history.down("draft") == "mkdir docs")
    #expect(history.down("draft") == "cd /tmp")
    #expect(history.down("draft") == "open readme")
    #expect(history.down("draft") == "draft")
    #expect(history.down("draft") == nil) // at the draft already

    // New recording resets to the draft.
    history.record("cd /")
    #expect(history.down("") == nil)
    #expect(history.up() == "cd /")
}
