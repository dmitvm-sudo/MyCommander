// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import ListViewKit

// T-33 (F-23 частично — docs/SDD/06 §6.9 «Уточнение T-33»): the LV side of
// theming — `FileListView.applyTheme` paints the panel list surface (table
// background + alternating colors) and the cell color tokens; `nil` restores
// the system surface. AppKit-free parts of the theme (NSApp.appearance
// light/dark) live in the App layer and are smoke-checked by T-34. Helpers
// use the `thm` name-space (the test module compiles neighbouring files
// together; headless rendering per the T-18 pattern).

private func thmItem(name: String, isHidden: Bool = false) -> VFSItem {
    let root = VFSInstanceID(kind: .localDisk, credentialRef: nil, specID: "thm-unit")
    let id = VFSPath(
        root: root,
        components: [name],
        displayURL: URL(fileURLWithPath: "/tmp/thm/" + name)
    )
    var item = VFSItem(
        id: id,
        instance: id.root,
        name: name,
        kind: .file,
        attributes: VFSItemAttributes()
    )
    item.attributes.isHidden = isHidden
    return item
}

@MainActor
private func thmView(items: [VFSItem]) -> FileListView {
    let view = FileListView(
        viewModel: PanelViewModel(source: InMemoryVFS(name: "thm-vfs")),
        iconCache: ItemCache()
    )
    view.viewModel.setItems(items, at: nil)
    return view
}

@MainActor
private func thmColumn(_ identifier: String) -> NSTableColumn {
    NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
}

@Test @MainActor func thmApplyThemePaintsTheSurface() {
    let view = thmView(items: [thmItem(name: "a.txt"), thmItem(name: "b.txt")])
    let theme = PanelTheme.ncBlueClassic

    view.applyTheme(theme)
    #expect(view.listTableView.backgroundColor == theme.rowBackground)
    #expect(view.listTableView.usesAlternatingRowBackgroundColors)

    // Row painting rides the didAdd delegate (NSTableView can't recolor
    // system alternating rows directly).
    let even = NSTableRowView()
    let odd = NSTableRowView()
    view.tableView(view.listTableView, didAdd: even, forRow: 0)
    view.tableView(view.listTableView, didAdd: odd, forRow: 1)
    #expect(even.backgroundColor == theme.rowBackground)
    #expect(odd.backgroundColor == theme.rowAlternate)
}

@Test @MainActor func thmNilThemeRestoresTheSystemSurface() {
    let view = thmView(items: [thmItem(name: "a.txt")])
    let preThemeBackground = view.listTableView.backgroundColor
    view.applyTheme(PanelTheme.ncBlueClassic)
    view.applyTheme(nil)
    #expect(view.listTableView.backgroundColor == preThemeBackground)

    // The delegate no-ops for system rows (theme == nil) — the surface check
    // above covers the restore path.
    view.applyTheme(nil)
    #expect(view.listTableView.backgroundColor == preThemeBackground)
}

@Test @MainActor func thmCellsReceiveTheThemeColors() {
    let view = thmView(items: [thmItem(name: "a.txt"), thmItem(name: "h.txt", isHidden: true)])
    view.applyTheme(PanelTheme.ncBlueClassic)

    guard let nameCell = view.tableView(
        view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 0
    ) as? NameCell else {
        Issue.record("name cell missing")
        return
    }
    #expect(nameCell.textLabel.textColor == PanelTheme.ncBlueClassic.rowText)

    guard let hiddenRowName = view.tableView(
        view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 1
    ) as? NameCell else {
        Issue.record("hidden name cell missing")
        return
    }
    // Hidden files carry the dimmed secondary token over the blue surface.
    #expect(hiddenRowName.textLabel.textColor == PanelTheme.ncBlueClassic.rowSecondaryText)

    guard let metaCell = view.tableView(
        view.listTableView, viewFor: thmColumn(ColumnID.size.rawValue), row: 0
    ) as? MetaCell else {
        Issue.record("meta cell missing")
        return
    }
    #expect(metaCell.textLabel.textColor == PanelTheme.ncBlueClassic.rowSecondaryText)
}

@Test @MainActor func thmSystemThemeKeepsSystemColors() {
    let view = thmView(items: [thmItem(name: "a.txt")])
    guard let nameCell = view.tableView(
        view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 0
    ) as? NameCell else {
        Issue.record("name cell missing")
        return
    }
    // nil theme = system label colors.
    #expect(nameCell.textLabel.textColor == NSColor.labelColor)
}

@Test @MainActor func thmBadgeFollowsTheThemeToken() throws {
    // T-36 polish: the symlink/hidden/locked badge rides the SAME secondary
    // token as the hidden names — a constant dark badge is illegible on the
    // ncBlue surface. VM sorts name-ascending: row0 = a.txt (clean),
    // row1 = h2.txt (hidden badge), row2 = r.txt (locked badge).
    var hidden = thmItem(name: "h2.txt")
    hidden.attributes.isHidden = true
    var locked = thmItem(name: "r.txt")
    locked.attributes.isReadOnly = true
    let view = thmView(items: [locked, thmItem(name: "a.txt"), hidden])
    view.applyTheme(PanelTheme.ncBlueClassic)

    let cleanCell = try #require(
        view.tableView(view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 0)
            as? NameCell
    )
    #expect(cleanCell.badgeText.isEmpty)
    #expect(cleanCell.badgeTextColor == PanelTheme.ncBlueClassic.rowSecondaryText)

    let hiddenCell = try #require(
        view.tableView(view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 1)
            as? NameCell
    )
    #expect(hiddenCell.badgeText == String(localized: "cell.badge.hidden"))
    #expect(hiddenCell.badgeTextColor == PanelTheme.ncBlueClassic.rowSecondaryText)

    let lockedCell = try #require(
        view.tableView(view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 2)
            as? NameCell
    )
    #expect(lockedCell.badgeText == String(localized: "cell.badge.locked"))
    #expect(lockedCell.badgeTextColor == PanelTheme.ncBlueClassic.rowSecondaryText)

    // nil theme: fresh viewFor calls carry the system secondary color (the
    // headless table has no visible rows — the captured instances above are
    // not repainted by applyTheme(nil) itself).
    view.applyTheme(nil)
    let restored = try #require(
        view.tableView(view.listTableView, viewFor: thmColumn(ColumnID.name.rawValue), row: 2)
            as? NameCell
    )
    #expect(restored.badgeText == String(localized: "cell.badge.locked"))
    #expect(restored.badgeTextColor == NSColor.secondaryLabelColor)
}
