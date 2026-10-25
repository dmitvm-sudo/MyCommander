// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import FileOpsKit
import Foundation
@preconcurrency import Quartz

// Contract: docs/SDD/02 F-9 — Quick Look integration: ⌘Y opens QLPreviewPanel
// over the selected files (temp copies for non-local VFS come from
// PreviewMaterializer); native QL formats, and ↑/↓ moves through the list.

/// One native preview entry. The display name is carried separately so a VFS
/// temp copy (`~/tmp/.mc-preview-…/doc.md`) shows the original name.
public final class QuickLookItem: NSObject, QLPreviewItem {
    public let url: URL
    public let displayName: String

    public init(url: URL, displayName: String) {
        self.url = url
        self.displayName = displayName
    }

    public var previewItemURL: URL? { url }
    public var previewItemTitle: String! { displayName }
}

/// Data source + delegate for the shared preview panel (T-13 v1: the panel
/// takes its data source here before becoming key — docs/SDD/12, Уточнение T-13).
@MainActor
public final class QuickLookController: NSViewController, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    public private(set) var items: [QuickLookItem]
    public private(set) var currentIndex: Int
    private weak var panel: QLPreviewPanel?

    public init(items: [QuickLookItem], startIndex: Int = 0) {
        self.items = items
        self.currentIndex = max(0, min(startIndex, items.count - 1))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("QuickLookController is created programmatically only")
    }

    // MARK: QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard !items.isEmpty else { return nil }
        return items[max(0, min(index, items.count - 1))]
    }

    // MARK: QLPreviewPanelDelegate — ↑/↓ navigation through the preview list

    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, items.count > 1,
              event.keyCode == 125 || event.keyCode == 126   // ↓ download / ↑ up
        else { return false }
        let step = event.keyCode == 125 ? 1 : -1
        let next = max(0, min(currentIndex + step, items.count - 1))
        guard next != currentIndex else { return true }
        currentIndex = next
        panel?.currentPreviewItemIndex = next
        panel?.reloadData()
        return true
    }

    // MARK: Panel control (responder chain contract) — the informal
    // ObjC-category overrides arrive nonisolated; hop onto the main actor.

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            self.panel = panel
            panel.dataSource = self
            panel.delegate = self
        }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            self.panel = nil
        }
    }
}

public enum QuickLookPresenter {
    /// Orders the native preview panel front over `requests` (F-9). When
    /// requests are empty nothing happens (nothing selected).
    @MainActor
    public static func show(urls: [(url: URL, displayName: String)], startIndex: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        let items = urls.map { QuickLookItem(url: $0.url, displayName: $0.displayName) }
        let controller = QuickLookController(items: items, startIndex: startIndex)
        currentController = controller
        controller.beginPreviewPanelControl(panel)
        panel.currentPreviewItemIndex = controller.currentIndex
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keeps the data source alive while the panel is open (AppKit holds only
    /// weak references to the dataSource).
    @MainActor
    private static var currentController: QuickLookController?
}
