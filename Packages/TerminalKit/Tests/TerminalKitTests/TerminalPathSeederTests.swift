// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import TerminalKit

// T-31 (F-17, 06 §6.8 «Уточнение T-31»): pure POSIX escaping of the seeded
// paths. Every shell-significant character must stay inside the quotes; the
// `cd` line carries the newline, the insertion sequence must not.

@Test func seederQuotesPlainPath() {
    #expect(TerminalPathSeeder.posixQuoted("abc") == "'abc'")
}

@Test func seederQuotesEmptyPath() {
    #expect(TerminalPathSeeder.posixQuoted("") == "''")
}

@Test func seederEscapesEmbeddedQuote() {
    // it's → 'it'\''s' (the standard three-part splice)
    #expect(TerminalPathSeeder.posixQuoted("it's") == "'it'\\''s'")
}

@Test func seederKeepsShellSpecialsInert() {
    let path = "/tmp/a $(rm -rf ~); echo hit$q; \\"
    let quoted = TerminalPathSeeder.posixQuoted(path)
    #expect(quoted == "'/tmp/a $(rm -rf ~); echo hit$q; \\'")
}

@Test func seederKeepsSpacesAndUnicodeInert() {
    let quoted = TerminalPathSeeder.posixQuoted("/Users/me/Мои файлы/№ 5")
    #expect(quoted == "'/Users/me/Мои файлы/№ 5'")
}

@Test func seederCdtCarriesNewline() {
    let url = URL(fileURLWithPath: "/tmp/dir with space")
    #expect(TerminalPathSeeder.cdTo(url) == "cd -- '/tmp/dir with space'\n")
}

@Test func seederInsertSequenceOmitsNewline() {
    let url = URL(fileURLWithPath: "/tmp/dir with space")
    #expect(TerminalPathSeeder.insertSequence(url) == "'/tmp/dir with space'")
    #expect(TerminalPathSeeder.insertSequence(URL(fileURLWithPath: "/tmp/a'b")) == "'/tmp/a'\\''b'")
}
