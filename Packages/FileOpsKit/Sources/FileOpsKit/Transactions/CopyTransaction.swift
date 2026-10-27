// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import VFSKit
import Foundation
import Darwin

// Contract: docs/SDD/06 §6.2 — every TransferItem is executed as a transaction:
// - same-volume + APFS: `clonefile(2)` (CoW, мгновенно), fallback fcopyfile;
// - same-volume non-APFS: `fcopyfile` into `.<name>.mc-partial` + fsync + rename;
// - cross-volume local (T-11): FileHandle-chunked copy into `.<name>.mc-partial`
//   + fsync + rename, with resume-by-offset of an existing partial (06 §6.2
//   «resume-файл: .mc-partial переиспользуется по offset»); a cancelled local
//   chunked copy LEAVES the partial for resume (08 §8.3 requires only that no
//   final target file exists);
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

/// Volume identity provider (T-11): maps a local file URL to its volume key.
/// The default reads `statfs`'s `f_mntfromname` (device identity — different
/// mounted disk images on one APFS container still get different keys).
/// Tests inject constant keys to make cross-volume behaviour deterministic
/// without depending on real filesystem geometry (docs/SDD/08 §8.3).
public typealias VolumeKeyProvider = @Sendable (URL) -> String?

/// Default volume key: the mounted-device name from `statfs` (`/dev/disk…`).
/// The URL itself may not exist yet (a planned target) — `statfs` fails with
/// ENOENT on missing paths, so probe the nearest existing ancestor (same
/// volume by definition).
public func posixVolumeKey(for url: URL) -> String? {
    var probe = url
    var stat = statfs()
    while statfs(probe.path, &stat) != 0 {
        let parent = probe.deletingLastPathComponent()
        if parent.path.isEmpty || parent.path == probe.path {
            return nil   // walked past the filesystem root without a hit
        }
        probe = parent
    }
    return withUnsafeBytes(of: &stat.f_mntfromname) { buffer in
        let cString = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        let raw = String(cString: cString)
        return raw.isEmpty ? nil : raw
    }
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
        progress: CopyProgressSink?,
        volumeKey: VolumeKeyProvider? = nil,
        chunkDelay: UInt64 = 0
    ) async throws {
        switch transfer.item.kind {
        case .directory:
            try await ensureAncestors(transfer.target, destination: destination)
            try await materializeDirectory(transfer, destination: destination)
        case .file, .special:
            try await ensureAncestors(transfer.target, destination: destination)
            try await copyFile(
                transfer, source: source, destination: destination,
                preference: preference, gate: gate, progress: progress,
                volumeKey: volumeKey, chunkDelay: chunkDelay
            )
        case .symlink:
            // T-10 каркас: symlinks are copied by content (openRead follows).
            // Real link preservation arrives with the T-11 attribute pass.
            try await ensureAncestors(transfer.target, destination: destination)
            try await copyFile(
                transfer, source: source, destination: destination,
                preference: preference, gate: gate, progress: progress,
                volumeKey: volumeKey, chunkDelay: chunkDelay
            )
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
        do {
            _ = try await destination.createDirectory(name, in: parent)
        } catch {
            // A sibling item's ensureAncestors may have materialized this
            // directory first — only a still-missing target is a real failure.
            if (try? await destination.metadata(of: transfer.target)) == nil {
                throw error
            }
        }
    }

    private static func copyFile(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        preference: TransportPreference,
        gate: OperationGate?,
        progress: CopyProgressSink?,
        volumeKey: VolumeKeyProvider? = nil,
        chunkDelay: UInt64 = 0
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
            // Cross-volume detection (T-11): unequal injected/statfs volume
            // keys route to the resumable local chunked branch instead of the
            // same-volume fast paths (rename/clone cannot cross a volume).
            if let volumeKey, let sourceKey = volumeKey(local.sourceURL), let targetKey = volumeKey(local.targetURL), sourceKey != targetKey {
                try await localChunkedBranch(transfer, urls: local, gate: gate, progress: progress, chunkDelay: chunkDelay)
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

    static func localPair(
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

    /// The auto transport for these source/target URLs (internal, tests assert
    /// the branch selection from docs/SDD/08 §8.3): "clonefile" / "fcopyfile"
    /// (same volume) or "localChunked" (T-11: different volume keys).
    static func autoTransportKind(
        sourceURL: URL,
        targetURL: URL? = nil,
        volumeKey: VolumeKeyProvider? = nil
    ) -> String {
        if let volumeKey, let targetURL, let sourceKey = volumeKey(sourceURL), let targetKey = volumeKey(targetURL), sourceKey != targetKey {
            return "localChunked"
        }
        return isAPFS(sourceURL) ? "clonefile" : "fcopyfile"
    }

    /// Maps a Foundation/POSIX failure to the §5.8 error vocabulary with the
    /// offending path attached (adapter-boundary rule 5 of 12).
    static func mapFSError(_ error: Error, at path: VFSPath) -> MCError {
        if let mcError = error as? MCError { return mcError }
        let nsError = error as NSError
        let code = nsError.code
        // NSCocoaErrorDomain wraps POSIX codes in NSFileError bits (e.g. 4 = ENOENT,
        // 257 = EACCES-family); NSUnderlyingError keeps the raw POSIX code.
        var posixCode = code
        if nsError.domain == NSCocoaErrorDomain, code > 255 {
            posixCode = code - 256
        } else if nsError.domain == NSCocoaErrorDomain,
                  let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posixCode = underlying.code
        }
        switch posixCode {
        case Int(ENOENT):
            return .vfsNotFound(path)
        case Int(EACCES), Int(EPERM), Int(EROFS), Int(EISDIR):
            return .vfsAccessDenied(path, underlying: NSError(domain: NSPOSIXErrorDomain, code: posixCode))
        default:
            return .unexpected(underlying: error)
        }
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

    // MARK: localChunked (T-11: cross-volume local; resumable by offset)

    /// Chunked FileHandle copy for local cross-volume transfers. The temp
    /// `.<name>.mc-partial` is REUSED when it exists and is strictly shorter
    /// than the source (06 §6.2 «resume: .mc-partial переиспользуется по
    /// offset») — a previous cancelled attempt left it behind. Cancellation
    /// leaves the partial in place (08 §8.3 only forbids a final target file);
    /// the MoveTransaction of a later retry resumes from its size.
    private static func localChunkedBranch(
        _ transfer: TransferItem,
        urls: (sourceURL: URL, targetURL: URL),
        gate: OperationGate?,
        progress: CopyProgressSink?,
        chunkDelay: UInt64
    ) async throws {
        try Task.checkCancellation()
        let tempURL = urls.targetURL.deletingLastPathComponent()
            .appendingPathComponent("." + (transfer.target.components.last ?? "file") + ".mc-partial")
        let fm = FileManager.default

        guard let sourceSize = try? urls.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw MCError.vfsNotFound(transfer.source)
        }

        // Resume: reuse a shorter existing partial as the prefix; otherwise
        // start from zero. A partial LONGER than the source is corrupt — restart.
        var offset = 0
        if let attributes = try? fm.attributesOfItem(atPath: tempURL.path),
           let partialSize = (attributes[.size] as? NSNumber)?.intValue,
           partialSize > 0, partialSize < sourceSize {
            offset = partialSize
        }

        guard let source = FileHandle(forReadingAtPath: urls.sourceURL.path) else {
            throw MCError.vfsAccessDenied(transfer.source, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { try? source.close() }

        // Seek to the resume point and open the partial for appending; the
        // first attempt must create it (FileHandle(forWritingAtPath:) returns
        // nil for a missing file).
        _ = try source.seek(toOffset: UInt64(offset))
        if !fm.fileExists(atPath: tempURL.path) {
            guard fm.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                throw MCError.vfsAccessDenied(transfer.target, underlying: nil)
            }
        }
        guard let target = FileHandle(forWritingAtPath: tempURL.path) else {
            throw MCError.vfsAccessDenied(transfer.target, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        do {
            _ = try target.seek(toOffset: UInt64(offset))
            _ = try target.truncate(atOffset: UInt64(offset))   // drop a torn tail, if any

            let chunkSize = 1 << 20   // docs/SDD/05 §5.5: chunked copies 1–4 MB
            var transferred = Int64(offset)
            while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                await gate?.waitIfPaused()
                try target.write(contentsOf: chunk)
                if chunkDelay > 0 {
                    try await Task.sleep(nanoseconds: chunkDelay)
                }
                transferred += Int64(chunk.count)
                let fraction = sourceSize > 0 ? Double(transferred) / Double(sourceSize) : 1.0
                await progress?(min(fraction, 1.0), transferred)
            }

            // fsync before the atomic publish (06 §6.2 «fsync → rename»).
            _ = fcntl(target.fileDescriptor, F_FULLFSYNC)
        } catch {
            try? target.close()
            throw error   // cancel/abort: the partial stays for resume
        }
        try target.close()

        try Task.checkCancellation()
        await gate?.waitIfPaused()

        try fm.moveItem(at: tempURL, to: urls.targetURL)   // atomic publish
        await progress?(1.0, Int64(sourceSize))
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
