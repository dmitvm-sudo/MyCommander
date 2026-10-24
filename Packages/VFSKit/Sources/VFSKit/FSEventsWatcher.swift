// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import DomainKit

/// Watch engine for the local volume (docs/SDD/06 §6.3; contract §5.4):
/// - one physical `FSEventStream` serves every watched directory (latency 0.5 s,
///   `kFSEventStreamCreateFlagNone` → events report the changed directory);
/// - each watch produces a snapshot diff by re-listing the directory through the
///   panel's `any VFS` (`listDirectory` twice comparison) and emits
///   `WatchEvent.itemsChanged(DirectoryDiff)`;
/// - per-path coalescing (default 300 ms) collapses event storms;
/// - `suppress(paths:until:)` implements self-suppression: FileOpsKit (T-10)
///   marks its own writes so the panel never "self-ping-pongs";
/// - paths without `displayURL` (non-watchable VFS) yield an empty stream.
public final class FSEventsWatcher: FileWatchEngineProtocol, @unchecked Sendable {
    private let vfs: any VFS
    private let dispatchQueue = DispatchQueue(label: "MyCommander.FSEventsWatcher", qos: .utility)
    private let lock = NSLock()

    private final class WatchState {
        let vfsPath: VFSPath
        let absolute: String
        var options: WatchOptions
        /// Last listing keyed by item identity — the diff baseline (§6.3).
        var snapshot: [VFSPath: VFSItem] = [:]
        var pendingWork: DispatchWorkItem?
        var continuations: [UUID: AsyncStream<WatchEvent>.Continuation] = [:]

        init(vfsPath: VFSPath, absolute: String, options: WatchOptions) {
            self.vfsPath = vfsPath
            self.absolute = absolute
            self.options = options
        }
    }

    /// C-callback bridge: the FSEventStream retains this token; the watcher
    /// releases the retained token in `deinit` right after stopping the stream.
    fileprivate final class CallbackBox {
        weak var watcher: FSEventsWatcher?

        func drain(eventPaths: UnsafeMutableRawPointer) {
            let eventArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var changedPaths: [String] = []
            for item in eventArray as NSArray {
                if let path = item as? String {
                    changedPaths.append(path)
                }
            }
            guard !changedPaths.isEmpty else { return }
            watcher?.handleExternalEventPaths(changedPaths)
        }
    }

    private var states: [String: WatchState] = [:]
    /// Suppression deadlines keyed by absolute path; a key suppresses itself and
    /// its descendants until the deadline (expired lazily on the next event).
    private var suppressions: [String: Date] = [:]
    private var eventStream: FSEventStreamRef?
    private let callbackBox = CallbackBox()
    /// Retained token given to the stream as `info`; released in `deinit`.
    private let callbackToken: Unmanaged<CallbackBox>

    public init(vfs: any VFS) {
        self.vfs = vfs
        self.callbackToken = Unmanaged.passRetained(callbackBox)
        callbackBox.watcher = self
    }

    // MARK: §5.4 engine surface

    /// FSEvents reports canonical («/private/var/…») paths while temporary dirs
    /// come in as «/var/…». Canonicalize at registration so key matching is
    /// stable (realpath with a graceful fallback).
    private static func canonicalPath(of url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init)
        return String(decoding: bytes, as: UTF8.self)
    }

    public func watch(_ path: VFSPath, options: WatchOptions) -> AsyncStream<WatchEvent> {
        guard let mountURL = path.displayURL else {
            // Non-watchable VFS: a finished stream per contract §5.4.
            return AsyncStream { $0.finish() }
        }
        let absolute = Self.canonicalPath(of: mountURL) ?? mountURL.path
        return AsyncStream { continuation in
            let subscriptionID = UUID()
            self.withLock {
                if let state = self.states[absolute] {
                    state.options = options   // latest caller wins; per-path value
                    state.continuations[subscriptionID] = continuation
                } else {
                    let state = WatchState(vfsPath: path, absolute: absolute, options: options)
                    state.continuations[subscriptionID] = continuation
                    self.states[absolute] = state
                    self.ensureStreamLocked()
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.dropSubscription(subscriptionID, from: absolute)
            }
            self.bootstrapSnapshot(path: path, key: absolute)
        }
    }

    /// Suppresses events for `paths` (and descendants) until `deadline`.
    public func suppress(_ paths: [VFSPath], until deadline: Date) {
        withLock {
            for path in paths {
                guard let mountURL = path.displayURL else { continue }
                let absolute = Self.canonicalPath(of: mountURL) ?? mountURL.path
                if let existing = suppressions[absolute] {
                    suppressions[absolute] = max(existing, deadline)
                } else {
                    suppressions[absolute] = deadline
                }
            }
        }
    }

    /// Clears suppression entries (`nil` clears all).
    public func clearSuppression(_ paths: [VFSPath]? = nil) {
        withLock {
            if let paths = paths {
                for path in paths {
                    guard let mountURL = path.displayURL else { continue }
                    let absolute = Self.canonicalPath(of: mountURL) ?? mountURL.path
                    suppressions.removeValue(forKey: absolute)
                }
            } else {
                suppressions.removeAll()
            }
        }
    }

    deinit {
        dispatchQueue.sync {
            withLock {
                for state in states.values {
                    state.pendingWork?.cancel()
                    for continuation in state.continuations.values {
                        continuation.finish()
                    }
                }
                states.removeAll()
                suppressions.removeAll()
                if let stream = eventStream {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    eventStream = nil
                }
            }
        }
        callbackToken.release()
    }

    // MARK: stream setup

    /// Recreates the physical FSEventStream over the current watch set.
    private func ensureStreamLocked() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
        let absolutePaths = Array(states.keys).sorted()
        guard !absolutePaths.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: `eventPaths` points to one
            // CFArray of CFStringRef mount-event paths.
            box.drain(eventPaths: eventPaths)
        }
        var context = FSEventStreamContext(
            version: 0,
            info: callbackToken.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            absolutePaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,                       // §6.3: latency 0.5 s
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, dispatchQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func bootstrapSnapshot(path: VFSPath, key: String) {
        Task { [weak self] in
            guard let self else { return }
            let listing = try? await self.vfs.listDirectory(at: path)
            self.withLock {
                guard let state = self.states[key], let listing else { return }
                var snapshot: [VFSPath: VFSItem] = [:]
                snapshot.reserveCapacity(listing.count)
                for item in listing {
                    snapshot[item.id] = item
                }
                state.snapshot = snapshot
            }
        }
    }

    private func dropSubscription(_ id: UUID, from key: String) {
        withLock {
            guard let state = states[key] else { return }
            state.continuations[id] = nil
            if state.continuations.isEmpty {
                state.pendingWork?.cancel()
                state.pendingWork = nil
            }
        }
    }

    // MARK: event processing (dispatchQueue thread)

    private func handleExternalEventPaths(_ changedPaths: [String]) {
        var dueKeys: Set<String> = []
        let now = Date()
        withLock {
            for (key, deadline) in suppressions where deadline <= now {
                suppressions.removeValue(forKey: key)
            }
            for changedPath in changedPaths {
                let suppressed = suppressions.contains(where: { suppressedPath, _ in
                    changedPath == suppressedPath || changedPath.hasPrefix(suppressedPath + "/")
                })
                if suppressed { continue }
                for (watchKey, _) in states where changedPath == watchKey || changedPath.hasPrefix(watchKey + "/") {
                    dueKeys.insert(watchKey)
                }
            }
            for key in dueKeys {
                scheduleDiffEmitLocked(key)
            }
        }
    }

    private func scheduleDiffEmitLocked(_ key: String) {
        guard let state = states[key] else { return }
        state.pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performDiff(key: key)
        }
        state.pendingWork = work
        let window = max(16, state.options.coalescingMilliseconds)
        dispatchQueue.asyncAfter(deadline: .now() + .milliseconds(window), execute: work)
    }

    /// Snapshot diff: re-list through the panel VFS and compare by identity
    /// (§6.3 «lstat сравнение snapshot vs новый список (listDirectory повторно)»).
    private func performDiff(key: String) {
        Task { [weak self, vfs] in
            guard let self else { return }
            let current: (path: VFSPath?, hasConsumers: Bool) = self.withLock {
                guard let state = states[key] else { return (nil, false) }
                return (state.vfsPath, !state.continuations.isEmpty)
            }
            guard let vfsPath = current.path, current.hasConsumers else { return }
            guard let listing = try? await vfs.listDirectory(at: vfsPath) else {
                self.emitVanished(key: key)
                return
            }
            self.emitDiff(key: key, listing: listing)
        }
    }

    private func emitDiff(key: String, listing: [VFSItem]) {
        withLock {
            guard let state = states[key], !state.continuations.isEmpty else { return }
            var fresh: [VFSPath: VFSItem] = [:]
            fresh.reserveCapacity(listing.count)
            var added: [VFSItem] = []
            var updated: [VFSItem] = []
            for item in listing {
                guard fresh[item.id] == nil else { continue }
                fresh[item.id] = item
                switch state.snapshot[item.id] {
                case .none:
                    added.append(item)
                case .some(let old) where !old.isContentEquivalent(to: item):
                    updated.append(item)
                default:
                    break
                }
            }
            var removed: [VFSItem] = []
            for (id, oldItem) in state.snapshot where fresh[id] == nil {
                removed.append(oldItem)
            }
            guard !(added.isEmpty && removed.isEmpty && updated.isEmpty) else { return }
            state.snapshot = fresh
            let event = WatchEvent.itemsChanged(
                diff: DirectoryDiff(added: added, removed: removed, updated: updated)
            )
            for continuation in state.continuations.values {
                continuation.yield(event)
            }
        }
    }

    /// The watched directory disappeared out of band: one «removed» diff, then
    /// the stream finishes (the panel navigates itself away per §5.4 notes).
    private func emitVanished(key: String) {
        withLock {
            guard let state = states[key] else { return }
            let removed = Array(state.snapshot.values)
            if !removed.isEmpty {
                let event = WatchEvent.itemsChanged(diff: DirectoryDiff(removed: removed))
                for continuation in state.continuations.values {
                    continuation.yield(event)
                }
            }
            for continuation in state.continuations.values {
                continuation.finish()
            }
            states.removeValue(forKey: key)
        }
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
