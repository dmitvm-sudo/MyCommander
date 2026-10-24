// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin
import Testing
import DomainKit
@testable import VFSKit

// T-04 integration matrix (docs/SDD/12): list / stat / mkdir / rename / delete /
// copy on REAL temporary directories + attributes (xattr/тэги/FinderInfo).

private func temporaryRoot(_ label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("mclfs-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func testVFS(_ label: String) -> (LocalVFS, URL) {
    let root = temporaryRoot(label)
    let vfs = LocalVFS(at: root, instanceID: VFSInstanceID(kind: .localDisk, specID: "local-test-\(label)"))
    return (vfs, root)
}

private func path(_ vfs: LocalVFS, _ components: [String]) -> VFSPath {
    VFSPath(root: vfs.id, components: components)
}

private func generatedData(bytes count: Int, seed: UInt64 = 88172645463325252) -> Data {
    var state = seed ^ UInt64(count)
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state)
    }
    return Data(bytes)
}

private func writeChunked(_ vfs: LocalVFS, at components: [String], chunks: [Data]) async throws {
    let target = path(vfs, components)
    let writer = try await vfs.openWrite(target, replace: false)
    for chunk in chunks { try await writer.write(chunk) }
    try await writer.finish(committingTo: target)
}

private func readAll(_ stream: any ByteStream, chunkSize: Int = 64 * 1024) async throws -> Data {
    var result = Data()
    while let chunk = try await stream.readChunk(max: chunkSize) {
        result.append(chunk)
    }
    return result
}

@Test func statMetadataOnFreshFilesReportsKindSizeDates() async throws {
    let (vfs, root) = testVFS("stat")
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = generatedData(bytes: 4096, seed: 7)
    try await writeChunked(vfs, at: ["seed.bin"], chunks: [expected])

    let item = try await vfs.metadata(of: path(vfs, ["seed.bin"]))
    guard case .file = item.kind else {
        Issue.record("expected a file item, got \(item.kind)")
        return
    }
    #expect(item.attributes.size == 4096)
    #expect(item.attributes.modified != nil)
    #expect(item.attributes.created != nil)
    #expect(item.attributes.posixPermissions != nil)
}

@Test func mkdirShowsListingsWithKindsAndDisplayURLs() async throws {
    let (vfs, root) = testVFS("list")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await vfs.createDirectory("alpha", in: path(vfs, []))
    _ = try await vfs.createDirectory("gamma", in: path(vfs, ["alpha"]))
    try await writeChunked(vfs, at: ["alpha", "report.txt"], chunks: [Data("report".utf8)])

    let items = try await vfs.listDirectory(at: path(vfs, ["alpha"]))
    #expect(items.map(\.name) == ["gamma", "report.txt"])
    let directoryItem = items.first { $0.name == "gamma" }!
    guard case .directory = directoryItem.kind else {
        Issue.record("gamma should list as a directory")
        return
    }
    #expect(directoryItem.id.displayURL != nil)
    #expect(directoryItem.id.components == ["alpha", "gamma"])
    #expect(directoryItem.id.root == vfs.id)
}

@Test func createDirectoryIsIdempotentButOccupiedByNameDenied() async throws {
    let (vfs, root) = testVFS("mkdir")
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = path(vfs, [])
    let first = try await vfs.createDirectory("x", in: rootPath)
    let second = try await vfs.createDirectory("x", in: rootPath)
    #expect(first == second)

    try await writeChunked(vfs, at: ["f.txt"], chunks: [Data("z".utf8)])
    await #expect(throws: MCError.self) {
        _ = try await vfs.createDirectory("f.txt", in: rootPath)
    }
}

@Test func slashAndEmptyNamesAreEINVALLike() async throws {
    let (vfs, root) = testVFS("einval")
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = path(vfs, [])
    await #expect(throws: MCError.self) {
        _ = try await vfs.createDirectory("a/b", in: rootPath)
    }
    _ = try await vfs.createDirectory("x", in: rootPath)
    await #expect(throws: MCError.self) {
        _ = try await vfs.rename(path(vfs, ["x"]), to: "x/y")
    }
}

@Test func renameMovesWithinParentConflictsAndNotFound() async throws {
    let (vfs, root) = testVFS("rename")
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeChunked(vfs, at: ["a.txt"], chunks: [Data("aaa".utf8)])

    let renamed = try await vfs.rename(path(vfs, ["a.txt"]), to: "b.txt")
    #expect(renamed.components == ["b.txt"])
    await #expect(throws: MCError.self) { _ = try await vfs.metadata(of: path(vfs, ["a.txt"])) }
    #expect(try await vfs.metadata(of: renamed).attributes.size == 3)

    try await writeChunked(vfs, at: ["c.txt"], chunks: [Data("c".utf8)])
    await #expect(throws: MCError.self) {
        _ = try await vfs.rename(renamed, to: "c.txt")   // rename onto occupied name
    }
    await #expect(throws: MCError.self) {
        _ = try await vfs.rename(path(vfs, ["missing"]), to: "x.txt")
    }
}

@Test func deleteRemovesTreesAndReportsMissing() async throws {
    let (vfs, root) = testVFS("delete")
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = path(vfs, [])
    try await writeChunked(vfs, at: ["leaf.txt"], chunks: [Data("l".utf8)])
    _ = try await vfs.createDirectory("big", in: rootPath)
    _ = try await vfs.createDirectory("tree", in: path(vfs, ["big"]))
    try await writeChunked(vfs, at: ["big", "tree", "keep.bin"], chunks: [generatedData(bytes: 128)])

    try await vfs.delete([path(vfs, ["leaf.txt"]), path(vfs, ["big"])], toTrash: false)
    await #expect(throws: MCError.self) { _ = try await vfs.metadata(of: path(vfs, ["leaf.txt"])) }
    await #expect(throws: MCError.self) {
        _ = try await vfs.metadata(of: path(vfs, ["big", "tree", "keep.bin"]))
    }
    await #expect(throws: MCError.self) {
        _ = try await vfs.delete([path(vfs, ["ghost"])], toTrash: false)
    }
}

@Test func stagedWriteUsesTempThenRenameWithNoResidue() async throws {
    let (vfs, root) = testVFS("staging")
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let stagedURL = root.appendingPathComponent(".file.txt.mc-partial")
    let targetURL = root.appendingPathComponent("file.txt")

    let writer = try await vfs.openWrite(path(vfs, ["file.txt"]), replace: false)
    try await writer.write(generatedData(bytes: 1024))
    #expect(fm.fileExists(atPath: stagedURL.path) == true)      // temp visible before commit
    #expect(fm.fileExists(atPath: targetURL.path) == false)
    try await writer.finish(committingTo: path(vfs, ["file.txt"]))
    #expect(fm.fileExists(atPath: stagedURL.path) == false)     // residue swept by rename
    #expect(fm.fileExists(atPath: targetURL.path) == true)
}

@Test func localWriterFinishConflictsOnOccupiedTarget() async throws {
    let (vfs, root) = testVFS("finish-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    try await writeChunked(vfs, at: ["dup.txt"], chunks: [generatedData(bytes: 500)])

    let writer = try await vfs.openWrite(path(vfs, ["dup.txt"]), replace: false)
    try await writer.write(generatedData(bytes: 64))
    await #expect(throws: MCError.self) { try await writer.finish(committingTo: path(vfs, ["dup.txt"])) }

    let resident = try await vfs.metadata(of: path(vfs, ["dup.txt"]))
    #expect(resident.attributes.size == 500)
    #expect(fm.fileExists(atPath: root.appendingPathComponent(".dup.txt.mc-partial").path) == false)

    // Slot got released: a fresh write downstream is allowed.
    try await writeChunked(vfs, at: ["other.txt"], chunks: [Data("x".utf8)])
}

@Test func copyFileRoundTripsBytesAndDates() async throws {
    let (vfs, root) = testVFS("copy")
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = path(vfs, [])
    _ = try await vfs.createDirectory("alpha", in: rootPath)
    _ = try await vfs.createDirectory("beta", in: rootPath)
    let expected = generatedData(bytes: 2_500_000, seed: 99)
    try await writeChunked(vfs, at: ["alpha", "payload.bin"], chunks: [
        expected.prefix(1_000_000),
        expected.dropFirst(1_000_000).prefix(1_000_000),
        expected.suffix(500_000),
    ])

    try await vfs.copyContents(
        from: path(vfs, ["alpha", "payload.bin"]),
        to: vfs,
        target: path(vfs, ["beta"])
    )

    let copied = try await vfs.metadata(of: path(vfs, ["beta", "payload.bin"]))
    #expect(copied.attributes.size == 2_500_000)

    // utimes()-based setattr truncates to microseconds while stat returns
    // nanoseconds — exact Date equality is unattainable; compare with tolerance.
    let sourceItem = try await vfs.metadata(of: path(vfs, ["alpha", "payload.bin"]))
    if let copiedModified = copied.attributes.modified, let sourceModified = sourceItem.attributes.modified {
        #expect(abs(copiedModified.timeIntervalSince(sourceModified)) < 1.0)
    } else {
        Issue.record("dates lost in copy")
    }

    let received = try await readAll(try await vfs.openRead(path(vfs, ["beta", "payload.bin"])))
    #expect(received == expected)
}

@Test func copyDirectoryTreeMergesRecursively() async throws {
    let (vfs, root) = testVFS("copy-tree")
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = path(vfs, [])
    _ = try await vfs.createDirectory("alpha", in: rootPath)
    _ = try await vfs.createDirectory("nested", in: path(vfs, ["alpha"]))
    _ = try await vfs.createDirectory("beta", in: rootPath)
    try await writeChunked(vfs, at: ["alpha", "readme.md"], chunks: [Data("# tree".utf8)])
    let deep = generatedData(bytes: 777, seed: 3)
    try await writeChunked(vfs, at: ["alpha", "nested", "deep.txt"], chunks: [deep])

    try await vfs.copyContents(from: path(vfs, ["alpha"]), to: vfs, target: path(vfs, ["beta"]))

    let copiedTop = try await vfs.listDirectory(at: path(vfs, ["beta", "alpha"]))
    #expect(copiedTop.map(\.name).sorted() == ["nested", "readme.md"])
    let received = try await readAll(try await vfs.openRead(path(vfs, ["beta", "alpha", "nested", "deep.txt"])))
    #expect(received == deep)
}

@Test func copyBetweenTwoInstancesPreservesBytes() async throws {
    let (left, leftRoot) = testVFS("left")
    let (right, rightRoot) = testVFS("right")
    defer {
        try? FileManager.default.removeItem(at: leftRoot)
        try? FileManager.default.removeItem(at: rightRoot)
    }
    _ = try await left.createDirectory("alpha", in: path(left, []))
    try await writeChunked(left, at: ["alpha", "seeds.txt"], chunks: [Data("mc seeds v1".utf8)])

    try await left.copyContents(from: path(left, ["alpha", "seeds.txt"]), to: right, target: path(right, []))

    let received = try await readAll(try await right.openRead(path(right, ["seeds.txt"])))
    #expect(received == Data("mc seeds v1".utf8))
}

@Test func attributesRoundTripTagsPermissionsHiddenFinderInfo() async throws {
    let (vfs, root) = testVFS("attrs")
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeChunked(vfs, at: ["flagged.txt"], chunks: [Data("f".utf8)])
    let itemURL = root.appendingPathComponent("flagged.txt")

    let advanced = Date().addingTimeInterval(3_600)
    try await vfs.setAttributes(path(vfs, ["flagged.txt"])) {
        $0.posixPermissions = 0o640
        $0.modified = advanced
        $0.isHidden = true
        $0.tags = ["Red", "Blue"]
    }

    let flagged = try await vfs.metadata(of: path(vfs, ["flagged.txt"]))
    #expect(flagged.attributes.posixPermissions == 0o640)
    #expect(flagged.attributes.isHidden == true)
    #expect(flagged.attributes.tags == ["Red", "Blue"])
    if let modified = flagged.attributes.modified {
        #expect(abs(modified.timeIntervalSince(advanced)) < 60)
    } else {
        Issue.record("modified date lost")
    }

    // FinderInfo: direct xattr write → resurfaced inside urlResourceMeta (base64).
    let blob = Data((0 ..< 32).map { UInt8($0 * 7) })
    try LocalVFS.writeFinderInfo(blob, to: itemURL)
    let refreshed = try await vfs.metadata(of: path(vfs, ["flagged.txt"]))
    #expect(refreshed.attributes.urlResourceMeta[LocalVFS.finderInfoXattr] == blob.base64EncodedString())
}

private func requireSendable<T: Sendable>(_ value: T) { _ = value }

@Test func adapterIsSendableAndCarriesContractIdentity() throws {
    let (vfs, root) = testVFS("sendable")
    defer { try? FileManager.default.removeItem(at: root) }
    requireSendable(vfs)
    requireSendable(vfs.id)
    requireSendable(vfs.capabilities)
    #expect(vfs.capabilities.canWrite && vfs.capabilities.canRename && vfs.capabilities.canDelete)
    #expect(vfs.capabilities.canWatch == true)   // FSEventsWatcher wired in T-06
}
