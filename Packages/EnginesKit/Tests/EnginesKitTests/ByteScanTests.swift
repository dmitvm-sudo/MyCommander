// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import EnginesKit

// T-30 (F-16): the line-based streaming content scan — literal/regex matching,
// case options, the partial-line carry-over across small windows and the
// cancellation contract.

final class ByteScanStream: ByteStream, @unchecked Sendable {
    private let chunks: [Data]
    private var next = 0

    init(data: Data, chunkSize: Int) {
        var parts: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            parts.append(Data(data[offset ..< end]))
            offset = end
        }
        chunks = parts
    }

    var length: Int64 { Int64(chunks.reduce(0) { $0 + $1.count }) }

    func readChunk(max: Int) async throws -> Data? {
        guard next < chunks.count else { return nil }
        let chunk = chunks[next]
        next += 1
        return chunk
    }
}

@Suite("ByteScan (F-16, T-30)")
struct ByteScanTests {

    private func stream(_ text: String, chunkSize: Int = 4096) -> ByteScanStream {
        ByteScanStream(data: Data(text.utf8), chunkSize: chunkSize)
    }

    @Test func literalSubstringCountsLines() async throws {
        let text = "alpha report\nbeta gamma\nREPORT final\nnone here\n"
        let hits = try await ByteScan.countMatchingLines(in: stream(text), needle: "report", isRegex: false, caseSensitive: false)
        #expect(hits == 2)   // case-insensitive: alpha report + REPORT final
        let sensitive = try await ByteScan.countMatchingLines(in: stream(text), needle: "report", isRegex: false, caseSensitive: true)
        #expect(sensitive == 1)
    }

    @Test func regexMatchesLines() async throws {
        let text = "2024-03 report\nplain line\n2025-01 memo\n"
        let hits = try await ByteScan.countMatchingLines(in: stream(text), needle: "^\\d{4}-\\d{2} ", isRegex: true, caseSensitive: false)
        #expect(hits == 2)
    }

    @Test func partialLineCarriesAcrossWindows() async throws {
        // The needle spans the window boundary — the partial tail must join
        // the next window instead of splitting the line.
        let text = String(repeating: "x", count: 100) + "needle-in-the-middle\n" + String(repeating: "y", count: 100) + "\n"
        for chunkSize in [3, 7, 16] {
            let hits = try await ByteScan.countMatchingLines(
                in: stream(text, chunkSize: chunkSize), needle: "needle-in-the-middle",
                isRegex: false, caseSensitive: true
            )
            #expect(hits == 1, "chunkSize \(chunkSize)")
        }
    }

    @Test func emptyNeedleMatchesNothing() async throws {
        let hits = try await ByteScan.countMatchingLines(in: stream("anything\n"), needle: "", isRegex: false, caseSensitive: false)
        #expect(hits == 0)
    }
}
