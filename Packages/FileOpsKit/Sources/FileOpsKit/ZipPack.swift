// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import VFSKit
import ZIPFoundation

// Contract: docs/SDD/06 §6.2 (уточнение T-22) + docs/SDD/05 §5.6 — the F-12
// pack flow: wrap the selection into ONE zip archive at the destination.
// The destination must be a LocalVFS (v1); the zip is published through the
// standard staging protocol (`.mc-partial` → rename) of the transfer engine.
// Sources may come from any VFS: LocalVFS entries are added by file URL,
// everything else (e.g. an ArchiveVFS panel) is materialized through `openRead`
// chunked copies into a temp tree. Entry paths always start from the source
// item's own name — never from temp/disk file names. Progress is reported at
// entry boundaries (ZIPFoundation's addEntry updates Progress totals only,
// no per-chunk callback — honest v1 limit, 05 §5.6 уточнение T-22); pause and
// cancel are honored by the OperationGate between entries.

/// Planner layer of the pack flow (06 §6.2 layer 1).
public enum ZipPackPlanner {

    public enum PlannerError: Error {
        /// The planner refuses an empty selection (nothing to pack).
        case noSources
    }

    /// Packs `sources` (top-level entries of the selection) into ONE zip named
    /// `zipName` inside the directory `target`. Every source becomes one
    /// `TransferItem` whose `target` is the SAME zip path (05 §5.6 уточнение
    /// T-22); the conflict list holds at most one row — the shared zip target.
    /// `compression` is the dialog's «метод сжатия» vocabulary (store/deflate).
    public static func planPack(
        sources: [VFSPath],
        into target: VFSPath,
        zipName: String,
        source: any VFS,
        destination: any VFS,
        compression: ZipPackCompression = .deflate,
        progress: ProgressSink? = nil
    ) async throws -> TransferPlan {
        guard !sources.isEmpty else { throw PlannerError.noSources }
        let targetItem = try await destination.metadata(of: target)
        guard case .directory = targetItem.kind else {
            throw TransferPlannerError.targetNotADirectory(target)
        }

        let zipPath = target.appending(component: zipName)
        var items: [TransferItem] = []
        var conflicts: [Conflict] = []
        if let existing = try? await destination.metadata(of: zipPath), let seed = sources.first {
            // One shared conflict for the whole plan — the executor resolves
            // it by items[0].target (overwrite deletes the zip once).
            let seedItem = try? await source.metadata(of: seed)
            conflicts.append(Conflict(
                source: seed,
                target: zipPath,
                kind: .targetExists(existing: existing),
                sourceItem: seedItem
            ))
        }
        for sourcePath in sources {
            let item = try await source.metadata(of: sourcePath)
            items.append(TransferItem(source: sourcePath, target: zipPath, item: item))
            progress?(ProgressUpdate(completedItems: items.count, message: item.name))
        }
        return TransferPlan(op: .packZip, items: items, conflicts: conflicts, zipPack: ZipPackSpec(compression: compression))
    }
}

/// Executor side of the pack flow (06 §6.2 layer 3, `.packZip` branch).
public enum ZipPackTask {

    /// Packs every `sources` item into ONE zip at `target` (LocalVFS-only
    /// publication in v1). Gate performs pause between entries; cancellation
    /// removes the staged temp. Returns the consumed source bytes.
    public static func pack(
        target: VFSPath,
        sources: [TransferItem],
        source: any VFS,
        destination: any VFS,
        compressionMethod: CompressionMethod,
        gate: OperationGate,
        progress: @escaping @Sendable (_ fraction: Double, _ bytes: Int64) async -> Void
    ) async throws -> Int64 {
        guard let localDestination = destination as? LocalVFS else {
            throw MCError.vfsUnsupported(
                destination.id,
                "pack writes only to a local destination in v1 (06 §6.2 T-22)"
            )
        }
        let fm = FileManager.default
        let zipURL = localDestination.url(for: target)
        let targetDirectory = zipURL.deletingLastPathComponent()
        let staged = targetDirectory.appendingPathComponent("." + zipURL.lastPathComponent + ".mc-partial")

        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: staged)   // leftover of an aborted previous run
        let archive: Archive
        do {
            archive = try Archive(url: staged, accessMode: .create)
        } catch {
            throw MCError.unexpected(underlying: error)
        }

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("MyCommander-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let consumed = ConsumedBytes()
        let totalBytes = sources.reduce(Int64(0)) { $0 + ($1.item.attributes.size ?? 0) }

        do {
            for entry in sources {
                await gate.waitIfPaused()
                if Task.isCancelled { throw CancellationError() }
                try await addSource(
                    entry,
                    source: source,
                    archive: archive,
                    tempRoot: tempRoot,
                    compressionMethod: compressionMethod,
                    consumed: consumed
                )
                let done = consumed.value
                let fraction = totalBytes > 0 ? Double(done) / Double(totalBytes) : 1.0
                await progress(min(fraction, 1.0), done)
            }
            // fsync before the atomic publish (06 §6.2 «fsync → rename»).
            if let handle = try? FileHandle(forUpdating: staged) {
                try? handle.synchronize()
                try? handle.close()
            }
            if fm.fileExists(atPath: zipURL.path) {
                try fm.removeItem(at: zipURL)
            }
            try fm.moveItem(at: staged, to: zipURL)   // atomic publish in one directory
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return consumed.value
    }

    // MARK: sources

    /// Thread-safe byte accumulator shared with the sync add walk.
    private final class ConsumedBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var value_: Int64 = 0
        var value: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value_
        }
        func add(_ bytes: Int64) { lock.lock(); value_ += bytes; lock.unlock() }
    }

    /// Adds ONE top-level source (file/subtree/symlink) to the archive. File
    /// byte sizes flow into `consumed` at each added file entry.
    private static func addSource(
        _ entry: TransferItem,
        source: any VFS,
        archive: Archive,
        tempRoot: URL,
        compressionMethod: CompressionMethod,
        consumed: ConsumedBytes
    ) async throws {
        if let local = source as? LocalVFS {
            try addTree(
                fileURL: local.url(for: entry.source),
                as: entry.item.name,
                to: archive,
                compressionMethod: compressionMethod,
                consumed: consumed
            )
            return
        }
        // Non-LocalVFS source: symlinks are never materialized (06 §6.4);
        // everything else extracts into a temp subtree and is zipped from it.
        if case .symlink = entry.item.kind { return }
        let subtree = tempRoot.appendingPathComponent(entry.item.name, isDirectory: entry.item.kind.isDirectory)
        let copiedBytes = try await materializeSubtree(
            path: entry.source,
            source: source,
            into: subtree
        )
        try addTree(
            fileURL: subtree,
            as: entry.item.name,
            to: archive,
            compressionMethod: .none,   // compression came at the materialization step on disk
            consumed: consumed
        )
        consumed.add(copiedBytes)
    }

    /// Non-LocalVFS source: extract the source subtree via streaming
    /// `openRead` into `into` (an on-disk mirror), returning file bytes.
    /// Symlinks are omitted (06 §6.4 / 05 §5.1 v1 scope).
    private static func materializeSubtree(
        path sourcePath: VFSPath,
        source: any VFS,
        into destination: URL
    ) async throws -> Int64 {
        let fm = FileManager.default
        guard let item = try? await source.metadata(of: sourcePath) else {
            throw MCError.vfsNotFound(sourcePath)
        }
        var total: Int64 = 0
        switch item.kind {
        case .file, .special:
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stream = try await source.openRead(sourcePath)
            try await streamChunked(stream, to: destination)
            total += item.attributes.size ?? 0
        case .directory:
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try await source.listDirectory(at: sourcePath) {
                if case .symlink = child.kind { continue }
                total += try await materializeSubtree(
                    path: child.id,
                    source: source,
                    into: destination.appendingPathComponent(child.name)
                )
            }
        case .symlink:
            break
        }
        return total
    }

    /// Recursive on-disk tree add; archive entry paths are `as` plus the
    /// relative child paths. Directories keep their own «name/» entry.
    private static func addTree(
        fileURL root: URL,
        as entryPath: String,
        to archive: Archive,
        compressionMethod: CompressionMethod,
        consumed: ConsumedBytes
    ) throws {
        let fm = FileManager.default
        try archive.addEntry(with: entryPath, fileURL: root, compressionMethod: compressionMethod)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try addTree(
                    fileURL: child,
                    as: entryPath + "/" + child.lastPathComponent,
                    to: archive,
                    compressionMethod: compressionMethod,
                    consumed: consumed
                )
            }
        } else if let size = (try? root.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            consumed.add(Int64(size))
        }
    }

    /// Chunked ByteStream → file (1 MB chunks, RAM-bounded). Creates the file
    /// first (`FileHandle(forWritingTo:)` needs an existing path).
    private static func streamChunked(_ stream: any ByteStream, to destination: URL) async throws {
        let fm = FileManager.default
        fm.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            while let chunk = try await stream.readChunk(max: 1 << 20) {
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }
}

private extension VFSItemKind {
    var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }
}
