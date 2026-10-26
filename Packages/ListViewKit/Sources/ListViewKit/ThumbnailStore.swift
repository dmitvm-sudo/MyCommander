// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import QuickLookThumbnailing

// Contract: docs/SDD/06 §6.1 «Уточнение T-32» (F-4) — thumbnails are generated
// in the background (QLThumbnailGenerator) for local URLs only
// (`item.id.displayURL`), lazily per visible row; NSCache caps the count;
// identity/mode guards ride in the caller. The QL default path uses a checked
// continuation with an `@unchecked Sendable` image box (the T-30
// NSMetadataQuery pattern) because QLThumbnailGenerator delivers its callback
// on an unspecified queue.

/// Thumbnail provider of the thumbnail display mode (⌃4).
@MainActor
public final class ThumbnailStore {
    /// Fires on the main actor after a generation finished (cache updated);
    /// the argument is the store key (`cacheKey(for:pixelSize:)`).
    public var onThumbnailUpdated: ((String) -> Void)?

    private let cache = NSCache<NSString, NSImage>()
    /// In-flight keys — repeated row requests are coalesced.
    private var pending: Set<String> = []
    /// Test seam (module tests use a synchronous fake; the real QL pipeline
    /// stays runtime-only, T-34 manual smoke).
    var fakeGenerator: ((URL, CGSize) -> NSImage?)?
    /// Ordered keys of started generations (test seam).
    private(set) var startedKeys: [String] = []

    public init(cacheLimit: Int = 1000) {
        cache.countLimit = cacheLimit
    }

    /// Cached image or nil. A nil result starts ONE async request; the row is
    /// re-rendered when `onThumbnailUpdated` fires (and the caller re-asks).
    public func thumbnail(for item: VFSItem, pixelSize: CGSize) -> NSImage? {
        guard item.id.root.kind == .localDisk, let url = item.id.displayURL else { return nil }
        let key = Self.cacheKey(for: item.id, pixelSize: pixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        startedKeys.append(key)
        if let fake = fakeGenerator {
            finish(key: key, with: fake(url, pixelSize))
        } else {
            Task { [weak self] in
                await self?.generateAndFinish(url: url, key: key, pixelSize: pixelSize)
            }
        }
        return nil
    }

    /// True while one generation for the key is still running (test seam).
    func isPending(_ key: String) -> Bool { pending.contains(key) }

    /// Forgetting the in-flight list (mode left ⌃4 / rebind): later completions
    /// still land in the cache, but the row-reload listener no-ops via its
    /// view-mode guard. New requests may start immediately.
    func cancelPending() {
        pending.removeAll()
    }

    /// Stable cache/render key: instance spec + path + requested pixel size.
    /// Pure → nonisolated (testable from any actor, and the caller computes
    /// it before touching the store).
    nonisolated static func cacheKey(for path: VFSPath, pixelSize: CGSize) -> String {
        path.root.specID
            + "@" + path.components.joined(separator: "/")
            + "#\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }

    /// One QL generation: the callback queue is unspecified → the result rides
    /// through a Sendable box back to the store (main actor).
    private func generateAndFinish(url: URL, key: String, pixelSize: CGSize) async {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<SendableImage, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: pixelSize,
                    scale: 2.0,
                    representationTypes: .thumbnail
                ),
                completion: { thumbnail, _ in
                    continuation.resume(returning: SendableImage(image: thumbnail?.nsImage))
                }
            )
        }
        finish(key: key, with: result.image)
    }

    private func finish(key: String, with image: NSImage?) {
        pending.remove(key)
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        onThumbnailUpdated?(key)
    }
}

/// The NSImage is created on an unspecified QL queue; the box crosses the
/// isolation boundary, the image is unpacked on the main actor only.
private struct SendableImage: @unchecked Sendable {
    let image: NSImage?
}
