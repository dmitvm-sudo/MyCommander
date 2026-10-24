// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import ListViewKit

// T-06: panel watch-loop integration with a fake engine (docs/SDD/06 §6.3;
// contract §5.4). The real FSEventsWatcher is covered in VFSKitTests; here we
// prove the panel behaviour: external diffs apply as row deltas (no full
// reload), selection survives merges, stale events are dropped after
// navigation. Helpers are private (module compiles files together).

private func watchTestInstance() -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, specID: "watch-unit")
}

private func watchItem(root: VFSInstanceID, name: String, size: Int64 = 1) -> VFSItem {
    VFSItem(
        id: VFSPath(root: root, components: [name]),
        instance: root,
        name: name,
        kind: .file,
        attributes: VFSItemAttributes(size: size),
        revision: 1
    )
}

/// In-memory FileWatchEngineProtocol fake: registrations are recorded so tests
/// can await them; `emit` fans the event out to every continuation watching a
/// matching path.
private final class WatchableFakeEngine: FileWatchEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [VFSPath: [UUID: AsyncStream<WatchEvent>.Continuation]] = [:]

    func watch(_ path: VFSPath, options: WatchOptions) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            let subscription = UUID()
            self.lock.lock()
            self.registrations[path, default: [:]][subscription] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.registrations[path]?[subscription] = nil
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: WatchEvent, to path: VFSPath) {
        let targets: [AsyncStream<WatchEvent>.Continuation]
        lock.lock()
        targets = Array(registrations[path]?.values ?? [:].values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func hasRegistration(for path: VFSPath) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(registrations[path]?.isEmpty ?? true)
    }
}

@MainActor
private func waitFor(
    deadline interval: Double = 3.0,
    stepNanoseconds: UInt64 = 5_000_000,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: stepNanoseconds)
    }
    return condition()
}

@Test @MainActor func externalDiffAppliesAsDeltaWithoutFullReload() async throws {
    let engine = WatchableFakeEngine()
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("base", in: root)

    let vm = PanelViewModel(source: fake)
    vm.watchEngine = engine
    var contentChanges = 0
    var deltas: [FileListDelta] = []
    vm.onContentsChanged = { contentChanges += 1 }
    vm.onContentsDelta = { deltas.append($0) }

    let directory = watchTestInstance()
    let listing = [watchItem(root: directory, name: "aaa.txt"), watchItem(root: directory, name: "zzz.txt")]
    let watchedPath = VFSPath(root: directory, components: ["base"])
    vm.setItems(listing, at: watchedPath)
    #expect(contentChanges == 1)

    // The watch loop is a detached task: await its registration before piping.
    #expect(await waitFor { engine.hasRegistration(for: watchedPath) })

    let selected = listing[0].id
    vm.setSelection([selected])

    engine.emit(
        .itemsChanged(diff: DirectoryDiff(added: [watchItem(root: directory, name: "zzzzzz.txt")])),
        to: watchedPath
    )
    #expect(await waitFor { deltas.count == 1 })

    // Delta path: no full reload fired; insertion lands in sorted position.
    #expect(contentChanges == 1)
    #expect(deltas[0].inserted == [2])
    #expect(vm.visibleCount == 3)
    var visibleNames: [String] = []
    for index in 0 ..< vm.visibleCount {
        if let item = vm.item(atVisibleIndex: index) { visibleNames.append(item.name) }
    }
    #expect(visibleNames == ["aaa.txt", "zzz.txt", "zzzzzz.txt"])
    // Selection survives the external merge (identity-based, docs/SDD/06 §6.1).
    #expect(vm.selection == [selected])
}

@Test @MainActor func volumeEventIsIgnoredByThePanelLoop() async throws {
    let engine = WatchableFakeEngine()
    let fake = InMemoryVFS()
    let vm = PanelViewModel(source: fake)
    vm.watchEngine = engine

    var contentChanges = 0
    var deltas: [FileListDelta] = []
    vm.onContentsChanged = { contentChanges += 1 }
    vm.onContentsDelta = { deltas.append($0) }

    let directory = watchTestInstance()
    let watchedPath = VFSPath(root: directory, components: ["somedir"])
    vm.setItems([watchItem(root: directory, name: "a.txt")], at: watchedPath)
    #expect(await waitFor { engine.hasRegistration(for: watchedPath) })

    engine.emit(
        .volumeEvent(volume: VFSInstanceID(kind: .localDisk, specID: "external-volume"), mounted: true),
        to: watchedPath
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(contentChanges == 1)
    #expect(deltas.isEmpty)
}

@Test @MainActor func staleEventsAfterNavigationDoNotApply() async throws {
    let engine = WatchableFakeEngine()
    let fake = InMemoryVFS()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    _ = try await fake.createDirectory("beta", in: root)

    let vm = PanelViewModel(source: fake)
    vm.watchEngine = engine
    var deltas: [FileListDelta] = []
    vm.onContentsDelta = { deltas.append($0) }

    let directory = watchTestInstance()
    let oldPath = VFSPath(root: directory, components: ["alpha"])
    // The panel's source is the InMemoryVFS fake: navigation paths must carry
    // ITS instance identity (watchTestInstance is only the fixture identity).
    vm.setItems([watchItem(root: directory, name: "a.txt")], at: oldPath)
    #expect(await waitFor { engine.hasRegistration(for: oldPath) })

    // Navigate away: the panel re-watches the new directory.
    let newPath = VFSPath(root: fake.id, components: ["beta"])
    try await vm.openDirectory(at: newPath)
    #expect(await waitFor { engine.hasRegistration(for: newPath) })

    // A spectator event for the OLD directory must not touch the panel.
    engine.emit(
        .itemsChanged(diff: DirectoryDiff(added: [watchItem(root: directory, name: "leaked.txt")])),
        to: oldPath
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(deltas.isEmpty)
    #expect(vm.path == newPath)
}
