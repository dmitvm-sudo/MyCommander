// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import VFSKit
import Foundation
import Darwin

// Contract: docs/SDD/06 §6.2 — move = rename(2) when both endpoints live on
// one volume (inode preserved, O(1)); otherwise copy+delete with the copy
// running through the CopyTransaction transports (clonefile is never valid
// across volumes). Directory moves cross-volume materialize the target tree
// and delete each source child immediately after its copy succeeds, deepest
// first — a cancelled/failed move leaves the source consistent. F-5 semantics:
// pause/cancel react between chunks; a cancelled local chunked file copy keeps
// its `.mc-partial` for resume (08 §8.3).

/// What one top-level move transaction did.
public enum MoveOutcome: Sendable {
    /// POSIX rename(2): the whole subtree moved with inodes intact.
    case renamed
    /// Copy+delete path: number of files transferred and bytes moved.
    case movedCrossVolume(files: Int, bytes: Int64)
}

public enum MoveTransaction {
    /// Moves one top-level item (the executor passes planner-expanded
    /// top-level entries only — a rename subsumes the whole subtree).
    /// Throws MCError (or CancellationError).
    public static func run(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        gate: OperationGate?,
        progress: CopyProgressSink?,
        volumeKey: VolumeKeyProvider? = nil,
        chunkDelay: UInt64 = 0
    ) async throws -> MoveOutcome {
        // Same-volume local fast path: real URLs on both sides whose volume
        // keys agree → a single rename(2) (inode preserved — 08 §8.3 asserts
        // this). Non-local adapters and mixed pairs take the generic path.
        if let urls = CopyTransaction.localPair(transfer, source: source, destination: destination) {
            let sourceKey = volumeKeyFor(urls.sourceURL, volumeKey)
            let targetKey = volumeKeyFor(urls.targetURL, volumeKey)
            if sourceKey != nil, sourceKey == targetKey {
                let fm = FileManager.default
                do {
                    try fm.moveItem(at: urls.sourceURL, to: urls.targetURL)
                } catch {
                    // EEXIST etc. is pre-resolved by the executor; anything left
                    // (EXDEV should not happen after the key check, EACCES…)
                    // surfaces as an MCError at the adapter boundary (§5.8).
                    throw CopyTransaction.mapFSError(error, at: transfer.source)
                }
                return .renamed
            }
        }

        // Cross-volume / VFS-generic: recursive copy+delete.
        return try await moveRecursively(
            transfer, source: source, destination: destination, gate: gate,
            progress: progress, volumeKey: volumeKey, chunkDelay: chunkDelay
        )
    }

    /// Volume key with the default statfs provider standing in for `nil`.
    private static func volumeKeyFor(_ url: URL, _ provider: VolumeKeyProvider?) -> String? {
        provider?(url) ?? posixVolumeKey(for: url)
    }

    private static func moveRecursively(
        _ transfer: TransferItem,
        source: any VFS,
        destination: any VFS,
        gate: OperationGate?,
        progress: CopyProgressSink?,
        volumeKey: VolumeKeyProvider?,
        chunkDelay: UInt64
    ) async throws -> MoveOutcome {
        try Task.checkCancellation()
        await gate?.waitIfPaused()

        var files = 0
        var bytes: Int64 = 0

        switch transfer.item.kind {
        case .directory:
            // Materialize the target directory (target conflicts are already
            // resolved by the executor).
            try await ensureTargetDirectory(transfer.target, destination: destination)
            let children = try await source.listDirectory(at: transfer.source)
            for child in children {
                let childTransfer = TransferItem(
                    source: child.id,
                    target: transfer.target.appending(component: child.name),
                    item: child
                )
                let outcome = try await moveRecursively(
                    childTransfer, source: source, destination: destination, gate: gate,
                    progress: progress, volumeKey: volumeKey, chunkDelay: chunkDelay
                )
                switch outcome {
                case .renamed:
                    files += 1   // a nested same-geometry rename still counts as one moved unit
                case .movedCrossVolume(let childFiles, let childBytes):
                    files += childFiles
                    bytes += childBytes
                }
            }
            // Children are gone — the source directory itself is removable now
            // (deepest-first order falls out of the recursion).
            try await source.delete([transfer.source], toTrash: false)
            return .movedCrossVolume(files: max(files, 1), bytes: bytes)

        case .file, .special, .symlink:
            // Copy with the best transport (temp + fsync + atomic rename), then
            // remove the source immediately: the move is committed per file.
            try await CopyTransaction.run(
                transfer,
                source: source,
                destination: destination,
                preference: .auto,
                gate: gate,
                progress: progress,
                volumeKey: volumeKey,
                chunkDelay: chunkDelay
            )
            try await source.delete([transfer.source], toTrash: false)
            return .movedCrossVolume(files: 1, bytes: transfer.item.attributes.size ?? 0)
        }
    }

    /// mkdir with racing-worker tolerance (same semantics as the copy engine).
    private static func ensureTargetDirectory(_ target: VFSPath, destination: any VFS) async throws {
        guard let name = target.components.last else { return }
        let parent = target.parent
        do {
            _ = try await destination.createDirectory(name, in: parent)
        } catch {
            if (try? await destination.metadata(of: target)) == nil {
                throw error
            }
        }
    }
}
