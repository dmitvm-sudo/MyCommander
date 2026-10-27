// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation
import SQLite3

// Contract: docs/SDD/06 §6.6 (уточнение T-29) — the content-digest cache for
// F-15 sync. System sqlite3 (no third-party dependency), key =
// instance specID + relative path, invalidated when mtime/size no longer
// match (п. 08 §8 «hash-cache инваллидация по mtime+размеру»). A single
// connection guarded by a lock — the sync worker pool shares one cache.

/// sqliteTransient is not exposed by the SQLite3 module overlay.
private let sqliteTransient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public final class HashCache: @unchecked Sendable {
    public struct Key: Equatable, Hashable {
        public let instance: String
        public let path: String

        public init(instance: String, path: String) {
            self.instance = instance
            self.path = path
        }
    }

    private let lock = NSLock()
    private var db: OpaquePointer?

    /// `-1` sentinel for a missing mtime (sqlite REAL NULL → bind double).
    private static let noMtime = -1.0

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            sqlite3_close_v2(handle)
            throw MCError.vfsUnsupported(
                VFSInstanceID(kind: .localDisk, specID: "hash-cache"),
                "sqlite open failed (\(rc))"
            )
        }
        db = opened
        let create = "CREATE TABLE IF NOT EXISTS hashes (key TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER, digest BLOB NOT NULL);"
        guard sqlite3_exec(opened, create, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(opened)
            db = nil
            throw MCError.vfsUnsupported(
                VFSInstanceID(kind: .localDisk, specID: "hash-cache"),
                "sqlite schema failed"
            )
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Returns the cached digest only when mtime/size still match.
    public func lookup(_ key: Key, mtime: Date?, size: Int64?) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT mtime, size, digest FROM hashes WHERE key = ?1;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, cacheKey(key), -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let storedMtime = sqlite3_column_double(statement, 0)
        let storedSize = sqlite3_column_int64(statement, 1)
        guard let blob = sqlite3_column_blob(statement, 2) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 2))
        let digest = Data(bytes: blob, count: length)

        let wantMtime = mtime.map { $0.timeIntervalSince1970 } ?? Self.noMtime
        guard wantMtime == storedMtime else { return nil }
        if let size { guard size == storedSize else { return nil } }
        return digest
    }

    public func store(_ key: Key, mtime: Date?, size: Int64?, digest: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO hashes (key, mtime, size, digest) VALUES (?1, ?2, ?3, ?4) "
                + "ON CONFLICT(key) DO UPDATE SET mtime = excluded.mtime, "
                + "size = excluded.size, digest = excluded.digest;",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, cacheKey(key), -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, mtime.map { $0.timeIntervalSince1970 } ?? Self.noMtime)
        if let size {
            sqlite3_bind_int64(statement, 3, size)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        _ = digest.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        _ = sqlite3_step(statement)
    }

    private func cacheKey(_ key: Key) -> String {
        "\(key.instance)\u{1F}\(key.path)"
    }
}
