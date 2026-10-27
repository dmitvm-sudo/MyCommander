// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import VFSKit
import Foundation
import Darwin

// Contract: docs/SDD/06 §6.2 — «delete: tree-walk bottom-up; toTrash через
// FileManager.trashItem (локальный); для VFS без trash — прямое удаление с
// подтверждением». Undo data (F-6): a trash move records
// `.restoreFromTrash(original:trashURL:)`; a permanent delete is not
// reversible — the journal record carries no reversals (08 §8.3).

/// What one delete transaction did.
public enum DeleteOutcome: Sendable {
    /// Local trash: one `trashItem` call moved the object (tree included)
    /// into ~/.Trash; `trashURL` is where it landed (undo data).
    case trashed(trashURL: URL, files: Int, bytes: Int64)
    /// Permanent removal: per-node bottom-up walk completed.
    case removed(files: Int, bytes: Int64)
}

public enum DeleteTransaction {
    /// Deletes one top-level item. Local volumes take trash (default) or the
    /// bottom-up permanent walk; other adapters delegate to `VFS.delete`.
    /// Throws MCError (or CancellationError).
    public static func run(
        _ transfer: TransferItem,
        source: any VFS,
        toTrash: Bool,
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws -> DeleteOutcome {
        // Only genuine local files get Finder-trash semantics; every other
        // adapter (archive, SFTP, fake) is delegated wholesale (§6.2).
        guard let local = source as? LocalVFS, transfer.source.root == local.id else {
            try await source.delete([transfer.source], toTrash: toTrash)
            await progress?(1.0, transfer.item.attributes.size ?? 0)
            return .removed(files: 1, bytes: transfer.item.attributes.size ?? 0)
        }

        let url = local.url(for: transfer.source)
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MCError.vfsNotFound(transfer.source)
        }

        if toTrash {
            var trashNSURL: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &trashNSURL)
            } catch {
                throw CopyTransaction.mapFSError(error, at: transfer.source)
            }
            let (files, bytes) = countContents(url)
            await progress?(1.0, bytes)
            return .trashed(trashURL: (trashNSURL as URL?) ?? url, files: max(files, 1), bytes: bytes)
        }

        let (files, bytes) = try await removeTreeBottomUp(url, at: transfer.source, gate: gate, progress: progress)
        return .removed(files: max(files, 1), bytes: bytes)
    }

    /// Bottom-up permanent walk: children first, then the node itself
    /// (deepest first, docs/SDD/06 §6.2). Files marked read-only are removed
    /// when their parent directory is writable (POSIX unlink rules); a node
    /// that cannot be removed fails the transaction with its path attached.
    private static func removeTreeBottomUp(
        _ url: URL,
        at path: VFSPath,
        gate: OperationGate?,
        progress: CopyProgressSink?
    ) async throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var files = 0
        var bytes: Int64 = 0

        // Depth-first post-order: recurse into subdirectories, then remove
        // the files of this node, then the node itself.
        let children = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )) ?? []
        for child in children {
            try Task.checkCancellation()
            await gate?.waitIfPaused()

            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let childIsDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            if childIsDirectory {
                // The recursion removes the whole subtree INCLUDING its root —
                // do not touch the child again afterwards (it is already gone).
                let childPath = path.appending(component: child.lastPathComponent)
                let sub = try await removeTreeBottomUp(child, at: childPath, gate: gate, progress: progress)
                files += sub.files
                bytes += sub.bytes
            } else {
                do {
                    try fm.removeItem(at: child)
                } catch {
                    throw CopyTransaction.mapFSError(error, at: path.appending(component: child.lastPathComponent))
                }
                files += 1
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                bytes += Int64(size)
                await progress?(0, bytes)
            }
        }

        // All children are gone — the node itself is last (post-order).
        try Task.checkCancellation()
        await gate?.waitIfPaused()
        do {
            try fm.removeItem(at: url)
        } catch {
            throw CopyTransaction.mapFSError(error, at: path)
        }
        files += 1
        let rootSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        bytes += Int64(rootSize)
        await progress?(1.0, bytes)
        return (files, bytes)
    }

    /// Content statistics of a subtree (for the summary of a one-call trash).
    private static func countContents(_ url: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        var files = 0
        var bytes: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
}
