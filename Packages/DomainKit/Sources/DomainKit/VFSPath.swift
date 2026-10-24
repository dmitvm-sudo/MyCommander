// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Data source kind. Contract: docs/SDD/05-DataModel-VFS.md §5.1.
/// `.smb` / `.s3` are reserved for v1.x (ADR-5); they exist so that URLs/serialization
/// round-trip across versions without re-enumerations.
public enum VFSKind: String, Codable, Sendable, CaseIterable {
    case localDisk
    case archive
    case sftp
    case smb   // v1.x
    case s3    // v1.x
}

/// Stable identifier of one open "disk" (volume, archive, SFTP session, ...).
/// Contract: docs/SDD/05-DataModel-VFS.md §5.1.
public struct VFSInstanceID: Hashable, Codable, Sendable {
    public var kind: VFSKind
    /// Keychain reference for saved connections (F-13); `nil` for local sources.
    public var credentialRef: UUID?
    /// localDisk: volume UUID; archive: file identity; sftp: connection id.
    public var specID: String

    public init(kind: VFSKind, credentialRef: UUID? = nil, specID: String) {
        self.kind = kind
        self.credentialRef = credentialRef
        self.specID = specID
    }
}

/// A path inside one source. Not an URL: works uniformly for archives and SFTP.
/// Contract: docs/SDD/05-DataModel-VFS.md §5.1.
/// Codable since T-03: JournalRecord (§5.6) and persistent sessions store paths
/// verbatim (see docs/SDD/12, «Уточнение T-03»).
///
/// Normalization semantics (tested in VFSPathTests):
/// - components are relative to `root`, no leading separator, no empty segments;
/// - `.` segments are dropped, `..` pops the previous component (clamped at root);
/// - segments are canonically composed (NFC) so that NFD/NFC spellings of the same
///   name (macOS APFS/HFS+ NFD residue vs typed NFC) produce identical `VFSPath` values.
public struct VFSPath: Hashable, Codable, Sendable {
    public var root: VFSInstanceID
    /// Normalized segments without ".."; "/" is the root itself (empty components).
    public var components: [String]
    /// nil for virtual sources; kept for Quick Look / Finder actions (F-9, F-18).
    public var displayURL: URL?

    public init(root: VFSInstanceID, components: [String] = [], displayURL: URL? = nil) {
        self.root = root
        self.components = components.map { $0.precomposedStringWithCanonicalMapping }
        self.displayURL = displayURL
    }

    /// Local-disk path from a file URL. Root == volume of the URL (specID: volume
    /// UUID when the OS reports one, "unknown" otherwise).
    public static func local(_ url: URL) -> VFSPath {
        let root = VFSInstanceID(kind: .localDisk, specID: VFSPath.volumeID(for: url))
        return VFSPath(root: root, components: VFSPath.normalizedComponents(from: url), displayURL: url)
    }

    /// POSIX-style syntactic normalization of a file URL's path:
    /// drops ".", collapses duplicate separators, resolves ".." against the previous
    /// segment, clamped at root. Symlinks are NOT resolved (display preserves intent).
    public static func normalizedComponents(from url: URL) -> [String] {
        var result: [String] = []
        for segment in url.pathComponents where segment != "/" {
            switch segment {
            case ".", "":
                continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(segment)
            }
        }
        return result
    }

    private static func volumeID(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString
        else { return "unknown" }
        return uuid
    }
}
