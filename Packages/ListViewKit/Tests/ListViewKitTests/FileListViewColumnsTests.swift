// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import Foundation
import Testing
import VFSKit
@testable import ListViewKit

// T-32 (F-4 — docs/SDD/06 §6.1 «Уточнение T-32»): the four view modes
// (⌃1..⌃4), the custom-columns preset plumbing and the ThumbnailStore
// pipeline over the test fake (the real QL generator stays runtime-only).
// Helpers use the `clt` name-space (the test module compiles neighbouring
// files together); FileListView renders cell-for-column headlessly (T-18
// SettingsFontTests pattern).

private func cltInstance(_ spec: String) -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, credentialRef: nil, specID: spec)
}

private func cltItem(name: String, spec: String = "clt-unit") -> VFSItem {
    let id = VFSPath(
        root: cltInstance(spec),
        components: [name],
        displayURL: URL(fileURLWithPath: "/tmp/clt/" + name)
    )
    return VFSItem(
        id: id,
        instance: id.root,
        name: name,
        kind: .file,
        attributes: VFSItemAttributes()
    )
}

@MainActor
private func cltView() -> FileListView {
    let view = FileListView(
        viewModel: PanelViewModel(source: InMemoryVFS(name: "clt-vfs")),
        iconCache: ItemCache()
    )
    view.viewModel.setItems([cltItem(name: "a.txt"), cltItem(name: "b.txt")], at: nil)
    return view
}

@MainActor
private func cltIdentifiers(_ view: FileListView) -> [String] {
    view.listTableView.tableColumns.map { $0.identifier.rawValue }
}

@MainActor
private func cltColumn(_ identifier: String) -> NSTableColumn {
    NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
}

// MARK: view modes (⌃1..⌃4)

@Test @MainActor func cltSetViewModeNotifiesOncePerChange() {
    let vm = PanelViewModel(source: InMemoryVFS(name: "clt-vm"))
    var changes = 0
    vm.onContentsChanged = { changes += 1 }
    vm.setViewMode(.full)          // the default mode — silent no-op
    #expect(changes == 0)
    vm.setViewMode(.brief)
    vm.setViewMode(.columns)
    vm.setViewMode(.thumbnails)
    vm.setViewMode(.thumbnails)
    #expect(changes == 3)
    #expect(vm.viewMode == .thumbnails)
}

@Test @MainActor func cltColumnsFollowTheViewMode() {
    let view = cltView()
    // Default `full` (⌃1): the name + size + modified trio.
    #expect(cltIdentifiers(view) == [ColumnID.name.rawValue, ColumnID.size.rawValue, ColumnID.dateModified.rawValue])
    #expect(view.listTableView.rowHeight == FileListView.rowHeight)

    // `brief` (⌃2): names only.
    view.viewModel.setViewMode(.brief)
    #expect(cltIdentifiers(view) == [ColumnID.name.rawValue])

    // `columns` (⌃3): the default preset trio before any settings edit.
    view.viewModel.setViewMode(.columns)
    #expect(cltIdentifiers(view) == [ColumnID.name.rawValue, ColumnID.size.rawValue, ColumnID.dateModified.rawValue])

    // `thumbnails` (⌃4): name + the thumbnail pseudo-column, tall rows.
    view.viewModel.setViewMode(.thumbnails)
    #expect(cltIdentifiers(view) == [ColumnID.name.rawValue, "thumbnail"])
    #expect(view.listTableView.rowHeight == FileListView.thumbnailRowHeight)
    #expect(cltColumn("thumbnail").identifier.rawValue == "thumbnail")   // not a ColumnID case

    // Back to `full`: the pre-built height snap.
    view.viewModel.setViewMode(.full)
    #expect(view.listTableView.rowHeight == FileListView.rowHeight)
}

@Test @MainActor func cltApplyColumnPresetOrdersAndSanitizes() {
    let view = cltView()
    view.viewModel.setViewMode(.columns)
    view.applyColumnPreset([.size, .tags, .name, .gitStatus, .size, .owner])
    // name is always first (§5.9), duplicates collapse, gitStatus is cut
    // until the F-27 providers.
    #expect(cltIdentifiers(view) == ["name", "size", "tags", "owner"])

    // A preset applied in another mode is remembered, not rendered.
    view.viewModel.setViewMode(.brief)
    view.applyColumnPreset([.tags, .owner])
    #expect(cltIdentifiers(view) == ["name"])
    view.viewModel.setViewMode(.columns)
    #expect(cltIdentifiers(view) == ["name", "tags", "owner"])
}

@Test @MainActor func cltMetaStaticsRenderTheCustomColumns() {
    var item = cltItem(name: "a-photo.png")
    item.attributes.created = Date(timeIntervalSinceReferenceDate: 700_000_000)
    item.attributes.modified = Date(timeIntervalSinceReferenceDate: 800_000_000)
    item.attributes.size = 1234
    item.attributes.posixPermissions = 0o644
    item.attributes.owner = "dmitrij"
    item.attributes.tags = ["blue", "project"]

    let view = cltView()
    // The mutated copy must be the item the table actually displays; sorted
    // first, so row 0 renders it.
    view.viewModel.setItems([item, cltItem(name: "b.txt")], at: nil)
    view.viewModel.setViewMode(.columns)
    view.applyColumnPreset([
        .name, .size, .dateModified, .dateCreated,
        .kind, .tags, .permissions, .owner
    ])

    func text(_ column: String) -> String? {
        (view.tableView(view.listTableView, viewFor: cltColumn(column), row: 0) as? MetaCell)?
            .textLabel.stringValue
    }

    #expect(text(ColumnID.dateCreated.rawValue) == MetaCell.createdText(of: item))
    #expect(text(ColumnID.dateModified.rawValue) == MetaCell.modifiedText(of: item))
    #expect(text(ColumnID.size.rawValue) == MetaCell.sizeText(of: item))
    #expect(text(ColumnID.permissions.rawValue) == "644")
    #expect(text(ColumnID.owner.rawValue) == "dmitrij")
    #expect(text(ColumnID.tags.rawValue) == "blue, project")
    #expect(MetaCell.kindText(of: item).isEmpty == false)
}

// MARK: ThumbnailStore (the fake generator keeps QL runtime-only)

@Test @MainActor func cltThumbnailStoreFakeGenerationLifecycle() {
    let store = ThumbnailStore()
    let image = NSImage(size: NSSize(width: 40, height: 40))
    store.fakeGenerator = { _, _ in image }
    let item = cltItem(name: "pic.png")
    let pixel = CGSize(width: 40, height: 40)
    let key = ThumbnailStore.cacheKey(for: item.id, pixelSize: pixel)

    var updates: [String] = []
    store.onThumbnailUpdated = { updates.append($0) }

    // First miss starts ONE generation and returns nothing yet.
    #expect(store.thumbnail(for: item, pixelSize: pixel) == nil)
    #expect(store.startedKeys == [key])
    #expect(updates == [key])        // the fake completes synchronously
    #expect(store.isPending(key) == false)

    // The second request takes the cache — no new generation.
    let cached = store.thumbnail(for: item, pixelSize: pixel)
    #expect(cached === image)
    #expect(store.startedKeys.count == 1)
}

@Test @MainActor func cltThumbnailStoreNotifiesForTheRightKey() {
    let store = ThumbnailStore()
    let imageA = NSImage(size: NSSize(width: 40, height: 40))
    let imageB = NSImage(size: NSSize(width: 60, height: 60))
    store.fakeGenerator = { url, _ in
        url.lastPathComponent == "a.png" ? imageA : imageB
    }
    let a = cltItem(name: "a.png")
    let b = cltItem(name: "b.png")
    let small = CGSize(width: 40, height: 40)
    let large = CGSize(width: 60, height: 60)

    var updates: [String] = []
    store.onThumbnailUpdated = { updates.append($0) }

    #expect(store.thumbnail(for: a, pixelSize: small) == nil)
    #expect(store.thumbnail(for: b, pixelSize: small) == nil)
    #expect(store.thumbnail(for: a, pixelSize: large) == nil)
    #expect(updates.count == 3)

    #expect(store.thumbnail(for: a, pixelSize: small) === imageA)
    #expect(store.thumbnail(for: a, pixelSize: large) === imageA)
    #expect(store.thumbnail(for: b, pixelSize: small) === imageB)
    #expect(store.startedKeys.count == 3)
}

@Test @MainActor func cltThumbnailStoreSkipsNonLocalItems() {
    let store = ThumbnailStore()
    var started = 0
    store.fakeGenerator = { _, _ in
        started += 1
        return nil
    }
    // A non-local root (archive mount) can never carry a displayURL — the
    // store refuses it before caching/generating.
    let root = VFSInstanceID(kind: .archive, credentialRef: nil, specID: "clt-remote")
    let id = VFSPath(root: root, components: ["inside.png"], displayURL: nil)
    let item = VFSItem(id: id, instance: root, name: "inside.png", kind: .file, attributes: VFSItemAttributes())

    #expect(store.thumbnail(for: item, pixelSize: CGSize(width: 40, height: 40)) == nil)
    #expect(started == 0)
    #expect(store.startedKeys.isEmpty)
}

@Test func cltThumbnailCacheKeysAreStableAndSpecific() {
    let root = cltInstance("spec-a")
    let path = VFSPath(root: root, components: ["d", "f.png"])
    #expect(ThumbnailStore.cacheKey(for: path, pixelSize: CGSize(width: 40, height: 40)) == "spec-a@d/f.png#40x40")
    #expect(
        ThumbnailStore.cacheKey(for: path, pixelSize: CGSize(width: 60, height: 60))
            == "spec-a@d/f.png#60x60"
    )
    // Another instance spec → another key (thumbnail sources never leak
    // across VFS instances).
    let otherRoot = cltInstance("spec-b")
    let other = VFSPath(root: otherRoot, components: ["d", "f.png"])
    #expect(ThumbnailStore.cacheKey(for: other, pixelSize: CGSize(width: 40, height: 40)) == "spec-b@d/f.png#40x40")
}
