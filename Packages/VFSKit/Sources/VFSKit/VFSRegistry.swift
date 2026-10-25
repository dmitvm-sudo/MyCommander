// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/05 §5.3 (уточнение T-21) + docs/SDD/06 §6.4 — mount registry
// for panel sources. v1 hosts the local workspace and archive interludes; the
// disk-picker UI arrives with a later task. The extract cache root
// (`~/Library/Caches/MyCommander/extract/`) is wiped on every launch (06 §6.4
// T-21: the 24-h TTL is v1.x — a fresh process start is the cheaper honest variant).

public final class VFSRegistry: VFSRegistryProtocol, @unchecked Sendable {
    /// Джентльмен-лимит: mount-intлюди архивов вытесняются по FIFO; локальный воркспейс не притиснут.
    private static let mountLimit = 64

    private let lock = NSLock()
    private var instances: [VFSInstanceID: any VFS] = [:]
    private var evictions: [VFSInstanceID] = []
    private let extractRoot: URL

    public init(extractRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyCommander/extract", isDirectory: true)) {
        self.extractRoot = extractRoot
        // v1 shampoo: the extract cache never survives a process relaunch;
        // per-archive subdirs are also evicted together with their mounts.
        try? FileManager.default.removeItem(at: extractRoot)
    }

    public func instance(for root: VFSInstanceID) -> (any VFS)? {
        withLock { instances[root] }
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func register(_ vfs: any VFS) async {
        withLock {
            guard instances[vfs.id] == nil else { return }
            instances[vfs.id] = vfs
            if vfs.id.kind == .archive {
                evictions.append(vfs.id)
                while evictions.count > Self.mountLimit {
                    let oldest = evictions.removeFirst()
                    instances[oldest] = nil
                    try? FileManager.default.removeItem(at: extractDirectory(specID: oldest.specID))
                }
            }
        }
    }

    public func mountedVolumes() async -> [VFSInstanceID] {
        withLock { instances.keys.sorted { $0.specID < $1.specID } }
    }

    /// Docs 06 §6.4 T-21: idempotent mount of an archive file; a file reopened
    /// with the same path+size+mtime resolves to the ALREADY mounted instance.
    public func mountArchive(reading url: URL) async throws -> (any VFS) {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL
        guard fm.isReadableFile(atPath: standardized.path) else {
            throw MCError.vfsAccessDenied(VFSPath.local(standardized), underlying: nil)
        }
        let identity = ArchiveVFS.fileIdentity(of: standardized)
        if let existing = instances[identity] { return existing }
        let archive = try ArchiveVFS(reading: standardized, extractRoot: extractRoot)
        await register(archive)
        return archive
    }

    private func extractDirectory(specID: String) -> URL {
        extractRoot.appendingPathComponent(specID.mountCacheHex(), isDirectory: true)
    }
}

extension String {
    /// Stable hex cache key (FNV-1a over UTF-8 bytes — filesystem-safe specID denormalization).
    func mountCacheHex() -> String {
        var hash: UInt64 = 1_469_598_103_934_665_743
        for byte in utf8 {
            hash = ((hash ^ UInt64(byte)) &* 1_070_779_231_226_858_297) & 0xFFFF_FFFF_FFFF_FFFF
        }
        return String(format: "%016x", hash)
    }
}
