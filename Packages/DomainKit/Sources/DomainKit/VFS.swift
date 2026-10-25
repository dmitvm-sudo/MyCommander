// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/05-DataModel-VFS.md §5.3 — the main VFS protocol and registry.

/// Payload of one streamed progress step («отчёт по глубине/размеру — потоковый
/// ProgressSink», docs/SDD/06 §6.2). Semantics: monotonic counters, never retrograde.
public struct ProgressUpdate: Sendable {
    public var completedItems: Int
    /// `nil` while the total is not yet known (tree walk still expanding).
    public var totalItems: Int?
    public var message: String?

    public init(completedItems: Int, totalItems: Int? = nil, message: String? = nil) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.message = message
    }
}

/// Receives progress updates; delivered on the reporting task, never from the UI thread
/// directly. UI pipelines marshal onto the main actor themselves.
public typealias ProgressSink = @Sendable (ProgressUpdate) -> Void

/// The single source/storage abstraction behind every panel, archive and connection.
/// Errors are always mapped into `MCError` at the adapter boundary (§5.8, rule 5 of 12).
/// Implementations: `LocalVFS`, `ArchiveVFS`, `SftpVFS` (VFSKit); test fake `InMemoryVFS`.
public protocol VFS: AnyObject, Sendable {
    var id: VFSInstanceID { get }
    var capabilities: VFSCapabilities { get }

    func listDirectory(at path: VFSPath) async throws -> [VFSItem]
    func metadata(of path: VFSPath) async throws -> VFSItem
    /// Recursively sums sizes; `progress` (optional) is called per visited item.
    func directorySize(of path: VFSPath, progress: ProgressSink?) async throws -> Int64

    func createDirectory(_ name: String, in parent: VFSPath) async throws -> VFSPath
    /// Renames in place (last component); returns the new path.
    func rename(_ path: VFSPath, to name: String) async throws -> VFSPath
    /// VFS without trash support deletes directly (06 §6.2: confirmation lives in UI).
    func delete(_ paths: [VFSPath], toTrash: Bool) async throws
    /// Copies the object `from` INTO the destination directory `target` of `to`:
    /// result path is `target/<from.name>` (two-panel semantics). Existing file target
    /// → `MCError.transferConflict`; existing directory target merges. The source side
    /// walks its own tree and pushes bytes through `openRead`/`openWrite`.
    func copyContents(from: VFSPath, to: any VFS, target: VFSPath) async throws

    func openRead(_ path: VFSPath) async throws -> any ByteStream
    /// Opens a staging writer; the actual bytes become visible on
    /// `finish(committingTo:)` (`.mc-partial` → rename pattern, 06 §6.2).
    func openWrite(_ path: VFSPath, replace: Bool) async throws -> any ByteStreamWriter
    func setAttributes(_ path: VFSPath, mutate: (inout VFSItemAttributes) -> Void) async throws
}

/// Registry behind «диски»/volume picker (contract §5.3). Concrete registry lives
/// in VFSKit (`VFSRegistry`, T-04+); this protocol lets other kits mock mounts.
/// Уточнение T-21: `instance(for:)` returns `nil` for an unregistered id
/// (§5.3 v1 sketch implied a precondition — an optional keeps mount probes honest).
public protocol VFSRegistryProtocol: Sendable {
    func instance(for root: VFSInstanceID) -> (any VFS)?
    func register(_ vfs: any VFS) async
    func mountedVolumes() async -> [VFSInstanceID]
}

public extension VFS {
    /// Default two-panel copy (docs/SDD/12, «Уточнение T-03»): the SOURCE side walks
    /// its own tree (`metadata`/`listDirectory`/`openRead`) and pushes bytes into the
    /// destination through `openWrite`/`finish`. Adapters with true server-side copy
    /// (archive/SFTP in later milestones) override this requirement.
    func copyContents(from source: VFSPath, to destination: any VFS, target targetDirectory: VFSPath) async throws {
        let meta = try await self.metadata(of: source)
        let name = source.components.last ?? ""
        let destinationPath = VFSPath(root: targetDirectory.root, components: targetDirectory.components + [name])

        if case .directory = meta.kind {
            _ = try await destination.createDirectory(name, in: targetDirectory)
            for child in try await self.listDirectory(at: source) {
                try await self.copyContents(from: child.id, to: destination, target: destinationPath)
            }
        } else {
            let occupied = try? await destination.metadata(of: destinationPath)
            if occupied != nil { throw MCError.transferConflict(source: source, target: destinationPath) }
            let stream = try await self.openRead(source)
            let writer = try await destination.openWrite(destinationPath, replace: false)
            while let chunk = try await stream.readChunk(max: 1 << 20) {   // contract 06 §6.2: chunks 1–4 MB
                try await writer.write(chunk)
            }
            try await writer.finish(committingTo: destinationPath)
            try await destination.setAttributes(destinationPath) { $0 = meta.attributes }
        }
    }
}
