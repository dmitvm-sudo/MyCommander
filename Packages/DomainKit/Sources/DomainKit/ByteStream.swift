// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/05-DataModel-VFS.md §5.5 — I/O streams.
// Used by: Lister (read window), FileOpsKit (chunked copies 1–4 MB), QL export.

/// Sequential readable stream over one object; `readChunk(max:)` returns `nil` at EOF.
/// `canRandomSeek` capabilities live in `VFSCapabilities`; seek-capable providers may
/// expose offset control via their concrete stream type (Lister F-8, 06 §6.7).
public protocol ByteStream: Sendable {
    var length: Int64 { get async throws }
    func readChunk(max: Int) async throws -> Data?
}

/// Уточнение T-13 (§5.5): adapters with random access prove it here — the
/// Lister's window loader seeks rather than discarding chunks. Adapters without
/// it keep window reads correct via skip-forward over `readChunk`.
public protocol ByteStreamSeekable: ByteStream {
    func seek(to offset: Int64) async throws
}

/// Sequential writer with staged-commit semantics: bytes stay buffered by the
/// implementing adapter until `finish(committingTo:)` publishes them atomically
/// (temp → rename, 06 §6.2). Writers must not be reused after finish.
public protocol ByteStreamWriter: Sendable {
    func write(_ data: Data) async throws
    func finish(committingTo finalTarget: VFSPath) async throws
}
