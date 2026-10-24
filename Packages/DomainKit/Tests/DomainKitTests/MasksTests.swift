// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DomainKit

@Test func wildcardMatchesAnything() {
    let mask = GlobMask("*")
    #expect(mask.matches("anything.txt"))
    #expect(mask.matches("études File (2026).dmg"))
}

@Test func questionMatchesExactlyOneCharacter() {
    let mask = GlobMask("Report?.txt")
    #expect(mask.matches("Report1.txt"))
    #expect(!mask.matches("Report12.txt"))
    #expect(!mask.matches("Report.txt"))
}

@Test func caseFoldingByDefaultAndStrictModeWhenAsked() {
    #expect(GlobMask("*.TXT").matches("notes.txt"))
    let strict = GlobMask("*.TXT", caseSensitive: true)
    #expect(strict.matches("Notes.TXT"))
    #expect(!strict.matches("notes.txt"))
}

@Test func characterClassesRangesAndNegation() {
    let range = GlobMask("[a-z]ide.txt", caseSensitive: true)
    #expect(range.matches("aide.txt"))
    #expect(!range.matches("Aide.txt"))

    let negation = GlobMask("[!0-9]File.txt")
    #expect(negation.matches("aFile.txt"))
    #expect(!negation.matches("1File.txt"))

    let unmatchedBracketIsLiteral = GlobMask("[x")
    #expect(unmatchedBracketIsLiteral.matches("[x"))
}

@Test func masksAnchorToWholeName() {
    let mask = GlobMask("*.txt")
    #expect(mask.matches("a.b.txt"))
    #expect(!mask.matches("notes.txt.bak"))
    #expect(GlobMask("file2").matches("file2"))
}

@Test func fileMaskUnionsGlobs() {
    let mask = FileMask(["*.jpg", "*.png"])
    #expect(mask.matches("pic.PNG"))
    #expect(!mask.matches("pic.gif"))
}

@Test func byteSizeFormatIsDeterministicWithPinnedLocale() {
    let posix = Locale(identifier: "en_US_POSIX")
    #expect(ByteSizeFormat.string(0, style: .binary, locale: posix) == "0 bytes")
    #expect(ByteSizeFormat.string(1_048_576, style: .binary, locale: posix) == "1 MB")
    #expect(ByteSizeFormat.string(1_024, style: .binary, locale: posix) == "1 KB")
    #expect(ByteSizeFormat.string(1_200_000, style: .decimal, locale: posix) == "1.2 MB")
    // Default call keeps working for display strings (locale from the system).
    #expect(!ByteSizeFormat.string(1_500).isEmpty)
}
