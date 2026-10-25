// SPDX-License-Identifier: GPL-3.0-or-later

import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.10 «Контракт v1 (T-17)» — the access probe of
// F-20. One lazily-run non-async probe classifies the running process:
// Full Disk Access granted → full mode; otherwise the TCC-granted home zones
// (Desktop/Documents/Downloads, ~/Library read) define Safe Mode; an empty
// report is `restricted` — the app must never crash on denied access, panels
// surface listing errors as notes (MCError path, §5.8).

/// Home zones that macOS grants by TCC without Full Disk Access.
public enum AccessZone: String, CaseIterable, Sendable, Equatable {
    case desktop = "Desktop"
    case documents = "Documents"
    case downloads = "Downloads"
    case library = "Library"
}

/// Raw probe result: whether the TCC-protected library file reads and which
/// home zones list successfully.
public struct AccessReport: Sendable, Equatable {
    public let hasFullDiskAccess: Bool
    public let grantedZones: [AccessZone]

    public init(hasFullDiskAccess: Bool, grantedZones: [AccessZone]) {
        self.hasFullDiskAccess = hasFullDiskAccess
        self.grantedZones = grantedZones
    }
}

/// The app's working mode derived from the report.
public enum AccessMode: Sendable, Equatable {
    case full
    case safe(knownZones: [AccessZone])
    case restricted
}

public enum AccessProbe {
    /// A file deep under `~/Library/Preferences` — TCC-guarded for plain
    /// processes: a successful contents read implies Full Disk Access.
    public static let fullDiskAccessProbeSubpath = "Library/Preferences/com.apple.dock.plist"

    public static func probe(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> AccessReport {
        let fdaGranted = fileManager.contents(atPath: home.appendingPathComponent(fullDiskAccessProbeSubpath).path) != nil
        let zones = AccessZone.allCases.filter { isGranted($0, home: home, fileManager: fileManager) }
        return AccessReport(hasFullDiskAccess: fdaGranted, grantedZones: zones)
    }

    /// Pure classification, always Total: no state crashes the app; denied
    /// listings surface through the panel error note path (MCError).
    public static func classify(_ report: AccessReport) -> AccessMode {
        if report.hasFullDiskAccess {
            return .full
        }
        if report.grantedZones.isEmpty {
            return .restricted
        }
        return .safe(knownZones: report.grantedZones)
    }

    /// First zone usable as the panel seed under Safe Mode (T-17: initial
    /// launch without a session starts in a granted zone, not the guarded
    /// home root).
    public static func seedPath(in mode: AccessMode) -> AccessZone? {
        guard case let .safe(knownZones) = mode, let first = knownZones.first else {
            return nil
        }
        return first
    }

    /// Read success = granted (an empty listing is still granted); any
    /// failure (TCC denial, absence) is not.
    static func isGranted(
        _ zone: AccessZone,
        home: URL,
        fileManager: FileManager
    ) -> Bool {
        (try? fileManager.contentsOfDirectory(at: home.appendingPathComponent(zone.rawValue), includingPropertiesForKeys: nil)) != nil
    }
}
