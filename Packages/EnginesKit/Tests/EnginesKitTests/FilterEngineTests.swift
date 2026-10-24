// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EnginesKit

// T-07: FilterEngine semantics and the F-10 budget (docs/SDD/06 §6.6:
// substring by default, simple fuzzy, ≤ 50 ms on 50 000 names, Int-index
// passes with prefix memoization).

@Test func substringMatchesCaseInsensitively() {
    #expect(FilterEngine.matches(name: "MyCommander.APP", query: "comma", style: .substring))
    #expect(FilterEngine.matches(name: "MyCommander.APP", query: "APP", style: .substring))
    #expect(!FilterEngine.matches(name: "MyCommander.APP", query: "commanderx", style: .substring))
}

@Test func emptyQueryMatchesEverything() {
    #expect(FilterEngine.matches(name: "anything", query: "", style: .substring))
    #expect(FilterEngine.matches(name: "", query: "", style: .fuzzy))
    let result = FilterEngine.filter(names: ["a", "b"], query: "", style: .substring)
    #expect(result == [0, 1])
}

@Test func fuzzyMatchesSubsequencesInOrder() {
    #expect(FilterEngine.matches(name: "my-commander.txt", query: "mcmd", style: .fuzzy))
    #expect(FilterEngine.matches(name: "my-commander.txt", query: "tx", style: .fuzzy))
    // Order matters: «dm» never appears in that order.
    #expect(!FilterEngine.matches(name: "my-commander.txt", query: "txtm", style: .fuzzy))
    #expect(!FilterEngine.matches(name: "readme.md", query: "z", style: .fuzzy))
}

@Test func coldFilterPreservesAscendingOrderAndIndices() {
    let names = ["Alpha.txt", "beta.md", "ALPHAbet", "gamma"]
    let result = FilterEngine.filter(names: names, query: "alpha", style: .substring)
    #expect(result == [0, 2])
}

@Test func incrementalPassKeepsOnlyPreviousCandidates() {
    // Prefix extension: «al» → «alp» re-tests only the previous result.
    let names = ["Alpha.txt", "beta.md", "ALPHAbet", "gamma"]
    let stepOne = FilterEngine.filter(names: names, query: "al", style: .substring)
    #expect(stepOne == [0, 2])

    let prepared = names.map(FilterEngine.prepare)
    let stepTwo = FilterEngine.filter(
        preparedNames: prepared,
        query: FilterEngine.prepare("alp"),
        style: .substring,
        candidates: stepOne
    )
    #expect(stepTwo == [0, 2])

    // A non-extension query restarts from the full set (nil candidates).
    let restart = FilterEngine.filter(
        preparedNames: prepared,
        query: FilterEngine.prepare("gamma"),
        style: .substring,
        candidates: nil
    )
    #expect(restart == [3])
}

@Test func filterPassOverFiftyThousandNamesStaysUnderFiftyMilliseconds() {
    var names: [String] = []
    names.reserveCapacity(50_000)
    for index in 0 ..< 50_000 {
        names.append("leaf-\(index % 4096)-\(index).\(index % 3 == 0 ? "png" : "txt")")
    }
    let prepared = names.map(FilterEngine.prepare)
    let query = FilterEngine.prepare("leaf-")

    // Cold pass (after a listing change).
    let coldStarted = Date()
    let cold = FilterEngine.filter(preparedNames: prepared, query: query, style: .substring, candidates: nil)
    let coldElapsed = Date().timeIntervalSince(coldStarted)
    #expect(cold.count > 0)

    // Incremental stroke over the previous result (per-keystroke path).
    let strokeStarted = Date()
    let strokeCount = FilterEngine.filter(
        preparedNames: prepared,
        query: FilterEngine.prepare("leaf-1"),
        style: .substring,
        candidates: cold
    ).count
    let strokeElapsed = Date().timeIntervalSince(strokeStarted)
    #expect(strokeCount > 0)

    // F-10 acceptance: filtering 50 000 names ≤ 50 ms (incrementally).
    #expect(coldElapsed < 0.05, "cold filter took \(coldElapsed)s")
    #expect(strokeElapsed < 0.05, "incremental stroke took \(strokeElapsed)s")
}
