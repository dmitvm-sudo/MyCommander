// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
import DomainKit
@testable import ListViewKit

// T-13: Quick Look integration (F-9) — item building, the data source's
// count/index access, and ↑/↓ navigation logic of the shared panel controller
// (the panel itself stays UI-level: tests pass `nil` panels).
// Helpers use the `qk` name-space (the test module compiles neighbouring
// files together).

private func qkURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/qk-fixture")
        .appendingPathComponent(".mc-preview-test-\(UUID().uuidString)")
        .appendingPathComponent(name)
}

@MainActor
@Test func qkItemsCarryURLAndDisplayName() {
    let url = qkURL("report.pdf")
    let item = QuickLookItem(url: url, displayName: "report.pdf")
    #expect(item.previewItemURL == url)
    #expect(item.previewItemTitle == "report.pdf")
}

@MainActor
@Test func qkDataSourceCountsAndClamps() {
    func item(_ name: String) -> QuickLookItem { QuickLookItem(url: qkURL(name), displayName: name) }
    let controller = QuickLookController(items: [item("a.txt"), item("b.txt")], startIndex: 1)

    #expect(controller.numberOfPreviewItems(in: nil) == 2)
    // Index access clamps into [0, count-1].
    let atHigh = controller.previewPanel(nil, previewItemAt: 99)
    #expect(atHigh?.previewItemTitle == "b.txt")
    let atLow = controller.previewPanel(nil, previewItemAt: -3)
    #expect(atLow?.previewItemTitle == "a.txt")
    #expect(controller.currentIndex == 1)
}

@MainActor
@Test func qkArrowNavigationThroughList() {
    func item(_ name: String) -> QuickLookItem { QuickLookItem(url: qkURL(name), displayName: name) }
    let controller = QuickLookController(items: [item("x.doc"), item("y.doc"), item("z.doc")], startIndex: 0)

    // Down (keyCode 125) — moves the controller's current index and reports
    // handling; the panel keeps its own currentPreviewItemIndex in sync.
    #expect(controller.previewPanel(nil, handle: nil) == false)   // nil event: not handled
    let downEvent = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 125
    )
    #expect(controller.previewPanel(nil, handle: downEvent) == true)
    #expect(controller.currentIndex == 1)
    #expect(controller.previewPanel(nil, handle: downEvent) == true)
    #expect(controller.currentIndex == 2)
    // At the tail: still handled (no movement).
    #expect(controller.previewPanel(nil, handle: downEvent) == true)
    #expect(controller.currentIndex == 2)

    let upEvent = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 126
    )
    #expect(controller.previewPanel(nil, handle: upEvent) == true)
    #expect(controller.currentIndex == 1)
}
