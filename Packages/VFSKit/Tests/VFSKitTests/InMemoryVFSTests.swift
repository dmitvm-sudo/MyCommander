// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
@testable import VFSKit

// The T-03 acceptance scenario («Готово»: простой «list→copy» через InMemoryVFS)
// plus the fake semantics locks that later kits (FileOpsKit T-10/T-11) rely on.

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

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

private func writeChunked(_ vfs: InMemoryVFS, to path: VFSPath, chunks: [Data]) async throws {
    let writer = try await vfs.openWrite(path, replace: true)
    for chunk in chunks { try await writer.write(chunk) }
    try await writer.finish(committingTo: path)
}

private func readAll(_ stream: any ByteStream, chunkSize: Int = 64 * 1024) async throws -> Data {
    var result = Data()
    while let chunk = try await stream.readChunk(max: chunkSize) {
        result.append(chunk)
    }
    return result
}

@Test func stagedWriteBecomesListableWithSizeAndRevision() async throws {
    let vfs = InMemoryVFS(name: "list")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("docs", in: root)
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["docs", "report.txt"]), chunks: [generatedData(bytes: 4096)])

    let items = try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["docs"]))
    #expect(items.map(\.name) == ["report.txt"])
    #expect(items[0].attributes.size == 4096)
    guard case .file = items[0].kind else {
        Issue.record("expected a file item, got \(items[0].kind)")
        return
    }
    #expect(items[0].revision >= 2)   // createDirectory + commit bumped the epoch
}

@Test func listToCopyRoundTripPreservesBytesAcrossDirs() async throws {
    let vfs = InMemoryVFS(name: "roundtrip")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("alpha", in: root)
    _ = try await vfs.createDirectory("beta", in: root)

    let source = VFSPath(root: vfs.id, components: ["alpha", "payload.bin"])
    let expected = generatedData(bytes: 2_097_152)
    try await writeChunked(vfs, to: source, chunks: [
        expected.prefix(1_500_000),
        expected.suffix(expected.count - 1_500_000),
    ])

    try await vfs.copyContents(from: source, to: vfs, target: VFSPath(root: vfs.id, components: ["beta"]))

    let destinationDir = VFSPath(root: vfs.id, components: ["beta"])
    let items = try await vfs.listDirectory(at: destinationDir)
    #expect(items.map(\.name) == ["payload.bin"])
    #expect(items.first?.attributes.size == 2_097_152)

    let received = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["beta", "payload.bin"])))
    #expect(received == expected)
}

@Test func copyFileIntoAnotherInstanceThroughStaging() async throws {
    let sourceVFS = InMemoryVFS(name: "left")
    let destinationVFS = InMemoryVFS(name: "right")
    _ = try await sourceVFS.createDirectory("alpha", in: VFSPath(root: sourceVFS.id))
    let source = VFSPath(root: sourceVFS.id, components: ["alpha", "seeds.txt"])
    try await writeChunked(sourceVFS, to: source, chunks: [Data("mc seeds v1".utf8)])

    try await sourceVFS.copyContents(from: source, to: destinationVFS, target: VFSPath(root: destinationVFS.id))

    let received = try await readAll(try await destinationVFS.openRead(VFSPath(root: destinationVFS.id, components: ["seeds.txt"])))
    #expect(received == Data("mc seeds v1".utf8))
}

@Test func copyDirectoryMergesRecursively() async throws {
    let vfs = InMemoryVFS(name: "tree")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("alpha", in: root)
    _ = try await vfs.createDirectory("nested", in: VFSPath(root: vfs.id, components: ["alpha"]))
    _ = try await vfs.createDirectory("beta", in: root)
    let deep = generatedData(bytes: 333, seed: 42)
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["alpha", "readme.md"]), chunks: [Data("# tree".utf8)])
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["alpha", "nested", "deep.txt"]), chunks: [deep])

    try await vfs.copyContents(from: VFSPath(root: vfs.id, components: ["alpha"]), to: vfs, target: VFSPath(root: vfs.id, components: ["beta"]))

    let copiedTop = try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["beta", "alpha"]))
    #expect(copiedTop.map(\.name).sorted() == ["nested", "readme.md"])
    let received = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["beta", "alpha", "nested", "deep.txt"])))
    #expect(received == deep)
}

@Test func copyOntoExistingFileThrowsTransferConflict() async throws {
    let vfs = InMemoryVFS(name: "conflict")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("alpha", in: root)
    _ = try await vfs.createDirectory("beta", in: root)
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["alpha", "note.txt"]), chunks: [Data("a".utf8)])
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["beta", "note.txt"]), chunks: [Data("b".utf8)])

    await #expect(throws: MCError.self) {
        try await vfs.copyContents(
            from: VFSPath(root: vfs.id, components: ["alpha", "note.txt"]),
            to: vfs,
            target: VFSPath(root: vfs.id, components: ["beta"])
        )
    }
    // The resident file is untouched after the rejected copy.
    let resident = try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["beta", "note.txt"]))
    #expect(resident.attributes.size == 1)
}

@Test func writerFinishWithoutReplaceConflictsOnOccupiedTarget() async throws {
    let vfs = InMemoryVFS(name: "finish-conflict")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("docs", in: root)
    let target = VFSPath(root: vfs.id, components: ["docs", "dup.txt"])
    try await writeChunked(vfs, to: target, chunks: [generatedData(bytes: 500)])

    let writer = try await vfs.openWrite(target, replace: false)
    try await writer.write(generatedData(bytes: 64))
    await #expect(throws: MCError.self) { try await writer.finish(committingTo: target) }

    // The slot is released even after a failed commit: a fresh write is allowed.
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["docs", "other.txt"]), chunks: [Data("x".utf8)])
    let stillThere = try await vfs.metadata(of: target)
    #expect(stillThere.attributes.size == 500)
}

@Test func directorySizeWalksTreeAndDrivesSink() async throws {
    let vfs = InMemoryVFS(name: "size")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("docs", in: root)
    _ = try await vfs.createDirectory("nested", in: VFSPath(root: vfs.id, components: ["docs"]))
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["docs", "a.bin"]), chunks: [generatedData(bytes: 10_000)])
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["docs", "nested", "b.bin"]), chunks: [generatedData(bytes: 150_000)])

    let box = ByteBox()
    let total = try await vfs.directorySize(of: VFSPath(root: vfs.id, components: ["docs"])) { _ in box.increment() }
    #expect(total == 160_000)
    #expect(box.value() == 2)

    let singleFile = try await vfs.directorySize(of: VFSPath(root: vfs.id, components: ["docs", "a.bin"]), progress: nil)
    #expect(singleFile == 10_000)
}

@Test func missingPathsReportNotFoundEverywhere() async throws {
    let vfs = InMemoryVFS(name: "missing")
    await #expect(throws: MCError.self) {
        try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["nope"]))
    }
    await #expect(throws: MCError.self) {
        try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["nope"]))
    }
    await #expect(throws: MCError.self) {
        try await vfs.openRead(VFSPath(root: vfs.id, components: ["nope.bin"]))
    }
}

@Test func renameInPlaceAndRecursiveDeleteRespectTree() async throws {
    let vfs = InMemoryVFS(name: "restruct")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("docs", in: root)
    let original = VFSPath(root: vfs.id, components: ["docs", "a.txt"])
    try await writeChunked(vfs, to: original, chunks: [Data("keep".utf8)])

    let renamed = try await vfs.rename(original, to: "b.txt")
    #expect(renamed.components == ["docs", "b.txt"])
    await #expect(throws: MCError.self) { try await vfs.metadata(of: original) }
    #expect(try await vfs.metadata(of: renamed).attributes.size == 4)

    _ = try await vfs.createDirectory("big", in: root)
    _ = try await vfs.createDirectory("tree", in: VFSPath(root: vfs.id, components: ["big"]))
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["big", "tree", "keep.bin"]), chunks: [generatedData(bytes: 128)])

    try await vfs.delete([VFSPath(root: vfs.id, components: ["big"])], toTrash: true)
    await #expect(throws: MCError.self) {
        try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["big"]))
    }
    await #expect(throws: MCError.self) {
        try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["big", "tree", "keep.bin"]))
    }
}

// MARK: errno-инъекция (docs/SDD/12 T-04; будет употребляться матрицей T-11)

@Test func injectedFailureFailsOperationThenRecoveryClears() async throws {
    let vfs = InMemoryVFS(name: "faults")
    let root = VFSPath(root: vfs.id)
    _ = try await vfs.createDirectory("alpha", in: root)
    try await writeChunked(vfs, to: VFSPath(root: vfs.id, components: ["alpha", "data.bin"]), chunks: [Data("keep".utf8)])
    vfs.injectFailure(MCError.vfsAccessDenied(root, underlying: nil), for: [.openRead])

    await #expect(throws: MCError.self) {
        _ = try await vfs.openRead(VFSPath(root: vfs.id, components: ["alpha", "data.bin"]))
    }
    // The default two-panel copy reads through openRead → the fault propagates.
    _ = try await vfs.createDirectory("beta", in: root)
    await #expect(throws: MCError.self) {
        try await vfs.copyContents(
            from: VFSPath(root: vfs.id, components: ["alpha", "data.bin"]),
            to: vfs,
            target: VFSPath(root: vfs.id, components: ["beta"])
        )
    }

    vfs.injectFailure(nil)   // recovery
    let stream = try await vfs.openRead(VFSPath(root: vfs.id, components: ["alpha", "data.bin"]))
    var restored = Data()
    while let chunk = try await stream.readChunk(max: 1024) { restored.append(chunk) }
    #expect(restored == Data("keep".utf8))
}

@Test func injectionAppliesOnlyToChosenOperations() async throws {
    let vfs = InMemoryVFS(name: "audit")
    let root = VFSPath(root: vfs.id)
    vfs.injectFailure(MCError.vfsNotFound(root), for: [.metadata])

    await #expect(throws: MCError.self) {
        _ = try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["whatever"]))
    }
    #expect(try await vfs.listDirectory(at: root).isEmpty)   // other operations stay healthy
}
