// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import VFSKit

// Contract: docs/SDD/06 §6.7 v1 (T-13) — the streaming source for the Lister
// (F-8 «ByteStream окно + seek») and URL materialization for Quick Look (F-9)
// and the F4 external-editor flow. ListViewKit consumes both without knowing
// VFS adapters (UI does not know adapters, 06 layers).

/// Windowed reader over one VFS object (F-8: «окно-скролл» стримом). Each
/// `read` call opens the target transparently, seeks (`ByteStreamSeekable`,
/// §5.5 уточнение T-13) or skip-forwards, and returns the clamped window.
public struct ListerByteSource: Sendable {
    /// Total byte size; drives the pager's window count and position bar.
    public let totalSize: Int64
    /// Clamped window at `offset` (never beyond EOF; non-negative offsets).
    public let read: @Sendable (_ offset: Int64, _ length: Int64) async throws -> Data

    public init(
        totalSize: Int64,
        read: @escaping @Sendable (_ offset: Int64, _ length: Int64) async throws -> Data
    ) {
        self.totalSize = totalSize
        self.read = read
    }
}

public enum ListerLoader {
    private static let chunkSize = 1 << 20

    /// Builds a windowed source over `path` (files only). Returns `nil` when
    /// metadata/stream access fails — the caller shows the error placeholder.
    public static func open(path: VFSPath, in vfs: any VFS) async -> ListerByteSource? {
        guard let item = try? await vfs.metadata(of: path) else { return nil }
        var size = item.attributes.size ?? 0
        if size == 0, let stream = try? await vfs.openRead(path) {
            size = (try? await stream.length) ?? 0
        }
        guard size >= 0 else { return nil }
        let resolvedSize = size

        return ListerByteSource(totalSize: resolvedSize) { offset, length in
            let stream = try await vfs.openRead(path)
            let start = min(max(offset, 0), resolvedSize)
            if let seekable = stream as? any ByteStreamSeekable {
                try await seekable.seek(to: start)
            } else {
                // Sequential adapters: drop chunks until the window start.
                var skipped: Int64 = 0
                while skipped < start {
                    let take = Int(min(Int64(chunkSize), start - skipped))
                    guard let chunk = try await stream.readChunk(max: take) else { break }
                    skipped += Int64(chunk.count)
                }
            }
            var data = Data()
            var remaining = length < 0 ? 0 : min(length, resolvedSize - start)
            while remaining > 0 {
                let take = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try await stream.readChunk(max: take) else { break }
                data.append(chunk)
                remaining -= Int64(chunk.count)
            }
            return data
        }
    }
}

/// Temp-copy registry for one preview session; cleanup is explicit
/// (termination) so an open QL panel keeps its files (06 §6.7 v1).
private final class PreviewTempStore: @unchecked Sendable {
    static let shared = PreviewTempStore()
    private let lock = NSLock()
    private var directories: [URL] = []

    func register(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        directories.append(url)
    }

    /// Removes every registered temp directory and returns the list that was
    /// already deleted (for tests).
    func purgeAll(in fm: FileManager = .default) -> [URL] {
        lock.lock()
        let all = directories
        directories.removeAll()
        lock.unlock()
        for url in all {
            try? fm.removeItem(at: url)
        }
        return all
    }
}

public enum PreviewMaterializer {
    /// URL for a native preview (QL F-9, F4-edit): the direct file URL for
    /// LocalVFS objects, a temp copy for other adapters (SFTP/archive — потоки).
    /// Returns `nil` when the object is unreadable.
    @discardableResult
    public static func prepareFileURL(path: VFSPath, in vfs: any VFS) async -> URL? {
        if let local = vfs as? LocalVFS {
            return local.url(for: path)
        }
        return await tempCopy(of: path, in: vfs)
    }

    /// Deletes temp copies of earlier preview sessions (app termination;
    /// copies of the current session stay until then).
    public static func purgeTempCopies() {
        _ = PreviewTempStore.shared.purgeAll()
    }

    private static func tempCopy(of path: VFSPath, in vfs: any VFS) async -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mc-preview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        PreviewTempStore.shared.register(dir)

        let name = path.components.last?.isEmpty == false ? path.components.last! : "preview"
        let target = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { return nil }
        guard let handle = FileHandle(forWritingAtPath: target.path) else { return nil }
        guard let stream = try? await vfs.openRead(path) else { return nil }

        do {
            while let chunk = try await stream.readChunk(max: 1 << 20) {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            return target
        } catch {
            try? handle.close()
            return nil
        }
    }
}
