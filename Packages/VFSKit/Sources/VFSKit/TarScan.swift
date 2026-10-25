// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.4 (уточнение T-21) — byte-block TAR streaming.
// SWCompression's TarReader eagerly materializes every entry (a 4 GB entry
// becomes a 4 GB Data), so ArchiveVFS walks the 512-byte POSIX/ustar headers
// itself on a FileHandle: RAM is O(1) per entry, extraction is a chunked copy
// from the byte offset in the backing file. Covered: ustar name+prefix,
// PAX («path»/«size» records), GNU longname/longlink (with the trailing newline
// some GNU writers append); typeflags 0·\0·7 = file, 5 = dir, 2 = symlink
// (no payload follows), 1·3·4·6 + unknown = header-only skip; base-256 numeric
// fields (0x80 marker). Names are resolved against the archive root by
// ArchiveVFS.normalizeEntryName — «..» escaping the root drops the entry
// (the F-12 path-traversal lock).

/// One scanned TAR header; the payload is never materialized here.
struct TarScannedEntry {
    var name: String
    var kind: TarEntryKind
    var size: Int64
    var modified: Date?
    var permissions: Int16?
    var symlinkTarget: String?
    /// Byte offset of the payload in the backing file (nil: no payload).
    var dataOffset: Int64?
}

enum TarEntryKind: Equatable {
    case file
    case directory
    case symlink
    /// Hardlink/dev/fifo/unknown entries: header-only skip (05 §5.1 v1 scope).
    case skipped
}

/// Structurally broken container surfaces (per-entry truncation etc.);
/// ArchiveVFS maps it into `MCError.unexpected` at the adapter boundary (§5.8).
enum TarMalformedError: Error {
    case truncated
}

enum TarStream {
    /// Scans the container to its EOF marker (two zero blocks); never throws on
    /// ordinary truncation — the scan simply ends where the stream ends. I/O
    /// failures propagate to be mapped by the adapter.
    static func scan(fileHandle: FileHandle) throws -> [TarScannedEntry] {
        var entries: [TarScannedEntry] = []
        var paxPath: String?
        var paxSize: Int64?
        var longName: String?
        var longLinkName: String?
        var zeroBlocks = 0

        while true {
            let blockStart = Int64(truncatingIfNeeded: fileHandle.offsetInFile)
            guard let headerData = try fileHandle.read(upToCount: 512) else { return entries }
            guard headerData.count == 512 else { return entries }   // truncated tail: honest stop

            if headerData.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                // POSIX: two zero blocks end the container; single-block writers exist.
                if zeroBlocks >= 2 { return entries }
                continue
            }
            zeroBlocks = 0

            let name = stringField(headerData, 0, 100)
            let contentSize = Int64(truncatingIfNeeded: numericField(headerData, 124, 12) ?? 0)
            let modified = numericField(headerData, 136, 12).map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
            let permissions = numericField(headerData, 100, 8).map { Int16(truncatingIfNeeded: $0 & 0o7777) }
            let typeflag = headerData[156]
            let linkName = stringField(headerData, 157, 100)
            let magic = stringField(headerData, 257, 6)
            let prefix = stringField(headerData, 345, 100)

            let payloadStart = blockStart + 512
            let payloadEnd = payloadStart + ((contentSize + 511) & ~511)

            let typechar = Character(UnicodeScalar(typeflag))
            switch typechar {
            case "x", "X":
                // PAX local extended header: only «path»/«size» records matter here;
                // both apply to the NEXT regular entry.
                if let payload = readPayload(fileHandle, start: payloadStart, size: contentSize) {
                    let records = PaxRecords(String(decoding: payload, as: UTF8.self))
                    if let path = records.value(forKey: "path") { paxPath = path }
                    paxSize = records.value(forKey: "size").flatMap(Int64.init)
                }
                try skipToPayloadEnd(fileHandle, payloadEnd)
            case "g":
                // Global extended header — skipped entirely (v1 scope).
                try skipToPayloadEnd(fileHandle, payloadEnd)
            case "L":
                if let payload = readPayload(fileHandle, start: payloadStart, size: contentSize) {
                    longName = unpackedString(payload)
                }
                try skipToPayloadEnd(fileHandle, payloadEnd)
            case "K":
                if let payload = readPayload(fileHandle, start: payloadStart, size: contentSize) {
                    longLinkName = unpackedString(payload)
                }
                try skipToPayloadEnd(fileHandle, payloadEnd)
            default:
                var resolvedName = name
                if let longName { resolvedName = longName }
                if let paxPath { resolvedName = paxPath }
                if longName == nil && paxPath == nil && !prefix.isEmpty && magic.hasPrefix("ustar") {
                    resolvedName = prefix + "/" + name
                }

                let kind: TarEntryKind
                switch typechar {
                case "0", "\u{0}", "7": kind = .file
                case "5": kind = .directory
                case "2": kind = .symlink
                default: kind = .skipped
                }

                if kind != .skipped {
                    let effectiveSize = (kind == .file && paxSize != nil) ? (paxSize ?? 0) : contentSize
                    entries.append(TarScannedEntry(
                        name: resolvedName,
                        kind: kind,
                        size: effectiveSize,
                        modified: modified,
                        permissions: permissions,
                        symlinkTarget: kind == .symlink ? (longLinkName ?? linkName) : nil,
                        dataOffset: kind == .file && effectiveSize > 0 ? payloadStart : nil
                    ))
                }
                longName = nil
                longLinkName = nil
                paxPath = nil
                paxSize = nil
                try skipToPayloadEnd(fileHandle, payloadEnd)
            }
        }
    }

    /// Chunked payload copy from a TAR entry to `destination` (`.mc-partial` →
    /// rename, 06 §6.2); RAM is bounded by the 1 MB chunk buffer.
    static func extract(fileHandle: FileHandle, at offset: Int64, size: Int64, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.appendingPathExtension("mc-partial")
        try? fm.removeItem(at: temp)
        fm.createFile(atPath: temp.path, contents: nil)
        try fileHandle.seek(toOffset: UInt64(truncatingIfNeeded: max(0, offset)))
        let writer = try FileHandle(forWritingTo: temp)
        do {
            var remaining = size
            while remaining > 0 {
                let chunkSize = Int(min(remaining, Int64(1 << 20)))
                guard let chunk = try fileHandle.read(upToCount: chunkSize) else {
                    throw TarMalformedError.truncated
                }
                if chunk.isEmpty { throw TarMalformedError.truncated }
                try writer.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try writer.close()
        } catch {
            try? writer.close()
            try? fm.removeItem(at: temp)
            throw error
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temp, to: destination)   // atomic publish inside one directory
    }

    // MARK: field decoding

    /// POSIX numeric field: octal with optional base-256 (0x80 marker) encoding.
    private static func numericField(_ block: Data, _ offset: Int, _ length: Int) -> UInt64? {
        guard length > 0 else { return nil }
        let upper = min(offset + length, block.count)
        guard offset < upper else { return nil }
        let bytes = [UInt8](block[offset ..< upper])
        guard let first = bytes.first else { return nil }
        if first & 0x80 != 0 {   // base-256 big number (GNU): big-endian content bits
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in bytes.dropFirst() {
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
        var digits: String = ""
        for byte in bytes {
            switch byte {
            case 0x20, 0x00:
                if !digits.isEmpty { return UInt64(digits, radix: 8) }
            case UInt8(ascii: "0") ... UInt8(ascii: "7"):
                digits.append(Character(UnicodeScalar(byte)))
            default:
                continue
            }
        }
        return digits.isEmpty ? nil : UInt64(digits, radix: 8)
    }

    /// NUL-terminated field content as UTF-8 (tar fields are NUL-padded).
    private static func stringField(_ block: Data, _ offset: Int, _ length: Int) -> String {
        let upper = min(offset + length, block.count)
        guard offset < upper else { return "" }
        var bytes = [UInt8](block[offset ..< upper])
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        if let firstNUL = bytes.firstIndex(of: 0) {
            bytes.removeSubrange(firstNUL...)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Entry payload bytes (content only; the handle is left after the padding).
    private static func readPayload(_ handle: FileHandle, start: Int64, size: Int64) -> Data? {
        guard size > 0, size <= Int64(Int32.max) else { return nil }
        guard (try? handle.seek(toOffset: UInt64(truncatingIfNeeded: start))) != nil else { return nil }
        let exact = try? handle.read(upToCount: Int(size))
        let padded = (size + 511) & ~511
        _ = try? handle.seek(toOffset: UInt64(truncatingIfNeeded: start + padded))
        guard let exact, exact.count == Int(size) else { return nil }
        return exact
    }

    private static func skipToPayloadEnd(_ handle: FileHandle, _ offset: Int64) throws {
        try handle.seek(toOffset: UInt64(truncatingIfNeeded: max(0, offset)))
    }

    /// GNU longname/longlink bodies carry a trailing newline in some writers.
    private static func unpackedString(_ data: Data) -> String {
        var text = stringField(data, 0, data.count)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text = String(text.dropLast()) }
        return text
    }
}

/// PAX extended-header records: «length key=value\n» lines.
struct PaxRecords {
    private let lines: [String.SubSequence]

    init(_ payload: String) {
        lines = payload.split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// Value of an exact key: the line body after «<digits> key=».
    func value(forKey key: String) -> String? {
        for line in lines {
            // Skip the leading record length digits + one space.
            guard let digitsEnd = line.firstIndex(where: { !$0.isNumber }),
                  line[digitsEnd] == " "
            else { continue }
            let record = line[line.index(after: digitsEnd)...]
            guard record.hasPrefix("\(key)=") else { continue }
            return String(record.dropFirst(key.count + 1))
        }
        return nil
    }
}
