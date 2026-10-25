// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation

// Contract: docs/SDD/06 §6.1 «Контракт v1 (T-16)» — the DnD transport bridge
// (F-18). Pure read/clear/write over NSPasteboard content: one dragged row is
// one `NSPasteboardItem` with a `.fileURL` type (Finder-compatible) plus the
// `panel-item` type carrying the `VFSPath` as JSON (panel↔panel planner input).
// ListViewKit stays VFS-free: the App layer supplies URLs/paths per row.

public enum DragBridge {
    /// Custom item type: one JSON-encoded `VFSPath` per pasteboard item.
    public static let itemType = NSPasteboard.PasteboardType("com.mycommander.panel-item.v1")
    /// Types a drag destination must register for.
    public static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, itemType]

    /// One dragged row as a pasteboard item: the local file URL (Finder
    /// accepts `NSURL` fileURL items) and the VFSPath payload ( planners).
    public static func entry(fileURL: URL?, path: VFSPath?) -> NSPasteboardItem? {
        guard fileURL != nil || path != nil else { return nil }
        let item = NSPasteboardItem()
        if let fileURL {
            let representation = (fileURL as NSURL).dataRepresentation
            item.setData(representation, forType: .fileURL)
        }
        if let path {
            guard let data = try? JSONEncoder().encode(path) else { return nil }
            item.setData(data, forType: itemType)
        }
        return item
    }

    /// Local file URLs written by Finder or by this app's drag source.
    public static func readURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls ?? []
    }

    /// One `VFSPath` per pasteboard item that carries the panel-item payload.
    public static func readPaths(_ pasteboard: NSPasteboard) -> [VFSPath] {
        pasteboard.pasteboardItems?.compactMap { item in
            guard let data = item.data(forType: itemType) else { return nil }
            return try? JSONDecoder().decode(VFSPath.self, from: data)
        } ?? []
    }
}
