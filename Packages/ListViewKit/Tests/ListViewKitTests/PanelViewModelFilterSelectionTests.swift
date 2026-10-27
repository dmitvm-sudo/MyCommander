// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import ListViewKit

// T-07: quick filter (F-10) and the selection model (F-3) on PanelViewModel.
// Helpers are private and name-spaced (the module compiles files together).

private func fsInstance() -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, specID: "fsg-unit")
}

private func fsItem(
    root: VFSInstanceID,
    name: String,
    isDirectory: Bool = false,
    size: Int64 = 1
) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: [name]),
        instance: root,
        name: name,
        kind: isDirectory ? .directory : .file,
        attributes: VFSItemAttributes(size: size),
        revision: 1
    )
}

@MainActor
private func fsVisibleNames(of vm: PanelViewModel) -> [String] {
    (0 ..< vm.visibleCount).compactMap { vm.item(atVisibleIndex: $0)?.name }
}

@MainActor
private func fsSelectionNames(of vm: PanelViewModel) -> [String] {
    (0 ..< vm.visibleCount)
        .compactMap { vm.item(atVisibleIndex: $0) }
        .filter { vm.selection.contains($0.id) }
        .map(\.name)
        .sorted()
}

@Test @MainActor func filterNarrowsVisibilityKeepingSortOrder() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    vm.setItems([
        fsItem(root: root, name: "report.txt"),
        fsItem(root: root, name: "photo.png"),
        fsItem(root: root, name: "notes.txt"),
        fsItem(root: root, name: "archive.zip")
    ], at: nil)

    vm.setFilter("txt")
    #expect(vm.isFilterActive)
    #expect(fsVisibleNames(of: vm) == ["notes.txt", "report.txt"])

    vm.clearFilter()
    #expect(!vm.isFilterActive)
    #expect(fsVisibleNames(of: vm) == ["archive.zip", "notes.txt", "photo.png", "report.txt"])
}

@Test @MainActor func filterStrokeAppliesAsDeltaAndCursorStaysInContext() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    vm.setItems([
        fsItem(root: root, name: "a1.txt"),
        fsItem(root: root, name: "a2.txt"),
        fsItem(root: root, name: "b1.png")
    ], at: nil)

    var deltas = 0
    var reloads = 0
    vm.onContentsDelta = { _ in deltas += 1 }
    vm.onContentsChanged = { reloads += 1 }

    vm.setCursor(2)   // on b1.png
    vm.setFilter("a")
    // Cursor element is filtered out → clamped into the remaining context.
    #expect(vm.cursor < vm.visibleCount)
    #expect(deltas == 1 && reloads == 0)   // F-1-style batch, not a reload

    // Extension stroke reuses the previous result (§6.6 memoization).
    vm.setFilter("a1")
    #expect(fsVisibleNames(of: vm) == ["a1.txt"])
    #expect(deltas == 2)

    // Non-username keystroke (deletion) → full recompute, still a delta.
    vm.deleteLastFilterCharacter()
    #expect(fsVisibleNames(of: vm) == ["a1.txt", "a2.txt"])
    #expect(deltas == 3)
}

@Test @MainActor func selectionSurvivesFilterCycleAndRestore() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    let items = [
        fsItem(root: root, name: "a.txt"),
        fsItem(root: root, name: "b.png"),
        fsItem(root: root, name: "c.txt")
    ]
    vm.setItems(items, at: nil)
    vm.setSelection([items[0].id, items[2].id])

    vm.setFilter("txt")   // hides b.png; selection must NOT lose it
    #expect(fsSelectionNames(of: vm) == ["a.txt", "c.txt"])
    #expect(vm.selection.count == 2)

    vm.clearFilter()
    #expect(fsSelectionNames(of: vm) == ["a.txt", "c.txt"])   // b.png was never selected
}

@Test @MainActor func acceptFilterPutsCursorOnFirstMatch() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    vm.setItems([
        fsItem(root: root, name: "zzz.txt"),
        fsItem(root: root, name: "aaa.txt")
    ], at: nil)
    vm.setCursor(1)

    vm.setFilter("txt")
    vm.acceptFilter()
    #expect(vm.cursor == 0)   // first match in sorted order: aaa.txt
    #expect(vm.item(atVisibleIndex: 0)?.name == "aaa.txt")
}

@Test @MainActor func selectionOperationsFollowF3Semantics() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    let items = [
        fsItem(root: root, name: "a.png"),
        fsItem(root: root, name: "b.png"),
        fsItem(root: root, name: "c.txt")
    ]
    vm.setItems(items, at: nil)

    // Space/Ins: toggle under cursor and move down.
    vm.toggleSelectionUnderCursorAndMove()
    #expect(vm.selection == [items[0].id])
    #expect(vm.cursor == 1)
    vm.toggleSelectionUnderCursorAndMove()
    #expect(vm.selection == [items[0].id, items[1].id])
    #expect(vm.cursor == 2)

    // Num + with a mask (F-3: «выделить по шаблону»).
    vm.deselectAll()
    vm.select(matching: FileMask(["*.png"]))
    #expect(fsSelectionNames(of: vm) == ["a.png", "b.png"])

    // Num * invert: the .txt row gets selected.
    vm.invertAll()
    #expect(fsSelectionNames(of: vm) == ["c.txt"])

    // Num / restore: back to the pre-invert state.
    vm.restoreSelection()
    #expect(fsSelectionNames(of: vm) == ["a.png", "b.png"])

    // Num − with a mask removes only matched rows.
    vm.deselect(matching: FileMask(["*.png"]))
    #expect(vm.selection.isEmpty)
}

@Test @MainActor func effectiveSelectionFallsBackToCursorItem() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    let items = [
        fsItem(root: root, name: "a.txt"),
        fsItem(root: root, name: "b.txt")
    ]
    vm.setItems(items, at: nil)

    #expect(vm.effectiveSelection == [items[0].id])   // empty → cursor item
    vm.setSelection([items[1].id])
    #expect(vm.effectiveSelection == [items[1].id])   // explicit wins
    vm.setSelection([])
    vm.setCursor(99)
    #expect(vm.effectiveSelection == [items[1].id])   // clamped cursor
}

@Test @MainActor func refreshKeepsSurvivingSelectionAndRemembersDropped() {
    let root = fsInstance()
    let path = VFSPath(root: root, components: ["dir"])
    let vm = PanelViewModel(source: InMemoryVFS())
    let items = [
        fsItem(root: root, name: "keep.txt"),
        fsItem(root: root, name: "vanish.txt")
    ]
    vm.setItems(items, at: path)
    vm.setSelection([items[0].id, items[1].id])

    // Refresh of the SAME path: vanish.txt is gone → its selection is dropped
    // but remembered (F-3 «Restore selection»).
    vm.setItems([items[0]], at: path)
    #expect(vm.selection == [items[0].id])
    #expect(vm.previousSelection == [items[0].id, items[1].id])

    vm.restoreSelection()
    #expect(vm.selection == [items[0].id, items[1].id])
}

@Test @MainActor func navigationResetsFilterAndSelection() async throws {
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    _ = try await fake.createDirectory("beta", in: root)

    let vm = PanelViewModel(source: fake)
    try await vm.openDirectory(at: root)
    vm.setFilter("alp")
    #expect(vm.isFilterActive)

    try await vm.openDirectory(at: VFSPath(root: fake.id, components: ["beta"]))
    #expect(!vm.isFilterActive)
    #expect(vm.selection.isEmpty)
    #expect(vm.cursor == 0)
}

@Test @MainActor func setViewModeNotifiesAndSticks() {
    let vm = PanelViewModel(source: InMemoryVFS())
    var notifications = 0
    vm.onContentsChanged = { notifications += 1 }

    vm.setViewMode(.brief)
    #expect(vm.viewMode == .brief)
    #expect(notifications == 1)
    vm.setViewMode(.brief)   // no-op → silent
    #expect(notifications == 1)
    vm.setViewMode(.full)
    #expect(notifications == 2)
}

@Test @MainActor func filterStyleIsSwitchableToFuzzy() {
    let root = fsInstance()
    let vm = PanelViewModel(source: InMemoryVFS())
    vm.filterStyle = .fuzzy
    vm.setItems([
        fsItem(root: root, name: "my-report-2026.txt"),
        fsItem(root: root, name: "photo.png")
    ], at: nil)

    vm.setFilter("mr2")   // m…r…2 subsequence of my-report-2026
    #expect(fsVisibleNames(of: vm) == ["my-report-2026.txt"])
}
