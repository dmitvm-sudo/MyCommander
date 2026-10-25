// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import ListViewKit

// T-17: the access badge (F-20 / §6.10 v1) — the App-provided localized label
// rides the status line; nil keeps it away. Helpers use the `ab` name-space
// (the test module compiles neighbouring files together).

@MainActor
@Test func abBadgeAppendsAndClearsInStatusLine() {
    let viewModel = PanelViewModel(source: InMemoryVFS(name: "ab-vfs"))
    let view = FileListView(viewModel: viewModel, iconCache: ItemCache())

    // The base status has no badge row.
    #expect(!view.statusText.contains("FDA"))

    view.accessBadge = "FDA"
    #expect(view.statusText.contains("FDA"))

    // A re-run replaces the text (Safe Mode: zones in the label).
    view.accessBadge = "SAFE Desktop, Documents"
    #expect(view.statusText.contains("SAFE Desktop, Documents"))
    #expect(!view.statusText.contains("FDA"))

    // nil removes the badge row again.
    view.accessBadge = nil
    #expect(!view.statusText.contains("SAFE Desktop"))
}
