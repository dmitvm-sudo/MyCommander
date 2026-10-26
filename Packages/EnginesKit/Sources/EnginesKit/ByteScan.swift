// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.6 (уточнение T-30) + F-16 — the streaming content
// scan. LINE-BASED over 8 MB windows: a window is decoded as UTF-8 (lossy),
// matched line by line (literal substring or NSRegularExpression), and the
// partial last line carries over to the next window — no false line splits,
// no materializing the whole file.

public enum ByteScan {
    /// Counts matching lines in the stream. `needle` empty → always 0.
    public static func countMatchingLines(
        in stream: any ByteStream,
        needle: String,
        isRegex: Bool,
        caseSensitive: Bool
    ) async throws -> Int {
        guard !needle.isEmpty else { return 0 }
        let regex: NSRegularExpression?
        if isRegex {
            regex = try? NSRegularExpression(
                pattern: needle,
                options: caseSensitive ? [] : [.caseInsensitive]
            )
            guard regex != nil else { return 0 }   // invalid pattern → no matches
        } else {
            regex = nil
        }
        let literal = caseSensitive ? needle : needle.lowercased()
        var window = Data()
        var matches = 0
        while let chunk = try await stream.readChunk(max: 8 << 20) {
            if Task.isCancelled { throw CancellationError() }
            window.append(chunk)
            // Process only COMPLETE lines; the partial tail waits for more.
            var processed = 0
            while let newline = window[processed...].firstIndex(of: 0x0A) {
                let lineData = window[processed ..< newline]
                processed = window.index(after: newline)
                if lineMatches(lineData, needle: literal, caseSensitive: caseSensitive, regex: regex) {
                    matches += 1
                }
            }
            window.removeSubrange(window.startIndex ..< window.startIndex + processed)
        }
        // The final unterminated line.
        if !window.isEmpty, lineMatches(window, needle: literal, caseSensitive: caseSensitive, regex: regex) {
            matches += 1
        }
        return matches
    }

    private static func lineMatches(
        _ lineData: Data,
        needle: String,
        caseSensitive: Bool,
        regex: NSRegularExpression?
    ) -> Bool {
        let line = String(decoding: lineData, as: UTF8.self)
        if let regex {
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }
        if caseSensitive {
            return line.contains(needle)
        }
        // The needle arrives pre-lowercased for the insensitive mode.
        return line.lowercased().contains(needle)
    }
}
