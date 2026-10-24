// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The single error taxonomy of MyCommander (contract: docs/SDD/05-DataModel-VFS.md §5.8).
/// Every subsystem error must be mapped into `MCError` at the subsystem boundary;
/// the original POSIX/SFTP error is preserved in `underlying` for details panes (N-5).
public enum MCError: Error {
    case vfsAccessDenied(VFSPath, underlying: Error?)
    case vfsNotFound(VFSPath)
    case vfsUnsupported(VFSInstanceID, String)
    case transferConflict(source: VFSPath, target: VFSPath)
    case interrupted(reason: String)
    case network(VFSInstanceID, code: String)
    case canceled
    case unexpected(underlying: Error)

    public var underlyingError: Error? {
        switch self {
        case .vfsAccessDenied(_, let underlying): return underlying
        case .unexpected(let underlying): return underlying
        default: return nil
        }
    }
}

extension MCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .vfsAccessDenied(let path, _):
            return "Access denied: \"\(path.components.last ?? "")\""
        case .vfsNotFound(let path):
            return "Not found: \"\(path.components.last ?? "")\""
        case .vfsUnsupported(let instance, let detail):
            return "Operation not supported by \(instance.kind.rawValue): \(detail)"
        case .transferConflict(_, let target):
            return "Conflicts at target: \"\(target.components.last ?? "")\""
        case .interrupted(let reason):
            return "Operation interrupted: \(reason)"
        case .network(let instance, let code):
            return "Network error (\(instance.kind.rawValue), code \(code))"
        case .canceled:
            return "Operation canceled"
        case .unexpected:
            return "Unexpected error"
        }
    }
}
