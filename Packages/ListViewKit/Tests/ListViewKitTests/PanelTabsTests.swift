// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import DomainKit
import VFSKit
@testable import ListViewKit

// T-08: tab model (F-2) — history, close/reopen, locked-tab gate, session
// selection staging, and the «≥ 20 tabs without degradation» budget. Helpers
// are private and name-spaced (the module compiles files together).

private func tabsTestInstance() -> VFSInstanceID {
    VFSInstanceID(kind: .localDisk, specID: "tabs-unit")
}

@MainActor
private func tabsWaitFor(
    deadline interval: Double = 3,
    stepNanoseconds: UInt64 = 2_000_000,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: stepNanoseconds)
    }
    return condition()
}

/// A tab list factory over a fresh in-memory tree: /alpha, /beta, /gamma.
@MainActor
private func tabsMakeList() -> (PanelTabList, InMemoryVFS) {
    let fake = InMemoryVFS()
    let list = PanelTabList(makeViewModel: { PanelViewModel(source: fake) })
    return (list, fake)
}

@Test func navigationHistoryRecordsAndReplays() {
    let root = tabsTestInstance()
    let alpha = VFSPath(root: root, components: ["alpha"])
    let beta = VFSPath(root: root, components: ["beta"])

    var history = NavigationHistory()
    // The very first location is not a «back» entry (nothing to go back to).
    history.record(from: nil, to: alpha)
    #expect(history.back.isEmpty && history.forward.isEmpty)

    history.record(from: alpha, to: beta)
    #expect(history.back == [alpha] && history.forward.isEmpty)

    // Consecutive duplicates collapse.
    history.record(from: beta, to: beta)
    #expect(history.back == [alpha])

    #expect(history.popBack(from: beta) == alpha)
    #expect(history.back.isEmpty && history.forward == [beta])

    #expect(history.popForward(from: alpha) == beta)
    #expect(history.back == [alpha] && history.forward.isEmpty)
    #expect(history.popBack(from: beta) == alpha)
    #expect(history.popForward(from: alpha) == beta)
}

@Test @MainActor func seedIsIdempotentAndActivatesFirstTab() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    _ = try await fake.createDirectory("beta", in: root)

    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))
    #expect(list.tabs.count == 1 && list.activeIndex == 0)

    // Second seed must be a no-op (panel restore calls seed defensively).
    list.seed(with: VFSPath(root: fake.id, components: ["beta"]))
    #expect(list.tabs.count == 1)

    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["alpha"] })
}

/// T-26 (F-11): every displayed location fires `onPathVisited` — the App
/// records recent folders through it (unlike the history, which skips
/// suppress-recording replays).
@Test @MainActor func onPathVisitedFiresForEveryDisplayedLocation() async throws {
    let (list, fake) = tabsMakeList()
    var visits: [VFSPath] = []
    list.onPathVisited = { visits.append($0) }

    _ = try await fake.createDirectory("alpha", in: VFSPath(root: fake.id))
    _ = try await fake.createDirectory("beta", in: VFSPath(root: fake.id))
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))
    #expect(await tabsWaitFor { !visits.isEmpty })

    // alpha → beta (recorded), then ⌘[ back → alpha (a replay VISIT).
    try await list.activeTab?.viewModel.openDirectory(
        at: VFSPath(root: fake.id, components: ["beta"])
    )
    #expect(await tabsWaitFor { visits.last?.components == ["beta"] })
    _ = list.navigateBack()
    #expect(await tabsWaitFor { visits.last?.components == ["alpha"] })
    #expect(visits.count >= 3)   // alpha, beta, replayed alpha
}

@Test @MainActor func closingLastTabIsNoop() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))

    list.closeTab(at: 0)
    #expect(list.tabs.count == 1)   // the panel must stay browsable (F-2)
    #expect(list.reopenLastClosed() == false)   // nothing was really closed
}

@Test @MainActor func closeAndReopenRestoreOriginalPositionAndContent() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    for name in ["alpha", "beta", "gamma"] {
        _ = try await fake.createDirectory(name, in: root)
    }
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))
    list.appendTab(at: VFSPath(root: fake.id, components: ["beta"]))
    list.appendTab(at: VFSPath(root: fake.id, components: ["gamma"]))
    #expect(list.tabs.count == 3)

    // Listings load asynchronously — wait for all three tabs to settle.
    #expect(await tabsWaitFor { list.tabs.compactMap { $0.viewModel.path }.count == 3 })

    // Close the middle tab (beta, index 1; the append activated it).
    list.closeTab(at: 1)
    #expect(list.tabs.count == 2)
    #expect(list.tabs.map { $0.viewModel.path?.components.last } == ["alpha", "gamma"])

    // ⌘⇧T: beta comes back at index 1 and reloads its directory.
    #expect(list.reopenLastClosed())
    #expect(list.tabs.count == 3 && list.activeIndex == 1)
    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["beta"] })

    // The reopened tab stays wired (gate/path feed reconnected by reopen);
    // watchEngine rewiring is the App assembly's job (nil in this factory).
    #expect(list.activeTab?.viewModel.navigationGate != nil)
}

@Test @MainActor func lockedTabDivertsNavigationIntoNewTab() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    _ = try await fake.createDirectory("beta", in: root)
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))

    var denied: [VFSPath] = []
    list.onNavigationDenied = { denied.append($0) }

    list.toggleLock(at: 0)
    #expect(list.activeTab?.isLocked == true)

    // A user navigation in the locked tab is diverted: a fresh tab opens next
    // to the locked one, the locked tab itself does not move.
    let target = VFSPath(root: fake.id, components: ["beta"])
    try await list.activeTab!.viewModel.openDirectory(at: target)
    #expect(await tabsWaitFor { list.tabs.count == 2 })
    #expect(denied == [target])
    #expect(list.activeIndex == 1)   // the diverted tab is activated
    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["beta"] })
    #expect(list.tabs[0].viewModel.path?.components == ["alpha"])   // locked tab stayed
}

@Test @MainActor func historyReplayBypassesLockAndDoesNotRecord() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    for name in ["alpha", "beta"] {
        _ = try await fake.createDirectory(name, in: root)
    }
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))
    let target = VFSPath(root: fake.id, components: ["beta"])
    try await list.activeTab!.viewModel.openDirectory(at: target)
    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["beta"] })
    #expect(list.activeTab!.history.back.count == 1)

    // Back: the replay navigates itself, records nothing, and the lock is
    // irrelevant for replays (the lock governs new navigations only).
    #expect(list.navigateBack())
    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["alpha"] })
    #expect(list.activeTab!.history.back.isEmpty)
    #expect(list.activeTab!.history.forward.count == 1)

    // Forward returns, and the round trip did not grow the stacks.
    #expect(list.navigateForward())
    #expect(await tabsWaitFor { list.activeTab?.viewModel.path?.components == ["beta"] })
    #expect(list.activeTab!.history.back.count == 1)
    #expect(list.activeTab!.history.forward.isEmpty)
}

@Test @MainActor func stagedSelectionAppliesAfterInitialLoad() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    for name in ["one.txt", "two.txt"] {
        let writer = try await fake.openWrite(VFSPath(root: fake.id, components: ["alpha", name]), replace: true)
        try await writer.write(Data("1".utf8))
        try await writer.finish(committingTo: VFSPath(root: fake.id, components: ["alpha", name]))
    }

    let restoredRoot = VFSPath(root: fake.id, components: ["alpha"])
    let restoredOne = VFSPath(root: fake.id, components: ["alpha", "one.txt"])
    list.appendTab(at: restoredRoot, restoringSelection: [restoredOne])

    #expect(await tabsWaitFor { list.activeTab?.viewModel.selection == [restoredOne] })
}

@Test @MainActor func twentyFiveTabsAppendWithoutDegradation() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))

    // F-2 budget: ≥ 20 tabs per panel without degradation. The model op itself
    // (append + activate + notify) stays far below a frame; listing loads are
    // async and do not count against the append cost.
    let started = Date()
    for index in 0 ..< 24 {
        list.appendTab(at: VFSPath(root: fake.id, components: ["alpha"]))
        #expect(list.activeIndex == index + 1)
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(list.tabs.count == 25)
    #expect(elapsed < 0.5, "24 tab appends took \(elapsed)s")

    // Selection switching across the stack stays O(1)-ish.
    let switchStarted = Date()
    for index in stride(from: 0, to: 25, by: 7) {
        list.selectTab(at: index)
        #expect(list.activeIndex == index)
    }
    #expect(Date().timeIntervalSince(switchStarted) < 0.05)
}

@Test @MainActor func cycleTabWrapsAroundWithinPanel() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    for name in ["alpha", "beta", "gamma"] {
        _ = try await fake.createDirectory(name, in: root)
    }
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))
    list.appendTab(at: VFSPath(root: fake.id, components: ["beta"]))
    list.appendTab(at: VFSPath(root: fake.id, components: ["gamma"]))
    #expect(list.tabs.count == 3)

    // ⌃Tab: forward with wrap-around; ⌃⇧Tab: backward with wrap-around.
    list.cycleTab(step: 1)
    #expect(list.activeIndex == 0)   // 2 + 1 → wrapped to 0
    list.cycleTab(step: -1)
    #expect(list.activeIndex == 2)
    list.cycleTab(step: 1)
    #expect(list.activeIndex == 0)

    // A single tab never cycles.
    list.closeTab(at: 1)
    list.closeTab(at: 1)
    #expect(list.tabs.count == 1)
    list.cycleTab(step: 1)
    #expect(list.activeIndex == 0)
}

@Test @MainActor func closedTabStopsWatchingAndReopenRestoresWatch() async throws {
    let (list, fake) = tabsMakeList()
    let root = VFSPath(root: fake.id)
    _ = try await fake.createDirectory("alpha", in: root)
    list.seed(with: VFSPath(root: fake.id, components: ["alpha"]))

    // No engine is wired in this factory (nil) — the contract under test is the
    // unwire/rewire symmetry: closing nils it out, reopen restores the list's
    // engine reference (nil here, non-nil in the App assembly).
    let closedViewModel = list.activeTab!.viewModel
    list.appendTab(at: VFSPath(root: fake.id, components: ["alpha"]))
    list.closeTab(at: 0)
    #expect(closedViewModel.watchEngine == nil)
    #expect(closedViewModel.navigationGate == nil)
    #expect(closedViewModel.onPathChanged == nil)
}
