// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import VFSKit
import Foundation
import Darwin

// Contract: docs/SDD/06 §6.2 — every TransferItem is executed as a transaction:
// - same-volume + APFS: `clonefile(2)` (CoW, мгновенно), fallback fcopyfile;
// - same-volume non-APFS: `fcopyfile` into `.<name>.mc-partial` + fsync + rename;
// - VFS-generic: chunked copy through ByteStream (the staged writer of the
//   destination VFS performs temp → rename itself; dropping an unfinished
//   writer cleans its temp — verified LocalByteWriter.deinit).
// Pause is checked between chunks (≤ 500 ms reaction, F-5); cancel is
// Task.cancel + temp cleanup (08 §8.3: «cancel на 99 % не оставляет целевого
// файла»).

/// Which fast path the transaction should attempt (docs/SDD/08 §8.3 forces the
/// branches in tests; `.auto` = planner's usual choice).
public enum TransportPreference: Sendable, Hashable {
    case auto
    /// Force the POSIX fcopyfile branch (same-volume non-APFS semantics).
    case forceFCopyFile
    /// Force the VFS-generic chunked branch.
    case forceByteStream
}

/// Progress callback: (fileFraction 0…1, absoluteBytesTransferred). Awaited
/// inline by the copy loop so events reach the executor synchronously (no
/// detached-task hop — the pause/cancel reaction budget of F-5 stays honest).
public typealias CopyProgressSink = @Sendable (_ fraction: Double, _ bytes: Int64) async -> Void

public enum CopyTransaction {
    /// One item. Throws MCError (or CancellationError — the executor maps it to
    /// a canceled summary). Directories are materialized via the destination
    /// VFS; files take the best transport available.
    public static func run(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        preference: TransportPreference = .auto,
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws {
        switch transfer.item.kind {
        case .directory:
            try await ensureAncestors(transfer.target, destination: destination)
            try await materializeDirectory(transfer, destination: destination)
        case .file, .special:
            try await ensureAncestors(transfer.target, destination: destination)
            try await copyFile(transfer, source: source, destination: destination, preference: preference, gate: gate, progress: progress)
        case .symlink:
            // T-10 каркас: symlinks are copied by content (openRead follows).
            // Real link preservation arrives with the T-11 attribute pass.
            try await ensureAncestors(transfer.target, destination: destination)
            try await copyFile(transfer, source: source, destination: destination, preference: preference, gate: gate, progress: progress)
        }
    }

    /// Concurrency-safe parent chain: with the worker pool, a nested file may
    /// start before its ancestor directory transaction did — materialize the
    /// missing ancestors on demand (mkdir -p semantics for the copy engine).
    private static func ensureAncestors(_ target: VFSPath, destination: any VFS) async throws {
        var walked: [String] = []
        for component in target.components.dropLast() {
            walked.append(component)
            let ancestor = VFSPath(root: target.root, components: walked)
            if (try? await destination.metadata(of: ancestor)) != nil { continue }
            do {
                _ = try await destination.createDirectory(
                    component,
                    in: VFSPath(root: target.root, components: Array(walked.dropLast()))
                )
            } catch {
                // A racing worker may have created it first — only a still-
                // missing ancestor is a real failure.
                if (try? await destination.metadata(of: ancestor)) == nil {
                    throw error
                }
            }
        }
    }

    private static func materializeDirectory(_ transfer: TransferItem, destination: any VFS) async throws {
        guard let name = transfer.target.components.last else { return }
        let parent = transfer.target.parent
        _ = try await destination.createDirectory(name, in: parent)
    }

    private static func copyFile(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        preference: TransportPreference,
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws {
        try Task.checkCancellation()
        await gate?.waitIfPaused()

        // The local fast paths need real URLs from both sides (§6.2): only when
        // both adapters are LocalVFS and the preference allows it.
        if preference != .forceByteStream, let local = localPair(transfer, source: source, destination: destination) {
            if preference == .forceFCopyFile {
                try await fcopyfileBranch(transfer, urls: local, gate: gate, progress: progress)
                return
            }
            if try clonefileBranch(transfer, urls: local) {
                await progress?(1.0, transfer.item.attributes.size ?? 0)
                return
            }
            try await fcopyfileBranch(transfer, urls: local, gate: gate, progress: progress)
            return
        }

        try await byteStreamBranch(transfer, source: source, destination: destination, gate: gate, progress: progress)
    }

    private static func localPair(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS
    ) -> (sourceURL: URL, targetURL: URL)? {
        guard let localSource = source as? LocalVFS, let localDestination = destination as? LocalVFS,
              let sourceURL = transfer.source.displayURL ?? nonOptionalURL(transfer.source, localSource),
              let targetURL = transfer.target.displayURL ?? nonOptionalURL(transfer.target, localDestination)
        else { return nil }
        return (sourceURL, targetURL)
    }

    private static func nonOptionalURL(_ path: VFSPath, _ local: LocalVFS) -> URL? {
        guard path.root == local.id else { return nil }
        return local.url(for: path)
    }

    /// The auto transport on these source URLs (internal, tests assert the
    /// branch selection from docs/SDD/08 §8.3).
    static func autoTransportKind(sourceURL: URL) -> String {
        isAPFS(sourceURL) ? "clonefile" : "fcopyfile"
    }

    private static func isAPFS(_ url: URL) -> Bool {
        var stat = statfs()
        guard statfs(url.path, &stat) == 0 else { return false }
        return withUnsafeBytes(of: &stat.f_fstypename) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self)) == "apfs"
        }
    }

    // MARK: clonefile (same-volume APFS, §8.3: ctime/size match, inode differs)

    /// `true` when the clone happened; `false` = not APFS → caller falls back.
    private static func clonefileBranch(_ transfer: TransferItem, urls: (sourceURL: URL, targetURL: URL)) throws -> Bool {
        guard isAPFS(urls.sourceURL) else { return false }

        let result = urls.sourceURL.path.withCString { source in
            urls.targetURL.path.withCString { target in
                clonefile(source, target, UInt32(0))
            }
        }
        if result == 0 { return true }
        // EEXIST is pre-resolved by the executor; any other errno (ENOTSUP,
        // EXDEV, EACCES…) falls back to fcopyfile — copy still succeeds.
        return false
    }

    // MARK: fcopyfile (local same-volume, non-APFS; 08 §8.3 «data равна byte-wise»)

    private static func fcopyfileBranch(
        _ transfer: TransferItem,
        urls: (sourceURL: URL, targetURL: URL),
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws {
        try Task.checkCancellation()
        let tempURL = urls.targetURL.deletingLastPathComponent()
            .appendingPathComponent("." + (transfer.target.components.last ?? "file") + ".mc-partial")
        let fm = FileManager.default

        let sourceFD = open(urls.sourceURL.path, O_RDONLY)
        guard sourceFD >= 0 else {
            throw MCError.vfsAccessDenied(transfer.source, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { close(sourceFD) }

        guard fm.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw MCError.vfsAccessDenied(transfer.target, underlying: nil)
        }
        let targetFD = open(tempURL.path, O_WRONLY)
        guard targetFD >= 0 else {
            try? fm.removeItem(at: tempURL)
            throw MCError.vfsAccessDenied(transfer.target, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }

        var copied = false
        do {
            // Default copy semantics (no length limit; the whole file).
            let status = fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_ALL))
            if status != 0 {
                throw MCError.unexpected(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
            // fsync before the atomic publish (06 §6.2 «fsync → rename»).
            _ = fcntl(targetFD, F_FULLFSYNC)
            copied = true
        } catch {
            close(targetFD)
            try? fm.removeItem(at: tempURL)
            throw error
        }
        close(targetFD)

        try Task.checkCancellation()
        await gate?.waitIfPaused()

        // Atomic publish: temp → final name.
        if copied {
            try fm.moveItem(at: tempURL, to: urls.targetURL)
        }
        await progress?(1.0, transfer.item.attributes.size ?? 0)
    }

    // MARK: byteStream (VFS-generic; works for InMemoryVFS and every adapter)

    private static func byteStreamBranch(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws {
        let reader = try await source.openRead(transfer.source)
        let total = (try? await reader.length) ?? transfer.item.attributes.size ?? 0
        let writer = try await destination.openWrite(transfer.target, replace: true)
        let chunkSize = 1 << 20   // docs/SDD/05 §5.5: chunked copies 1–4 MB

        var transferred: Int64 = 0
        while let chunk = try await reader.readChunk(max: chunkSize) {
            try Task.checkCancellation()
            await gate?.waitIfPaused()
            try await writer.write(chunk)
            transferred += Int64(chunk.count)
            let fraction = total > 0 ? Double(transferred) / Double(total) : 1.0
            await progress?(min(fraction, 1.0), transferred)
        }
        try await writer.finish(committingTo: transfer.target)
        await progress?(1.0, transferred)
    }
}
