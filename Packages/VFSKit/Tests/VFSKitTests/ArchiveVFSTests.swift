// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SWCompression
import Testing
import ZIPFoundation
import DomainKit
@testable import VFSKit

// T-21 acceptance (F-12, docs/SDD/12): golden archives for every v1 container
// (zip/tar/tgz/tar.xz + PAX/GNU peculiarities), single gz/xz/bz2 payloads,
// the F-12 path-traversal lock, CP866 legacy names, idempotent mounts and the
// honest read-only capabilities profile. Golden bytes live in Fixtures/
// (provenance — Fixtures/README.md).

private func temporaryRoot(for label: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("mcarchive-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func fixtureURL(_ name: String) -> URL {
    let base = name as NSString
    return Bundle.module.url(
        forResource: base.deletingPathExtension,
        withExtension: base.pathExtension,
        subdirectory: "Fixtures"
    )!
}

/// Reads the whole stream through the §5.5 chunk contract.
private func readAll(_ stream: any ByteStream) async throws -> Data {
    var data = Data()
    while let chunk = try await stream.readChunk(max: 256) {
        data.append(chunk)
    }
    return data
}

private func names(_ items: [VFSItem]) -> Set<String> {
    Set(items.map { $0.name })
}

private func extractRoot(_ temp: URL) -> URL {
    temp.appendingPathComponent("extract", isDirectory: true)
}

/// Sync directory walk (DirectoryEnumerator is not async-iterable).
private func cachedNames(_ dir: URL) -> [String] {
    var names: [String] = []
    if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator {
            names.append(url.lastPathComponent)
        }
    }
    return names
}

/// Builds a tar with SWCompression (file + nested file inside a directory).
private func goldenTarData() throws -> Data {
    let entries = [
        TarEntry(info: TarEntryInfo(name: "one.txt", type: .regular), data: Data("tar-one\n".utf8)),
        TarEntry(info: TarEntryInfo(name: "sub/deep.txt", type: .regular), data: Data("deep\n".utf8)),
    ]
    return TarContainer.create(from: entries, force: TarContainer.Format.ustar)
}

@Suite("ArchiveVFS (F-12, T-21)")
struct ArchiveVFSTests {

    // MARK: zip (ZIPFoundation read)

    @Test func zipGoldenListAndRead() async throws {
        let root = temporaryRoot(for: "zip")
        defer { try? FileManager.default.removeItem(at: root) }

        // Prepare source files and pack them into a real zip.
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: source.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try Data("inner\n".utf8).write(to: source.appendingPathComponent("sub/inner.txt"))
        let zippedURL = root.appendingPathComponent("packed.zip")
        let archive = try Archive(url: zippedURL, accessMode: .create)
        try archive.addEntry(with: "a.txt", relativeTo: source)
        try archive.addEntry(with: "sub/inner.txt", relativeTo: source)

        let vfs = try ArchiveVFS(reading: zippedURL, extractRoot: extractRoot(root))

        #expect(vfs.capabilities.canWrite == false)
        #expect(vfs.capabilities.canRandomSeek == true)

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["a.txt", "sub"]))

        let dirMeta = try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["sub"]))
        #expect(dirMeta.kind.isEquivalentToDirectory)
        let nested = try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["sub"]))
        #expect(names(nested) == Set(["inner.txt"]))

        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["sub", "inner.txt"])))
        #expect(bytes == Data("inner\n".utf8))
        // Repeated open (cache re-use) still reads the same bytes.
        let bytesAgain = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["sub", "inner.txt"])))
        #expect(bytesAgain == bytes)
    }

    // MARK: tar (own 512-byte streaming reader)

    @Test func tarGoldenListReadAndSize() async throws {
        let root = temporaryRoot(for: "tar")
        defer { try? FileManager.default.removeItem(at: root) }
        let tarURL = root.appendingPathComponent("pack.tar")
        try goldenTarData().write(to: tarURL)

        let vfs = try ArchiveVFS(reading: tarURL, extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["one.txt", "sub"]))

        let deep = try await vfs.listDirectory(at: VFSPath(root: vfs.id, components: ["sub"]))
        #expect(names(deep) == Set(["deep.txt"]))

        let first = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["one.txt"])))
        #expect(first == Data("tar-one\n".utf8))

        let nested = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["sub", "deep.txt"])))
        #expect(nested == Data("deep\n".utf8))

        let total = try await vfs.directorySize(of: VFSPath(root: vfs.id), progress: nil)
        #expect(total == Int64("tar-one\n".utf8.count + "deep\n".utf8.count))
    }

    // MARK: tgz (SWCompression full-Data container + streamed cache tar)

    @Test func tgzGoldenMatchesPlainTar() async throws {
        let root = temporaryRoot(for: "tgz")
        defer { try? FileManager.default.removeItem(at: root) }
        let tgzURL = root.appendingPathComponent("pack.tgz")
        try GzipArchive.archive(data: goldenTarData()).write(to: tgzURL)

        let vfs = try ArchiveVFS(reading: tgzURL, extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["one.txt", "sub"]))
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["one.txt"])))
        #expect(bytes == Data("tar-one\n".utf8))
    }

    @Test func tarXzGoldenFixture() async throws {
        let root = temporaryRoot(for: "tarxz")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = try ArchiveVFS(reading: fixtureURL("tar-golden.txz"), extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["golddir", "beta.txt"]))

        let beta = try await vfs.metadata(of: VFSPath(root: vfs.id, components: ["beta.txt"]))
        #expect(beta.attributes.size == Int64("beta content\n".utf8.count))

        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["golddir", "alpha.txt"])))
        #expect(bytes == Data("alpha content\n".utf8))
    }

    // MARK: PAX + GNU peculiarities

    @Test func paxLongNameGolden() async throws {
        let root = temporaryRoot(for: "pax")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = try ArchiveVFS(reading: fixtureURL("pax.tar"), extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        guard let item = listing.first else {
            Issue.record("PAX entry missing")
            return
        }
        let expected = "pax" + String(repeating: "x", count: 130) + ".txt"
        #expect(item.name == expected)
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: [item.name])))
        #expect(bytes == Data("pax payload\n".utf8))
    }

    @Test func gnuLongNameGolden() async throws {
        let root = temporaryRoot(for: "gnu")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = try ArchiveVFS(reading: fixtureURL("gnu.tar"), extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        guard let item = listing.first else {
            Issue.record("GNU longname entry missing")
            return
        }
        let expected = "gnu" + String(repeating: "g", count: 130) + ".txt"
        #expect(item.name == expected)
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: [item.name])))
        #expect(bytes == Data("gnu payload\n".utf8))
    }

    // MARK: F-12 path-traversal lock

    @Test func traversalEntriesAreRejected() async throws {
        let root = temporaryRoot(for: "traversal")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = try ArchiveVFS(reading: fixtureURL("traversal.tar"), extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        // «../evil.txt» is DROPPED; «a/../b.txt» clamps to «b.txt»; control visible.
        #expect(names(listing) == Set(["b.txt", "stay.txt"]))

        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["b.txt"])))
        #expect(bytes == Data("bee".utf8))
        #expect(!vfs.id.specID.isEmpty)   // identity still rooted on the container

        // The cache directory never contains an escape artifact.
        let leftovers = cachedNames(extractRoot(root))
        #expect(leftovers.allSatisfy { !$0.contains("evil") })
    }

    // MARK: single gz / bz2 / xz

    @Test func singleGzUnwrapsToBaseName() async throws {
        let root = temporaryRoot(for: "gz")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("single gzip payload\n".utf8)
        let url = root.appendingPathComponent("notes.txt.gz")
        try GzipArchive.archive(data: payload).write(to: url)

        let vfs = try ArchiveVFS(reading: url, extractRoot: extractRoot(root))
        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["notes.txt"]))
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["notes.txt"])))
        #expect(bytes == payload)
    }

    @Test func singleBz2UnwrapsToBaseName() async throws {
        let root = temporaryRoot(for: "bz2")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("single bz2 payload\n".utf8)
        let url = root.appendingPathComponent("manual.bib.bz2")
        try BZip2.compress(data: payload).write(to: url)

        let vfs = try ArchiveVFS(reading: url, extractRoot: extractRoot(root))
        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["manual.bib"]))
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["manual.bib"])))
        #expect(bytes == payload)
    }

    @Test func singleXzGoldenFixture() async throws {
        let root = temporaryRoot(for: "xz")
        defer { try? FileManager.default.removeItem(at: root) }
        let vfs = try ArchiveVFS(reading: fixtureURL("single.xz"), extractRoot: extractRoot(root))

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["single"]))
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["single"])))
        #expect(bytes == Data("MyCommander golden xz payload\n".utf8))
    }

    // MARK: CP866 legacy names

    @Test func cp866LegacyZipName() async throws {
        let root = temporaryRoot(for: "cp866")
        defer { try? FileManager.default.removeItem(at: root) }
        // IBM866 == CP866 (IANA registry; docs/SDD/06 §6.4 T-21 CP866-fallback).
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("IBM866" as CFString)
        let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        let vfs = try ArchiveVFS(reading: fixtureURL("cp866.zip"), extractRoot: extractRoot(root),
                                 pathEncoding: cp866)

        let listing = try await vfs.listDirectory(at: VFSPath(root: vfs.id))
        #expect(names(listing) == Set(["привет.txt"]))
        let bytes = try await readAll(try await vfs.openRead(VFSPath(root: vfs.id, components: ["привет.txt"])))
        #expect(bytes == Data("cp866 payload\n".utf8))
    }

    // MARK: metadata/read-only contract

    @Test func rootMetadataIsReadOnlyDirectory() async throws {
        let root = temporaryRoot(for: "meta")
        defer { try? FileManager.default.removeItem(at: root) }
        let tarURL = root.appendingPathComponent("pack.tar")
        try goldenTarData().write(to: tarURL)
        let vfs = try ArchiveVFS(reading: tarURL, extractRoot: extractRoot(root))

        let rootMeta = try await vfs.metadata(of: VFSPath(root: vfs.id))
        #expect(rootMeta.kind.isEquivalentToDirectory)
        #expect(rootMeta.name == "pack.tar")
        #expect(rootMeta.attributes.isReadOnly)
        #expect(rootMeta.attributes.size == nil)
    }

    @Test func writeShapedOperationsAreRefused() async throws {
        let root = temporaryRoot(for: "readonly")
        defer { try? FileManager.default.removeItem(at: root) }
        let tarURL = root.appendingPathComponent("pack.tar")
        try goldenTarData().write(to: tarURL)
        let vfs = try ArchiveVFS(reading: tarURL, extractRoot: extractRoot(root))
        let entry = VFSPath(root: vfs.id, components: ["one.txt"])

        do {
            _ = try await vfs.createDirectory("new-dir", in: VFSPath(root: vfs.id))
            Issue.record("createDirectory must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            _ = try await vfs.rename(entry, to: "renamed.txt")
            Issue.record("rename must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            try await vfs.delete([entry], toTrash: false)
            Issue.record("delete must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            _ = try await vfs.openWrite(entry, replace: false)
            Issue.record("openWrite must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            try await vfs.setAttributes(entry) { _ in }
            Issue.record("setAttributes must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            _ = try await vfs.openRead(VFSPath(root: vfs.id))
            Issue.record("openRead on the root must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
        do {
            _ = try await vfs.openRead(VFSPath(root: vfs.id, components: ["missing.txt"]))
            Issue.record("openRead on a missing entry must be vfsNotFound")
        } catch let error as MCError {
            #expect(error.isNotFoundRefusal)
        }
    }

    // MARK: registry (idempotent mounts)

    @Test func registryMountIsIdempotent() async throws {
        let root = temporaryRoot(for: "registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let tarURL = root.appendingPathComponent("pack.tar")
        try goldenTarData().write(to: tarURL)
        let registry = VFSRegistry(extractRoot: extractRoot(root))

        let first = try await registry.mountArchive(reading: tarURL)
        let second = try await registry.mountArchive(reading: tarURL)
        #expect(first === second)
        #expect(first.id.kind == .archive)
        #expect(registry.instance(for: first.id) === second)
        let volumes = await registry.mountedVolumes()
        #expect(volumes.count == 1)
        #expect(volumes.first == first.id)
    }

    @Test func unknownContainerIsRefused() async throws {
        let root = temporaryRoot(for: "unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try ArchiveVFS(reading: fixtureURL("plain.txt"), extractRoot: extractRoot(root))
            Issue.record("unknown container must be refused")
        } catch let error as MCError {
            #expect(error.isReadOnlyRefusal)
        }
    }

    @Test func missingArchiveIsNotFound() async throws {
        let root = temporaryRoot(for: "missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let ghostURL = root.appendingPathComponent("ghost.tar")
        do {
            _ = try ArchiveVFS(reading: ghostURL, extractRoot: extractRoot(root))
            Issue.record("missing archive must be vfsNotFound")
        } catch let error as MCError {
            #expect(error.isNotFoundRefusal)
        }
    }
}

// MARK: - local assertions helpers

private extension VFSItemKind {
    var isEquivalentToDirectory: Bool {
        if case .directory = self { return true }
        return false
    }
}

private extension MCError {
    var isReadOnlyRefusal: Bool {
        if case .vfsUnsupported = self { return true }
        return false
    }
    var isNotFoundRefusal: Bool {
        if case .vfsNotFound = self { return true }
        return false
    }
}
