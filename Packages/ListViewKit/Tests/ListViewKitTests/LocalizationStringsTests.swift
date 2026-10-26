// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import ListViewKit

// T-35 (F-22): the single MASTER catalog lives in
// `App/Resources/{en,ru}.lproj/Localizable.strings` — every package
// resolves through Bundle.main (the app bundle); the CLI SwiftPM build
// does NOT compile .xcstrings (T-35 probe lesson), so the runtime shape is
// classic .strings inside lproj directories. The test enforces:
//   (a) en/ru parity — same key sets, non-empty values both ways;
//   (b) every source key `String(localized: "…")` exists in the catalog;
//   (c) bidirectional completeness for FORMAT keys: a catalog key with
//       specifiers (`… %@`/`… %lld`) must be the prefix of an interpolated
//       call site (key + space), and the site must have been found;
//   (d) every catalog key must come from the sources (no orphans).

private func locRepoRoot() -> URL {
    // …/Packages/ListViewKit/Tests/ListViewKitTests/<file> → repo root:
    // dir + 3 ups = Packages/, + 1 up = repository root.
    URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
        .appendingPathComponent("../../..")
        .appendingPathComponent("..")
        .standardized
}

/// Scans the repo sources (Packages/**/Sources + App, Tests excluded) for
/// `String(localized: "…")`. Returns: exact (plain) keys, interpolation
/// prefixes (the literal before the first `\(`), and KEY-SHAPED literals
/// (`dotted.lowerStart` — e.g. menu-spec titleKeys and column tuples) from
/// every file that mentions the locator: those are the indirect catalog
/// keys (LocalizationValue sites, ternary select/deselect, MenuBuilder
/// specs); the parity test needs them for the no-orphan check.
private func locScanSources(root: URL) -> (plain: Set<String>, interpPrefixes: Set<String>, keyShaped: Set<String>) {
    var plain: Set<String> = []
    var interpPrefixes: Set<String> = []
    var keyShaped: Set<String> = []
    let keyShape = /^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_]+)+$/
    for topDir in ["Packages", "App"] {
        let base = root.appendingPathComponent(topDir, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { continue }
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue else {
                let leaf = url.lastPathComponent
                if leaf == "Tests" || leaf == ".build" { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard source.contains("String(localized:") else { continue }

            // Indirect (spec/tuple/ternary) key-shaped literals of THIS file.
            for match in source.matches(of: /"([^"\n]+)"/) {
                let candidate = String(match.1)
                if candidate.firstMatch(of: keyShape) != nil {
                    keyShaped.insert(candidate)
                }
            }

            var rest = Substring(source)
            let needle = "String(localized: \""
            while let at = rest.range(of: needle) {
                rest = rest[at.upperBound...]
                var glyph = [Character]()
                var hitInterpolation = false
                scan: while let ch = rest.first {
                    rest = rest.dropFirst()
                    switch ch {
                    case "\\":                                  // escape / interpolation
                        if let next = rest.first {
                            rest = rest.dropFirst()
                            if next == "(" {                    // start of interpolation
                                hitInterpolation = true
                                break scan
                            }
                            glyph.append(next == "n" ? "\n" : next)
                        } else { break scan }
                    case "\"":
                        break scan                              // literal ends
                    default:
                        glyph.append(ch)
                    }
                }
                let literal = String(glyph)
                if hitInterpolation {
                    // Swift's paren-depth is modelled coarsely — the prefix
                    // ends at the FIRST interpolation, so cut any trailing
                    // `)`/space residue the scanner captured (keys never end
                    // with `)`).
                    let head = literal.reversed().drop { $0 == ")" || $0 == " " }
                    interpPrefixes.insert(String(head.reversed()))
                } else {
                    plain.insert(literal)
                }
            }
        }
    }
    return (plain, interpPrefixes, keyShaped)
}

@MainActor
@Test func locCatalogParity() throws {
    let root = locRepoRoot()
    let enURL = root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")
    let ruURL = root.appendingPathComponent("App/Resources/ru.lproj/Localizable.strings")
    guard let en = NSDictionary(contentsOf: enURL) as? [String: String] else {
        Issue.record("EN catalog missing: \(enURL.path)"); return
    }
    guard let ru = NSDictionary(contentsOf: ruURL) as? [String: String] else {
        Issue.record("RU catalog missing: \(ruURL.path)"); return
    }
    #expect(Set(en.keys) == Set(ru.keys))
    for (key, value) in en {
        #expect(!value.isEmpty, "empty EN value for \(key)")
        #expect(!(ru[key] ?? "").isEmpty, "empty RU value for \(key)")
    }
}

@MainActor
@Test func locSourceKeysCoveredBidirectionally() throws {
    let root = locRepoRoot()
    let catalogURL = root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")
    guard let catalog = NSDictionary(contentsOf: catalogURL) as? [String: String] else {
        Issue.record("catalog missing"); return
    }
    let scanned = locScanSources(root: root)
    #expect(!scanned.plain.isEmpty, "scanner found no plain keys")

    // (a) every DIRECT source key is in the catalog exactly; (b) every INFO
    // source (menu specs, column tuples, ternary masks) key-shaped literal
    // is in the catalog as well; (c) no catalog key without a source.
    let formatKeys = Set(catalog.keys.filter { $0.contains("%") })
    let plainCatalog = Set(catalog.keys).subtracting(formatKeys)
    let knownSources = scanned.plain.union(scanned.keyShaped)
    let missing = plainCatalog.subtracting(knownSources)
    #expect(missing.isEmpty, "source keys without a catalog entry: \(missing.sorted())")
    let orphan = Set(catalog.keys).subtracting(knownSources).subtracting(formatKeys)
    #expect(orphan.isEmpty, "catalog keys not used in sources: \(orphan.sorted())")

    // (d) every format key is the «prefix + space» head of an interpolated
    // call site; specifiers live on the value side, so only the prefix
    // matters here.
    for formatKey in formatKeys {
        let head = formatKey.split(separator: "%", maxSplits: 1).first
        let prefix = String(head ?? formatKey[...]).trimmingCharacters(in: .whitespaces)
        let matched = scanned.interpPrefixes.contains { literal in
            literal.trimmingCharacters(in: .whitespaces) == prefix
        }
        #expect(matched, "format key without an interpolation site: \(formatKey)")
    }
}

