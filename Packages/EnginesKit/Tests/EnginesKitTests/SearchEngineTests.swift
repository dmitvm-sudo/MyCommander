// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import EnginesKit

// T-30 (F-16): the search engine over the fake VFS — mask/size/date filters,
// content modes, the result limit, instant cancellation and the Spotlight
// predicate builder (the pure part of the Spotlight-first path).

@Suite("SearchEngine (F-16, T-30)")
struct SearchEngineTests {

    private func makeTree() -> (SyncFakeVFS, VFSPath) {
        let vfs = SyncFakeVFS(specID: "search-vfs")
        vfs.put("report-2024.txt", data: Data("income report\nnothing else\n".utf8))
        vfs.put("notes.md", data: Data("todo: finish report\n".utf8))
        vfs.put("empty.bin", data: Data())
        vfs.put("big.log", data: Data("report inside\n".utf8), modified: Date(timeIntervalSince1970: 1_600_000_000))
        vfs.putDirectory("docs")
        vfs.put("docs/inner.txt", data: Data("report deep\n".utf8))
        let root = VFSPath(root: vfs.id)
        return (vfs, root)
    }

    @Test func nameMaskFiltersEverythingElse() async throws {
        let (vfs, root) = makeTree()
        let result = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(nameMask: FileMask(["*.txt"]))
        )
        let names = Set(result.hits.map { $0.item.name })
        #expect(names == ["report-2024.txt", "inner.txt"])
        #expect(result.hits.allSatisfy { $0.contentMatches == nil })
        #expect(!result.truncated)
    }

    @Test func sizeAndDateFiltersApply() async throws {
        let (vfs, root) = makeTree()
        let bySize = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(minSize: 10)
        )
        #expect(Set(bySize.hits.map { $0.item.name }) == ["report-2024.txt", "notes.md", "big.log", "inner.txt"])

        let byDate = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(modifiedBefore: Date(timeIntervalSince1970: 1_650_000_000))
        )
        #expect(Set(byDate.hits.map { $0.item.name }) == ["big.log"])
    }

    @Test func contentLiteralAndCase() async throws {
        let (vfs, root) = makeTree()
        let result = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(content: "report", caseSensitive: false)
        )
        // report-2024.txt: 1 line; notes.md: 1; big.log: 1; docs/inner.txt: 1.
        #expect(result.hits.count == 4)
        #expect(result.hits.allSatisfy { ($0.contentMatches ?? 0) == 1 })

        let sensitive = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(content: "Income", caseSensitive: true)
        )
        #expect(sensitive.hits.isEmpty)
    }

    @Test func contentRegexMatches() async throws {
        let (vfs, root) = makeTree()
        let result = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(content: "^todo:", contentIsRegex: true)
        )
        #expect(Set(result.hits.map { $0.item.name }) == ["notes.md"])
    }

    @Test func maxFileSizeCapSkipsContent() async throws {
        let (vfs, root) = makeTree()
        // Make big.log the oversized one (100+ bytes) so the cap separates it
        // from the small hits.
        vfs.put("big.log", data: Data(repeating: 0x61, count: 100) + Data("report inside\n".utf8), modified: Date(timeIntervalSince1970: 1_600_000_000))
        let result = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(content: "report", maxFileSize: 50)
        )
        // big.log is over the cap → excluded; small files still hit.
        #expect(!result.hits.contains { $0.item.name == "big.log" })
        #expect(Set(result.hits.map { $0.item.name }) == ["report-2024.txt", "notes.md", "inner.txt"])
    }

    @Test func resultLimitTruncates() async throws {
        let (vfs, root) = makeTree()
        let result = try await SearchEngine.search(
            in: vfs, at: root,
            query: SearchQuery(resultLimit: 2)
        )
        #expect(result.truncated)
        #expect(result.hits.count == 2)
    }

    @Test func cancellationThrowsInstantly() async throws {
        let (vfs, root) = makeTree()
        let task = Task {
            try await SearchEngine.search(in: vfs, at: root, query: SearchQuery())
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected — instant cancel (F-16 acceptance)
        }
    }

    // MARK: Spotlight predicate (the pure part of the Spotlight-first path)

    @Test func spotlightPredicateBuildsAndStaysNilWithoutFilters() {
        let root = URL(fileURLWithPath: "/tmp")
        #expect(NSMetadataQueryBridge.predicate(root: root, query: SearchQuery()) == nil)

        let mask = NSMetadataQueryBridge.predicate(
            root: root, query: SearchQuery(nameMask: FileMask(["*.txt", "a?c.log"]))
        )
        let format = mask?.predicateFormat ?? ""
        #expect(format.contains("kMDItemFSName"))
        #expect(format.contains("%.txt"))
        #expect(format.contains("a_c.log"))

        let sizes = NSMetadataQueryBridge.predicate(
            root: root, query: SearchQuery(minSize: 10, maxSize: 100, modifiedAfter: Date(timeIntervalSince1970: 0))
        )
        let sizeFormat = sizes?.predicateFormat ?? ""
        #expect(sizeFormat.contains("kMDItemFSSize"))
        #expect(sizeFormat.contains("kMDItemFSContentChangeDate"))
    }
}
