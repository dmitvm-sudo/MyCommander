// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import DomainKit

// Attribute plumbing that only the local volume understands (docs/SDD/05 §5.2:
// «tags — macOS-тэги (только LocalVFS)», F-4 custom columns). The codec stores
// Spotlight's plist array in the `com.apple.metadata:_kMDItemUserTags` xattr and
// exposes FinderInfo as base64 in `urlResourceMeta` (no UI strings here).

public extension LocalVFS {
    static let userTagsXattr = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfoXattr = "com.apple.FinderInfo"

    /// User tags, as spread by Finder/Spotlight (entries keep a trailing CR there).
    static func userTags(of url: URL) -> [String] {
        guard let payload = xattrValue(of: userTagsXattr, at: url) else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String] else {
            return []
        }
        return plist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Overwrites the whole tag set (Spotlight-compatible «<name>\r» entries).
    static func writeUserTags(_ tags: [String], to url: URL) throws {
        let payload = tags.map { $0 + "\r" }
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        try setXattrValue(data, name: userTagsXattr, at: url)
    }

    /// FinderInfo (F-9 badges, icons) exposed as base64 string for custom columns.
    static func finderInfo(of url: URL) -> String? {
        xattrValue(of: finderInfoXattr, at: url)?.base64EncodedString()
    }

    /// Overwrites the FinderInfo blob directly (32 bytes; tests use synthetic data).
    static func writeFinderInfo(_ data: Data, to url: URL) throws {
        try setXattrValue(data, name: finderInfoXattr, at: url)
    }

    // MARK: raw xattr plumbing (Darwin getxattr/setxattr)

    private static func xattrValue(of name: String, at url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }   // ENOATTR/ENOTSUP quietly handled as «нет атрибута»
        var buffer = [UInt8](repeating: 0, count: length)
        let written = getxattr(path, name, &buffer, size_t(length), 0, 0)
        guard written > 0 else { return nil }
        return Data(buffer[0 ..< written])
    }

    private static func setXattrValue(_ value: Data, name: String, at url: URL) throws {
        let result = value.withUnsafeBytes { raw -> Int32 in
            setxattr(url.path, name, raw.baseAddress, raw.count, 0, 0)
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            throw POSIXError(code)
        }
    }
}
