// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import Testing
@testable import EnginesKit

// T-29 acceptance (F-15, docs/SDD/12): the sync diff engine — matrix
// onlyA/onlyB/differing/equal, metadata vs content modes, action scripts
// (direction + mirror, descendant de-dup), the HashCache invalidation and
// the 100 000-entry diff budget ≤ 3 s.

/// In-memory VFS fake: a flat map keyed by full path string. `openRead`
/// counts hits so the HashCache test can prove the second pass re-hashes.
final class SyncFakeVFS: VFS, @unchecked Sendable {
    struct Node {
        var isDirectory: Bool
        var data: Data
        var modified: Date
    }

    let id: VFSInstanceID
    let capabilities = VFSCapabilities(canWrite: true, canDelete: true, canRename: true)
    private var nodes: [String: Node] = [:]
    private let readLock = NSLock()
    private var _readCount = 0
    /// How many times `openRead` was called (the cache-effectiveness probe).
    var readCount: Int {
        readLock.lock()
        defer { readLock.unlock() }
        return _readCount
    }

    private func bumpReadCount() {
        readLock.lock()
        defer { readLock.unlock() }
        _readCount += 1
    }

    init(specID: String) {
        id = VFSInstanceID(kind: .localDisk, specID: specID)
    }

    func put(_ path: String, data: Data = Data(), modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        nodes[path] = Node(isDirectory: false, data: data, modified: modified)
    }

    func putDirectory(_ path: String) {
        nodes[path] = Node(isDirectory: true, data: Data(), modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func item(_ path: String) -> VFSItem? {
        guard let node = nodes[path] else { return nil }
        let components = path.split(separator: "/").map(String.init)
        let vpath = VFSPath(root: id, components: components)
        return VFSItem(
            id: vpath,
            instance: id,
            name: components.last ?? "",
            kind: node.isDirectory ? .directory : .file,
            attributes: VFSItemAttributes(
                size: Int64(node.data.count),
                created: nil,
                modified: node.modified,
                posixPermissions: nil,
                owner: nil,
                group: nil,
                isHidden: false,
                isReadOnly: false,
                tags: [],
                urlResourceMeta: [:]
            )
        )
    }

    func listDirectory(at path: VFSPath) async throws -> [VFSItem] {
        let prefix = path.components.joined(separator: "/")
        var children: [VFSItem] = []
        for key in nodes.keys {
            let relative: Substring
            if prefix.isEmpty {
                relative = key[...]
            } else {
                guard key.hasPrefix(prefix + "/") else { continue }
                relative = key.dropFirst(prefix.count + 1)
            }
            guard !relative.contains("/") else { continue }   // direct children only
            if let child = item(key) { children.append(child) }
        }
        return children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func metadata(of path: VFSPath) async throws -> VFSItem {
        guard let found = item(path.components.joined(separator: "/")) else {
            throw MCError.vfsNotFound(path)
        }
        return found
    }

    func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 { 0 }

    func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath {
        let full = (parent.components + [name]).joined(separator: "/")
        putDirectory(full)
        return VFSPath(root: id, components: parent.components + [name])
    }

    func rename(_ path: VFSPath, to name: String) async throws -> VFSPath {
        fatalError("not needed in SyncReporterTests")
    }

    func delete(_ paths: [VFSPath], toTrash: Bool) async throws {
        fatalError("not needed in SyncReporterTests")
    }

    func copyContents(from: VFSPath, to: any VFS, target: VFSPath) async throws {
        fatalError("not needed in SyncReporterTests")
    }

    func openRead(_ path: VFSPath) async throws -> any ByteStream {
        bumpReadCount()
        guard let node = nodes[path.components.joined(separator: "/")], !node.isDirectory else {
            throw MCError.vfsNotFound(path)
        }
        return SyncFakeStream(data: node.data)
    }

    func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter {
        fatalError("not needed in SyncReporterTests")
    }

    func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws {
        fatalError("not needed in SyncReporterTests")
    }
}

final class SyncFakeStream: ByteStream, @unchecked Sendable {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    var length: Int64 { Int64(data.count) }

    func readChunk(max: Int) async throws -> Data? {
        guard offset < data.count else { return nil }
        let end = min(offset + max, data.count)
        let chunk = data.subdata(in: offset ..< end)
        offset = end
        return chunk
    }
}

// MARK: helpers

private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

private func makeSides() -> (SyncFakeVFS, SyncFakeVFS) {
    (SyncFakeVFS(specID: "sync-a"), SyncFakeVFS(specID: "sync-b"))
}

private func state(of path: String, in report: SyncReport) -> SyncEntryState? {
    report.entries.first { $0.relativePath == path }?.state
}

@Suite("SyncReporter (F-15, T-29)")
struct SyncReporterTests {

    @Test func identicalTreesAreAllEqual() async throws {
        let (a, b) = makeSides()
        a.put("same.txt", data: Data("x".utf8))
        b.put("same.txt", data: Data("y".utf8))
        a.putDirectory("sub")
        b.putDirectory("sub")
        a.put("sub/deep.bin", data: Data(0...9))
        b.put("sub/deep.bin", data: Data(0...9))
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(report.entries.allSatisfy { $0.state == .equal })
        #expect(report.count(.equal) == 3)
        #expect(SyncReporter.actionScript(from: report, direction: .aToB, mirror: true).isEmpty)
    }

    @Test func disjointTreesProduceOnlyAAndOnlyB() async throws {
        let (a, b) = makeSides()
        a.put("left.txt")
        b.put("right.txt")
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(state(of: "left.txt", in: report) == .onlyA)
        #expect(state(of: "right.txt", in: report) == .onlyB)
    }

    @Test func sizeAndMtimeDriveMetadataDiff() async throws {
        let (a, b) = makeSides()
        a.put("size-diff.txt", data: Data("aaaa".utf8))
        b.put("size-diff.txt", data: Data("a".utf8))
        // mtime beyond the 1 s tolerance → differing.
        a.put("time-diff.txt", modified: baseTime)
        b.put("time-diff.txt", modified: baseTime.addingTimeInterval(5))
        // mtime within the tolerance → equal.
        a.put("time-close.txt", modified: baseTime)
        b.put("time-close.txt", modified: baseTime.addingTimeInterval(0.4))
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(state(of: "size-diff.txt", in: report) == .differing)
        #expect(state(of: "time-diff.txt", in: report) == .differing)
        #expect(state(of: "time-close.txt", in: report) == .equal)
    }

    @Test func typeMismatchIsDiffering() async throws {
        let (a, b) = makeSides()
        a.putDirectory("thing")
        b.put("thing", data: Data("file".utf8))
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(state(of: "thing", in: report) == .differing)
    }

    @Test func contentModeCatchesSameMetadataDifferentBytes() async throws {
        let (a, b) = makeSides()
        a.put("twin.bin", data: Data("payload-one".utf8))
        b.put("twin.bin", data: Data("payload-two".utf8), modified: baseTime)
        let metadata = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(state(of: "twin.bin", in: metadata) == .equal)
        let content = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .content)
        #expect(state(of: "twin.bin", in: content) == .differing)
    }

    @Test func contentModeUsesCacheOnSecondPass() async throws {
        let (a, b) = makeSides()
        a.put("cached.bin", data: Data("cache-me".utf8))
        b.put("cached.bin", data: Data("cache-me".utf8), modified: baseTime)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("hashcache-\(UUID().uuidString).sqlite")
        let cache = try HashCache(url: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        _ = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .content, cache: cache)
        let readsAfterFirst = a.readCount + b.readCount
        #expect(readsAfterFirst == 2)   // one hash per side
        _ = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .content, cache: cache)
        #expect(a.readCount + b.readCount == readsAfterFirst)   // served from the cache
    }

    // MARK: action script

    @Test func actionScriptDirectionAToB() async throws {
        let (a, b) = makeSides()
        a.put("copy-me.txt")
        a.put("changed.txt", data: Data("new".utf8))
        b.put("changed.txt", data: Data("old".utf8), modified: baseTime.addingTimeInterval(10))
        b.put("stays.txt")
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        let script = SyncReporter.actionScript(from: report, direction: .aToB, mirror: false)
        #expect(script == [
            SyncAction(kind: .copyAToB, relativeComponents: ["changed.txt"]),
            SyncAction(kind: .copyAToB, relativeComponents: ["copy-me.txt"])
        ])
    }

    @Test func actionScriptMirrorDeletesReceiversExtras() async throws {
        let (a, b) = makeSides()
        a.put("kept.txt")
        b.put("extra.txt")
        b.putDirectory("extra-dir")
        b.put("extra-dir/inner.txt")
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        let script = SyncReporter.actionScript(from: report, direction: .aToB, mirror: true)
        // The DIRECTORY delete covers its subtree — inner.txt is not repeated;
        // script order follows the sorted report (extra-dir < extra.txt).
        #expect(script == [
            SyncAction(kind: .deleteInB, relativeComponents: ["extra-dir"]),
            SyncAction(kind: .deleteInB, relativeComponents: ["extra.txt"]),
            SyncAction(kind: .copyAToB, relativeComponents: ["kept.txt"])
        ])
    }

    @Test func actionScriptSkipsDescendantsOfCopiedDirectory() async throws {
        let (a, b) = makeSides()
        a.putDirectory("fresh")
        a.put("fresh/a.txt")
        a.put("fresh/nested/b.txt")
        a.put("outside.txt")
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        let script = SyncReporter.actionScript(from: report, direction: .aToB, mirror: false)
        #expect(script == [
            SyncAction(kind: .copyAToB, relativeComponents: ["fresh"]),
            SyncAction(kind: .copyAToB, relativeComponents: ["outside.txt"])
        ])
    }

    // MARK: HashCache invalidation

    @Test func hashCacheInvalidatesOnMtimeOrSizeChange() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hashcache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = try HashCache(url: url)
        let key = HashCache.Key(instance: "inst", path: "a.txt")
        let digest = Data([0x01, 0x02])
        cache.store(key, mtime: baseTime, size: 10, digest: digest)
        #expect(cache.lookup(key, mtime: baseTime, size: 10) == digest)
        // mtime moved → miss.
        #expect(cache.lookup(key, mtime: baseTime.addingTimeInterval(1), size: 10) == nil)
        // size moved → miss.
        #expect(cache.lookup(key, mtime: baseTime, size: 11) == nil)
        // Re-store refreshes.
        let fresh = Data([0x03])
        cache.store(key, mtime: baseTime.addingTimeInterval(2), size: 11, digest: fresh)
        #expect(cache.lookup(key, mtime: baseTime.addingTimeInterval(2), size: 11) == fresh)
    }

    // MARK: budget (F-15 acceptance: 100 000 entries ≤ 3 s)

    @Test func hundredThousandEntriesUnderThreeSeconds() async throws {
        let (a, b) = makeSides()
        for index in 0 ..< 50_000 {
            let name = "file-\(String(index).leftPadSync(6)).bin"
            a.put(name, data: Data("a\(index)".utf8))
            b.put(name, data: Data("a\(index)".utf8), modified: baseTime)
        }
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        }
        #expect(elapsed < .seconds(3))
        // Sanity on the smaller slice too: the script stays empty.
        let report = try await SyncReporter.compare(a: a, at: VFSPath(root: a.id), b: b, at: VFSPath(root: b.id), mode: .metadata)
        #expect(report.count(.equal) == 50_000)
        #expect(SyncReporter.actionScript(from: report, direction: .aToB, mirror: true).isEmpty)
    }
}

extension String {
    /// Zero-pads (test-only mirror of the rename pad).
    fileprivate func leftPadSync(_ width: Int) -> String {
        guard count < width else { return self }
        return String(repeating: "0", count: width - count) + self
    }
}
