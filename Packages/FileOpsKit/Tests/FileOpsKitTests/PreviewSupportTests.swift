// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import FileOpsKit

// T-13: the Lister's windowed source (F-8 «окно + seek»: seek path, skip path,
// 4 GB sparse acceptance) and URL materialization (F-9: direct for LocalVFS,
// temp copy + purge for other adapters). Helpers use the `pv` name-space (the
// test module compiles neighbouring files together).

private func pvPut(_ vfs: InMemoryVFS, _ dir: VFSPath, _ name: String, _ bytes: Data) async throws -> VFSPath {
    let path = dir.appending(component: name)
    let writer = try await vfs.openWrite(path, replace: true)
    try await writer.write(bytes)
    try await writer.finish(committingTo: path)
    return path
}

private func pvPattern(_ size: Int) -> Data {
    Data((0 ..< size).map { UInt8(($0 * 7 + 11) % 251) })
}

/// VFS wrapper handing out plain (non-seekable) streams to exercise the
/// skip-forward path of the loader.
private final class pvPlainVFS: VFS, @unchecked Sendable {
    let inner: InMemoryVFS

    init(inner: InMemoryVFS) {
        self.inner = inner
    }

    var id: VFSInstanceID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) async throws -> [VFSItem] { try await inner.listDirectory(at: path) }
    func metadata(of path: VFSPath) async throws -> VFSItem { try await inner.metadata(of: path) }
    func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64 { try await inner.directorySize(of: path, progress: progress) }
    func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath { try await inner.createDirectory(name, in: parent) }
    func rename(_ path: VFSPath, to name: String) async throws -> VFSPath { try await inner.rename(path, to: name) }
    func delete(_ paths: [VFSPath], toTrash: Bool) async throws { try await inner.delete(paths, toTrash: toTrash) }
    func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter { try await inner.openWrite(path, replace: replace) }
    func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws { try await inner.setAttributes(path, mutate: mutate) }

    func openRead(_ path: VFSPath) async throws -> any ByteStream {
        let stream = try await inner.openRead(path)
        return pvPlainStream(inner: stream)
    }

    private struct pvPlainStream: ByteStream {
        let inner: any ByteStream
        var length: Int64 { get async throws { try await inner.length } }
        func readChunk(max: Int) async throws -> Data? { try await inner.readChunk(max: max) }
    }
}

private struct pvLocalFixture {
    let rootURL: URL
    let vfs: LocalVFS

    static func create(name: String) throws -> pvLocalFixture {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return pvLocalFixture(rootURL: rootURL, vfs: LocalVFS(at: rootURL))
    }

    var path: (String) -> VFSPath {
        { [id = vfs.id] name in VFSPath(root: id, components: [name]) }
    }
}

@Test func pvLoaderWindowsOverInMemory() async throws {
    let vfs = InMemoryVFS(name: "pv")
    let root = VFSPath(root: vfs.id)
    let bytes = pvPattern(64 * 1024)
    let file = try await pvPut(vfs, root, "data.bin", bytes)

    guard let source = await ListerLoader.open(path: file, in: vfs) else {
        Issue.record("loader failed")
        return
    }
    #expect(source.totalSize == Int64(bytes.count))

    let head = try await source.read(0, 4096)
    #expect(head == bytes.prefix(4096))

    let mid = try await source.read(1000, 512)
    #expect(mid == bytes.subdata(in: 1000 ..< 1512))

    // Clamped near EOF: a window past the end yields only the existing tail.
    let tailOffset = Int64(bytes.count) - 10
    let tail = try await source.read(tailOffset, 1000)
    #expect(tail == bytes.suffix(10))
}

@Test func pvLoaderSkipsForwardWithoutSeek() async throws {
    let vfs = InMemoryVFS(name: "pv-skip")
    let root = VFSPath(root: vfs.id)
    let bytes = pvPattern(90 * 1024)
    let file = try await pvPut(vfs, root, "plain.bin", bytes)

    guard let source = await ListerLoader.open(path: file, in: pvPlainVFS(inner: vfs)) else {
        Issue.record("loader failed")
        return
    }
    let window = try await source.read(70 * 1024, 2048)
    #expect(window == bytes.subdata(in: 70 * 1024 ..< 70 * 1024 + 2048))
}

@Test func pvLoaderReads4GBSparseFileNearEnd() async throws {
    // F-8 acceptance: a 4 GB file «opens instantly» — the loader must work at
    // gigabyte offsets without touching the whole file (APFS sparse bytes).
    let fixture = try pvLocalFixture.create(name: "pv-sparse")
    let name = "big.bin"
    let total: Int64 = 4_294_967_296
    let url = fixture.rootURL.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(total))
    try handle.close()

    let file = fixture.path(name)
    guard let source = await ListerLoader.open(path: file, in: fixture.vfs) else {
        Issue.record("loader failed")
        return
    }
    #expect(source.totalSize == total)

    let window = try await source.read(total - 65536, 65536)
    #expect(Int64(window.count) == 65536)
    #expect(window.allSatisfy { $0 == 0 })
}

@Test func pvMaterializerDirectURLForLocal() async throws {
    let fixture = try pvLocalFixture.create(name: "pv-local")
    let bytes = Data("lister source".utf8)
    let name = "note.txt"
    try bytes.write(to: fixture.rootURL.appendingPathComponent(name))

    let url = await PreviewMaterializer.prepareFileURL(path: fixture.path(name), in: fixture.vfs)
    #expect(url == fixture.vfs.url(for: fixture.path(name)))
}

@Test func pvMaterializerTempCopyAndPurge() async throws {
    let vfs = InMemoryVFS(name: "pv-ql")
    let root = VFSPath(root: vfs.id)
    let bytes = Data("ql-bytes".utf8)
    _ = try await pvPut(vfs, root, "doc.md", bytes)

    guard let url = await PreviewMaterializer.prepareFileURL(path: root.appending(component: "doc.md"), in: vfs) else {
        Issue.record("materializer failed")
        return
    }
    // The copy lives in the temp directory and byte-wise matches the source.
    #expect(url.lastPathComponent == "doc.md")
    #expect(try Data(contentsOf: url) == bytes)

    // purgeTempCopies() removes registered copies (nothing left of ours).
    let before = try? Data(contentsOf: url)
    #expect(before != nil)
    PreviewMaterializer.purgeTempCopies()
    let after = try? Data(contentsOf: url)
    #expect(after == nil)
}
