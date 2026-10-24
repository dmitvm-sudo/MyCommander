// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import ListViewKit

// T-05: PanelViewModel behaviour (sort/selection/cursor/navigation) and the
// real-browse integration via LocalVFS. Helpers are file-private: the test
// module compiles neighbouring files together (docs/SDD/12, T-04 note).

private func viewModelInstance() -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, credentialRef: nil, specID: "panelvm-unit")
}

private func fixtureItem(
    root: VFSInstanceID,
    name: String,
    isDirectory: Bool = false,
    size: Int64? = nil,
    isHidden: Bool = false
) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: [name]),
        instance: root,
        name: name,
        kind: isDirectory ? .directory : .file,
        attributes: VFSItemAttributes(size: size, isHidden: isHidden),
        revision: 1
    )
}

private func temporaryPanelDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("mclv-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePanelChunk(_ vfs: InMemoryVFS, at components: [String], bytes: Data) async throws {
    let target = VFSPath(root: vfs.id, components: components)
    let writer = try await vfs.openWrite(target, replace: false)
    try await writer.write(bytes)
    try await writer.finish(committingTo: target)
}

@MainActor
private func visibleNames(of vm: PanelViewModel) -> [String] {
    (0 ..< vm.visibleCount).compactMap { vm.item(atVisibleIndex: $0)?.name }
}

@Test @MainActor func setItemsSortsDirectoriesFirstThenNames() async {
    let vm = PanelViewModel(source: InMemoryVFS(), sort: SortCriteria(key: .name))
    let instance = viewModelInstance()
    vm.setItems([
        fixtureItem(root: instance, name: "zebra.txt", size: 1),
        fixtureItem(root: instance, name: "alpha", isDirectory: true),
        fixtureItem(root: instance, name: "mango.txt", size: 2),
    ], at: nil)

    #expect(visibleNames(of: vm) == ["alpha", "mango.txt", "zebra.txt"])
}

@Test @MainActor func selectionSurvivesReSortAndCursorClamps() async {
    let vm = PanelViewModel(source: InMemoryVFS())
    let instance = viewModelInstance()
    let items = [
        fixtureItem(root: instance, name: "dirB", isDirectory: true),
        fixtureItem(root: instance, name: "a.txt"),
        fixtureItem(root: instance, name: "b.txt"),
        fixtureItem(root: instance, name: "c.txt"),
    ]
    vm.setItems(items, at: nil)
    let selectedA = items[1].id
    let selectedC = items[3].id

    vm.setSelection([selectedA, selectedC])
    vm.setCursor(99)
    #expect(vm.cursor == vm.visibleCount - 1)

    vm.setSort(SortCriteria(key: .name, order: .descending))
    #expect(vm.selection == [selectedA, selectedC])
    #expect(vm.cursor <= vm.visibleCount - 1)
    #expect(visibleNames(of: vm) == ["dirB", "c.txt", "b.txt", "a.txt"])
}

@Test @MainActor func selectionChangesAreSilentAndListingChangesNotify() async {
    let vm = PanelViewModel(source: InMemoryVFS())
    var delta = 0
    vm.onContentsChanged = { delta += 1 }
    let instance = viewModelInstance()
    let items = [
        fixtureItem(root: instance, name: "a.txt"),
        fixtureItem(root: instance, name: "b.txt"),
    ]
    vm.setItems(items, at: nil)
    #expect(delta == 1)

    vm.setSelection([items[0].id])
    vm.setCursor(0)
    #expect(delta == 1)   // selection/cursor are silent: no reload feedback loop

    vm.setSort(SortCriteria(key: .name, order: .descending))
    #expect(delta == 2)
    #expect(visibleNames(of: vm) == ["b.txt", "a.txt"])
}

@Test @MainActor func setItemsAtKeepsPathForStatusLine() async {
    let vm = PanelViewModel(source: InMemoryVFS())
    let fake = InMemoryVFS(name: "WithPath")
    let root = VFSPath(root: fake.id)
    vm.setItems([], at: root)
    #expect(vm.path == root)
    #expect(vm.visibleCount == 0)
}

@Test @MainActor func openItemNavigatesIntoDirectoryGoUpAndRootGuard() async throws {
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    _ = try await fake.createDirectory("beta", in: root)
    try await writePanelChunk(fake, at: ["beta", "readme.txt"], bytes: Data("hi".utf8))

    let vm = PanelViewModel(source: fake)
    try await vm.openDirectory(at: root)
    #expect(vm.visibleCount == 2)   // alpha, beta (readme lives inside beta)

    let opened = await vm.openItem(atVisibleIndex: 0)   // «alpha»
    #expect(opened?.components.last == "alpha")
    #expect(vm.visibleCount == 0)   // empty directory
    #expect(vm.path?.components.last == "alpha")

    #expect(await vm.goUp() == true)
    #expect(vm.visibleCount == 2)
    #expect(await vm.goUp() == false)   // root: components empty
    #expect(vm.path?.components.isEmpty == true)
}

@Test @MainActor func listingFailureSurfacesThroughOnErrorCallback() async throws {
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    let vm = PanelViewModel(source: fake)
    try await vm.openDirectory(at: root)

    let denied = MCError.vfsAccessDenied(root, underlying: nil)
    fake.injectFailure(denied, for: [.listDirectory])
    var captured: MCError?
    vm.onError = { captured = $0 }
    await vm.reload()

    guard case .vfsAccessDenied = captured else {
        Issue.record("expected vfsAccessDenied, got \(String(describing: captured))")
        return
    }
    // A failed reload keeps the previous listing on screen.
    #expect(vm.path == root)
}

@Test @MainActor func listingFailureIsRethrownFromOpenDirectory() async throws {
    let fake = InMemoryVFS()
    let denied = MCError.vfsNotFound(VFSPath(root: fake.id, components: ["ghost"]))
    fake.injectFailure(denied, for: [.listDirectory])
    let vm = PanelViewModel(source: fake)
    await #expect(throws: MCError.self) {
        try await vm.openDirectory(at: VFSPath(root: fake.id))
    }
}

@Test @MainActor func openItemOnFileIsIgnored() async throws {
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    try await writePanelChunk(fake, at: ["only.txt"], bytes: Data("x".utf8))
    let vm = PanelViewModel(source: fake)
    try await vm.openDirectory(at: root)

    let opened = await vm.openItem(atVisibleIndex: 0)
    #expect(opened == nil)
    #expect(vm.visibleCount == 1)
}

@Test @MainActor func localBrowseRoundTripNavigateUpDown() async throws {
    let root = temporaryPanelDirectory("browse")
    defer { try? FileManager.default.removeItem(at: root) }
    let vfs = LocalVFS(at: root, instanceID: VFSInstanceID(kind: .localDisk, specID: "browse-unit"))
    try FileManager.default.createFile(
        atPath: root.appendingPathComponent("compact.txt").path,
        contents: Data("c".utf8)
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("alpha"),
        withIntermediateDirectories: false
    )

    let vm = PanelViewModel(source: vfs)
    try await vm.openDirectory(at: VFSPath(root: vfs.id))
    #expect(visibleNames(of: vm) == ["alpha", "compact.txt"])   // dirs first, names asc

    let alphaRow = visibleNames(of: vm).firstIndex(of: "alpha") ?? -1
    #expect(alphaRow == 0)
    _ = await vm.openItem(atVisibleIndex: alphaRow)
    #expect(vm.path?.components.last == "alpha")
    #expect(vm.visibleCount == 0)

    #expect(await vm.goUp() == true)
    #expect(visibleNames(of: vm) == ["alpha", "compact.txt"])
    #expect(await vm.goUp() == false)   // adapter root == OS root for this pane
}

@Test @MainActor func sortingFiftyThousandItemsStaysUnderBudget() async {
    let vm = PanelViewModel(source: InMemoryVFS())
    let instance = viewModelInstance()
    var items: [VFSItem] = []
    items.reserveCapacity(50_000)
    for index in 0 ..< 50_000 {
        let isTree = index % 50 == 0
        items.append(fixtureItem(
            root: instance,
            name: isTree ? "tree\(index)" : "leaf-\(index % 4096)-\(index).txt",
            isDirectory: isTree,
            size: Int64(index % 97)
        ))
    }

    let started = Date()
    vm.setItems(items, at: nil)
    let listingElapsed = Date().timeIntervalSince(started)

    #expect(vm.visibleCount == 50_000)
    // Each 50th synthetic entry is a directory: dirs-first must present ALL of
    // them ahead of the first file row.
    var directoryRun = 0
    while let item = vm.item(atVisibleIndex: directoryRun) {
        if case .directory = item.kind {
            directoryRun += 1
        } else {
            break
        }
    }
    #expect(directoryRun == 1_000)
    // N-1 data-side budget: sort + visibility recomputation for 50k under 1 s.
    #expect(listingElapsed < 1.0, "50k listing took \(listingElapsed)s")
}
