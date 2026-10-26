// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import FileOpsKit
import Foundation
import Testing
import VFSKit

// T-30 (F-16): the read-only virtual folder of search results — flattening,
// duplicate-name addressing, origin delegation for reads (F-3/F-5), the
// write-path refusal and the copy-through-unified-queue path.

@Suite("SearchResultVFS (F-16, T-30)")
struct SearchResultVFSTests {

    private func makeOriginWithFiles() throws -> (LocalVFS, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sr-vfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vfs = LocalVFS(at: root, instanceID: VFSInstanceID(kind: .localDisk, specID: "sr-origin"))
        try Data("alpha payload".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("beta payload".utf8).write(to: root.appendingPathComponent("dup.txt"))
        return (vfs, root)
    }

    @Test func flattensHitsAndDelegatesReads() async throws {
        let (origin, root) = try makeOriginWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try await origin.listDirectory(at: VFSPath(root: origin.id))
        let aHit = listing.first { $0.name == "a.txt" }!
        let dupHit = listing.first { $0.name == "dup.txt" }!

        // Two hits with the SAME name stay addressable (component[0] = index).
        let vfs = SearchResultVFS(hits: [
            .init(item: aHit, origin: origin),
            .init(item: dupHit, origin: origin),
        ])
        let folder = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(folder.count == 2)
        #expect(folder.allSatisfy { $0.id.root.kind == .searchResults })
        #expect(Set(folder.map { $0.name }) == ["a.txt", "dup.txt"])
        #expect(folder[0].id != folder[1].id)

        // metadata + openRead delegate to the origin (F-3/F-5 foundation).
        let meta = try await vfs.metadata(of: folder[1].id)
        #expect(meta.name == "dup.txt")
        #expect(meta.attributes.size == 12)
        let stream = try await vfs.openRead(folder[0].id)
        var data = Data()
        while let chunk = try await stream.readChunk(max: 4096) { data.append(chunk) }
        #expect(data == Data("alpha payload".utf8))
    }

    @Test func writePathsAreRefused() async throws {
        let (origin, root) = try makeOriginWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try await origin.listDirectory(at: VFSPath(root: origin.id))
        let vfs = SearchResultVFS(hits: listing.map { .init(item: $0, origin: origin) })
        let path = VFSPath(root: vfs.id, components: ["0", "a.txt"])
        do {
            _ = try await vfs.createDirectory("x", in: VFSPath(root: vfs.id))
            Issue.record("expected vfsUnsupported")
        } catch { /* expected */ }
        do {
            try await vfs.delete([path], toTrash: false)
            Issue.record("expected vfsUnsupported")
        } catch { /* expected */ }
        do {
            _ = try await vfs.openWrite(path, replace: true)
            Issue.record("expected vfsUnsupported")
        } catch { /* expected */ }
    }

    /// F-5 through the virtual folder: one `.copy` plan over SearchResultVFS
    /// rides the unified queue; bytes land in the destination (origin
    /// delegation inside `copyContents`).
    @Test func copyFromResultsThroughUnifiedQueue() async throws {
        let (origin, root) = try makeOriginWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let destURL = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let dest = LocalVFS(at: destURL, instanceID: VFSInstanceID(kind: .localDisk, specID: "sr-dest"))

        let listing = try await origin.listDirectory(at: VFSPath(root: origin.id))
        let hits = listing.filter { $0.name == "a.txt" || $0.name == "dup.txt" }
        let vfs = SearchResultVFS(hits: hits.map { .init(item: $0, origin: origin) })
        let folder = try await vfs.listDirectory(at: VFSPath(root: vfs.id))

        let plan = try await TransferPlanner.planCopy(
            sources: folder.map { $0.id },
            into: VFSPath(root: dest.id),
            source: vfs,
            destination: dest
        )
        let executor = OperationExecutor(source: vfs, destination: dest, journal: JournalStorage())
        let (_, events) = await executor.enqueue(plan, policy: ConflictPolicy(defaultResolution: .overwrite), source: vfs, destination: dest)
        for await event in events {
            if case .finished = event.phase { break }
        }

        #expect((FileManager.default.contents(atPath: destURL.appendingPathComponent("a.txt").path) ?? Data()) == Data("alpha payload".utf8))
        #expect((FileManager.default.contents(atPath: destURL.appendingPathComponent("dup.txt").path) ?? Data()) == Data("beta payload".utf8))
    }
}
