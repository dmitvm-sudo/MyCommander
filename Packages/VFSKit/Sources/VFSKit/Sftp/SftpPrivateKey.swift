// SPDX-License-Identifier: GPL-3.0-or-later

import Crypto
import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.5 (уточнение T-24) + 05 §5.7 — private-key auth for
// F-13. v1 scope: UNENCRYPTED OpenSSH Ed25519 containers only
// (`openssh-key-v1`, cipher «none»); encrypted keys (bcrypt-KDF), PEM and
// classic formats produce a clear MCError at connect time (the passphrase
// slot in the record is a v1.x stub). The parser is pure — no I/O; the file
// reading belongs to the App/ConnectionStore layer.

public enum SftpPrivateKey {
    /// Parses an OpenSSH private key file content into an Ed25519 key.
    /// Throws `MCError.vfsUnsupported` on any structural deviation —
    /// «supported format, corrupted data» is reported the same way (the
    /// connect flow surfaces the reason verbatim).
    public static func ed25519(fromOpenSSH content: String) throws -> Curve25519.Signing.PrivateKey {
        let body = try armorBody(content)
        let blob: Data
        guard let decoded = Data(base64Encoded: body) else {
            throw failure("base64 body does not decode")
        }
        blob = decoded

        var reader = BlobReader(blob)
        do {
            let magic = try reader.readBytes(15)
            guard String(decoding: magic, as: UTF8.self) == "openssh-key-v1\u{0}" else {
                throw failure("not an openssh-key-v1 container")
            }
            let cipher = String(decoding: try reader.readString(), as: UTF8.self)
            let kdf = String(decoding: try reader.readString(), as: UTF8.self)
            _ = try reader.readString()   // kdf options
            guard cipher == "none" && kdf == "none" else {
                throw failure("encrypted keys are not supported in v1 (unencrypted Ed25519 only)")
            }
            let keyCount = try reader.readUInt32()
            guard keyCount == 1 else {
                throw failure("multi-key containers are not supported")
            }

            // Public key blob: "ssh-ed25519" + 32 raw bytes.
            let publicKeyBlob = try reader.readString()
            var publicReader = BlobReader(publicKeyBlob)
            let algorithm = String(decoding: try publicReader.readString(), as: UTF8.self)
            guard algorithm == "ssh-ed25519" else {
                throw failure("algorithm \(algorithm) is not Ed25519 (v1 supports Ed25519 only)")
            }
            let publicKey = try publicReader.readString()
            guard publicKey.count == 32 else {
                throw failure("Ed25519 public key must be 32 bytes")
            }

            // Private section: check1 == check2, then the same key layout.
            let privateSection = try reader.readString()
            var privateReader = BlobReader(privateSection)
            let check1 = try privateReader.readUInt32()
            let check2 = try privateReader.readUInt32()
            guard check1 == check2 else {
                throw failure("corrupted container (check mismatch)")
            }
            let privateAlgorithm = String(decoding: try privateReader.readString(), as: UTF8.self)
            guard privateAlgorithm == "ssh-ed25519" else {
                throw failure("private section algorithm mismatch")
            }
            let sectionPublic = try privateReader.readString()
            guard sectionPublic.count == 32, sectionPublic == publicKey else {
                throw failure("public halves do not match")
            }
            let secret = try privateReader.readString()
            guard secret.count == 64 else {
                throw failure("Ed25519 private section must be 64 bytes")
            }
            // The 64-byte section is seed || public; verify the public half
            // against the public blob so a corrupted container fails loudly.
            guard Data(secret.dropFirst(32)) == publicKey else {
                throw failure("private section does not match the public blob")
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
        } catch let error as MCError {
            throw error
        } catch {
            throw failure("truncated container")
        }
    }

    /// Strips the PEM armor, keeping the base64 body lines.
    private static func armorBody(_ content: String) throws -> String {
        var inside = false
        var collected: [String] = []
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "-----BEGIN OPENSSH PRIVATE KEY-----" {
                inside = true
                continue
            }
            if line == "-----END OPENSSH PRIVATE KEY-----" {
                inside = false
                continue
            }
            if inside {
                collected.append(line)
            }
        }
        let body = collected.joined()
        guard !body.isEmpty else { throw failure("empty key body or missing armor") }
        return body
    }

    private static func failure(_ reason: String) -> MCError {
        .vfsUnsupported(VFSInstanceID(kind: .sftp, specID: "private-key"), reason)
    }

    /// Length-prefixed ssh-string reader over the container bytes.
    private struct BlobReader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard bytes.count >= offset + count else { throw BlobError.truncated }
            defer { offset += count }
            return Data(bytes[offset ..< offset + count])
        }

        mutating func readString() throws -> Data {
            let length = Int(try readUInt32())
            return try readBytes(length)
        }

        mutating func readUInt32() throws -> UInt32 {
            let data = try readBytes(4)
            var value: UInt32 = 0
            for byte in data {
                value = (value << 8) | UInt32(byte)
            }
            return value
        }

        enum BlobError: Error { case truncated }
    }
}
