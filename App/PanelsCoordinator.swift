// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import ListViewKit
import ServicesKit
import VFSKit

/// Active/opposite panel dispatcher (docs/SDD/11: PanelsCoordinator — активная/
/// противопоставленная панели, диспетчер операций) plus menu action entry
/// points. T-08: each pane is a `PanelViewController` (tabs + file list);
/// the coordinator owns the two tab lists, the session save/restore (F-2) and
/// the volume unmount loop (T-06).
@MainActor
final class PanelsCoordinator: NSObject {
    let focus = FocusController()
    private(set) var leftPane: PanelViewController!
    private(set) var rightPane: PanelViewController!
    private var leftTabList: PanelTabList!
    private var rightTabList: PanelTabList!

    /// The panels' data source. Volume identity note: `LocalVFS(at: "/")` owns
    /// the system disk; a `VFSRegistry`-driven per-volume adapter set comes with
    /// the registry task.
    private let fileSystem: LocalVFS
    /// Watch engine (T-06): one FSEventStream serves every watched directory of
    /// the file system above; every tab's view model subscribes.
    private let watcher: FSEventsWatcher
    /// Volume mount/unmount fan-out (§5.4 `.volumeEvent`).
    private let volumeMonitor = VolumeMonitor()
    private var volumeTask: Task<Void, Never>?
    /// Session persistence (F-2: tabs survive relaunch).
    private let sessionStore: SessionStore

    private var homePath: VFSPath {
        VFSPath.local(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    override init() {
        let fileSystem = LocalVFS(at: URL(fileURLWithPath: "/"))
        self.fileSystem = fileSystem
        self.watcher = FSEventsWatcher(vfs: fileSystem)
        self.sessionStore = SessionStore()
        super.init()

        // F-2: the tab stacks survive relaunch; a missing/foreign session falls
        // back to one home tab per panel.
        if !restoreSession() {
            leftTabList = makeTabList()
            leftTabList.seed(with: homePath)
            rightTabList = makeTabList()
            rightTabList.seed(with: homePath)
        }

        leftPane = PanelViewController(tabList: leftTabList)
        rightPane = PanelViewController(tabList: rightTabList)
        leftPane.fileListView.onActivated = { [weak self] in self?.focus.activate(.left) }
        rightPane.fileListView.onActivated = { [weak self] in self?.focus.activate(.right) }
        focus.onFocusChanged = { [weak self] side in self?.applyFocus(side) }
    }

    deinit {
        volumeTask?.cancel()
    }

    private func makeTabList() -> PanelTabList {
        PanelTabList(
            makeViewModel: { [fileSystem, watcher] in
                let viewModel = PanelViewModel(source: fileSystem)
                viewModel.watchEngine = watcher
                return viewModel
            },
            watchEngine: watcher
        )
    }

    /// Loads the initial listing state (called at app launch). Restored tabs
    /// load their own directories asynchronously during `appendTab`.
    func start() async {
        applyFocus(.left)
        startVolumeLoop()
    }

    /// Called on termination: persist both panels' tab stacks (F-2).
    func saveSession() {
        sessionStore.save(SessionSnapshot(
            left: panelSnapshot(of: leftPane),
            right: panelSnapshot(of: rightPane)
        ))
    }

    private func panelSnapshot(of panel: PanelViewController) -> PanelTabsSnapshot {
        let (tabs, activeIndex) = panel.snapshotTabs()
        let tabSnapshots = tabs.map { tab in
            PanelTabsSnapshot.TabSnapshot(
                path: tab.viewModel.path ?? homePath,
                isLocked: tab.isLocked,
                selection: tab.viewModel.selection,
                historyBack: tab.history.back,
                historyForward: tab.history.forward
            )
        }
        return PanelTabsSnapshot(tabs: tabSnapshots, activeIndex: activeIndex)
    }

    private func restoreSession() -> Bool {
        guard let snapshot = sessionStore.load(),
              !snapshot.left.tabs.isEmpty, !snapshot.right.tabs.isEmpty
        else { return false }
        leftTabList = makeTabList()
        rightTabList = makeTabList()
        restorePanel(leftTabList, from: snapshot.left)
        restorePanel(rightTabList, from: snapshot.right)
        leftTabList.selectTab(at: min(snapshot.left.activeIndex, max(leftTabList.tabs.count - 1, 0)))
        rightTabList.selectTab(at: min(snapshot.right.activeIndex, max(rightTabList.tabs.count - 1, 0)))
        return true
    }

    private func restorePanel(_ list: PanelTabList, from panel: PanelTabsSnapshot) {
        for tab in panel.tabs {
            list.appendTab(
                at: tab.path,
                locked: tab.isLocked,
                restoringSelection: tab.selection,
                insertionIndex: list.tabs.count
            )
        }
        // Note (docs/SDD/12 T-08): back/forward history is not restored in the
        // v1 session format — the tab comes back at its final location.
    }

    /// Unmount handling (§5.4/T-06): a panel currently browsing the volume that
    /// vanished reloads — the failed listing flows into `onError` and shows in
    /// the status line. Matching is by instance identity; per-volume panel
    /// instances arrive with the VFSRegistry task.
    private func startVolumeLoop() {
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.volumeMonitor.subscribe() {
                guard case .volumeEvent(_, let mounted) = event else { continue }
                guard !mounted else { continue }   // mount handling: VFSRegistry task
                for tab in self.leftPane.tabList.tabs {
                    await tab.viewModel.reload()
                }
                for tab in self.rightPane.tabList.tabs {
                    await tab.viewModel.reload()
                }
            }
        }
    }

    private var activePane: PanelViewController? {
        focus.activePanel == .left ? leftPane : rightPane
    }

    private func applyFocus(_ side: FocusController.PanelSide) {
        let pane: PanelViewController = side == .left ? leftPane! : rightPane!
        pane.listTableView.window?.makeFirstResponder(pane.listTableView)
    }

    // MARK: menu action entry points (MenuBuilder targets)

    @objc func mcGoUp(_ sender: Any?) {
        guard let pane = activePane else { return }
        Task { _ = await pane.fileListView.viewModel.goUp() }
    }

    @objc func mcReload(_ sender: Any?) {
        guard let pane = activePane else { return }
        Task { await pane.fileListView.viewModel.reload() }
    }

    @objc func mcGoHome(_ sender: Any?) {
        guard let pane = activePane else { return }
        let target = homePath
        Task { try? await pane.fileListView.viewModel.openDirectory(at: target) }
    }

    @objc func mcFocusLeft(_ sender: Any?) {
        focus.activate(.left)
    }

    @objc func mcFocusRight(_ sender: Any?) {
        focus.activate(.right)
    }

    @objc func mcSwapPanels(_ sender: Any?) {
        guard let leftList = leftTabList, let rightList = rightTabList else { return }
        leftPane.adoptTabList(rightList)
        rightPane.adoptTabList(leftList)
        leftTabList = rightList
        rightTabList = leftList
        applyFocus(focus.activePanel)
    }

    // MARK: tabs (F-2: ⌘T / ⌘W / ⌘⇧T)

    /// ⌘T: a new tab next to the active one, in the same directory (classic
    /// NC/TC behaviour); a locked tab diverts here by design.
    @objc func mcNewTab(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sourcePath = pane.tabList.activeTab?.viewModel.path ?? homePath
        _ = pane.tabList.appendTab(at: sourcePath)
    }

    @objc func mcCloseTab(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.tabList.closeTab(at: pane.tabList.activeIndex)
    }

    @objc func mcReopenClosedTab(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.tabList.reopenLastClosed()
    }

    // MARK: view modes (F-4 start: full/brief, docs/SDD/12 T-07)

    @objc func mcViewFull(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.fileListView.viewModel.setViewMode(.full)
    }

    @objc func mcViewBrief(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.fileListView.viewModel.setViewMode(.brief)
    }
}
