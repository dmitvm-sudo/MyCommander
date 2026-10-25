// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import ListViewKit

// T-18: settings live-apply on the panel font (F-21 MVP, §6.9 v1) — the
// cell factory takes the face at render time; nil restores the default. Test
// helpers use the `sf` name-space (the module tests compile together).

private func sfItem() -> VFSItem {
    let id = VFSPath.local(URL(fileURLWithPath: "/tmp/a.txt"))
    return VFSItem(
        id: id,
        instance: id.root,
        name: "a.txt",
        kind: .file,
        attributes: VFSItemAttributes()
    )
}

/// One column per kind (identifier mirrors ColumnID raw values).
@MainActor
private func sfColumn(_ identifier: String) -> NSTableColumn {
    NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
}

@MainActor
@Test func sfFontAppliesToRenderedCells() throws {
    let view = FileListView(viewModel: PanelViewModel(source: InMemoryVFS(name: "sf-vfs")), iconCache: ItemCache())
    view.viewModel.setItems([sfItem(), sfItem()], at: nil)

    // Default before any setting: monospaced 13 (the module default face).
    guard let nameCell = view.tableView(view.listTableView, viewFor: sfColumn("name"), row: 0) as? NameCell else {
        Issue.record("name cell missing")
        return
    }
    #expect(nameCell.textLabel.font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))

    // Apply a custom face: the next rendered row takes it.
    view.applyPanelFont(NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold))
    guard let reRendered = view.tableView(view.listTableView, viewFor: sfColumn("name"), row: 0) as? NameCell else {
        Issue.record("re-rendered name cell missing")
        return
    }
    #expect(reRendered.textLabel.font?.pointSize == 21)

    // Meta cells ride the same face.
    view.applyPanelFont(NSFont.systemFont(ofSize: 17))
    guard let metaCell = view.tableView(view.listTableView, viewFor: sfColumn("size"), row: 0) as? MetaCell else {
        Issue.record("rendered meta cell missing")
        return
    }
    #expect(metaCell.textLabel.font?.pointSize == 17)

    // nil back to defaults.
    view.applyPanelFont(nil)
    guard let restored = view.tableView(view.listTableView, viewFor: sfColumn("name"), row: 0) as? NameCell else {
        Issue.record("restored name cell missing")
        return
    }
    #expect(restored.textLabel.font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
}
