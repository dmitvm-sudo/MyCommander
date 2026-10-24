// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import ListViewKit
import ServicesKit
import VFSKit

/// Active/opposite panel dispatcher (docs/SDD/11: PanelsCoordinator — активная/
/// противопоставленная панели, диспетчер операций). T-09: every action is a
/// `CommandID` dispatched through `router`; menu key equivalents come from
/// `keymapStore` (active profile «tc» = the 07 map).
@MainActor
final class PanelsCoordinator: NSObject {
    let focus = FocusController()
    let router = CommandRouter()
    let keymapStore: KeymapStore
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
        self.keymapStore = KeymapStore(defaultProfiles: Self.bundledKeymapProfiles())
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

        registerCommandHandlers()
    }

    /// T-09: the bundled 07-map profiles; «tc» must decode first — it is the
    /// active default (docs/SDD/12: «карта 07 активна»).
    private static func bundledKeymapProfiles() -> [KeymapProfile] {
        var profiles: [KeymapProfile] = []
        for name in ["tc", "macos"] {
            guard let url = Bundle.module.url(forResource: "keymap-\(name)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(KeymapProfile.self, from: data)
            else { continue }
            profiles.append(profile)
        }
        return profiles
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

    // MARK: command handlers (T-09: единственный dispatch — CommandRouter)

    private func registerCommandHandlers() {
        // Navigation.
        router.register(.goUp) { [weak self] in
            guard let pane = self?.activePane else { return }
            Task { _ = await pane.fileListView.viewModel.goUp() }
        }
        router.register(.goHome) { [weak self] in
            guard let pane = self?.activePane, let target = self?.homePath else { return }
            Task { try? await pane.fileListView.viewModel.openDirectory(at: target) }
        }
        router.register(.reloadPanel) { [weak self] in
            guard let pane = self?.activePane else { return }
            Task { await pane.fileListView.viewModel.reload() }
        }
        router.register(.openItem) { [weak self] in
            guard let pane = self?.activePane else { return }
            let viewModel = pane.fileListView.viewModel
            Task {
                _ = await viewModel.openItem(atVisibleIndex: viewModel.cursor)
            }
        }

        // Focus / panels.
        router.register(.focusLeft) { [weak self] in self?.focus.activate(.left) }
        router.register(.focusRight) { [weak self] in self?.focus.activate(.right) }
        router.register(.swapPanels) { [weak self] in self?.swapPanels() }

        // Tabs (F-2: ⌘T / ⌘W / ⌘⇧T, ⌃Tab / ⌃⇧Tab).
        router.register(.newTab) { [weak self] in
            guard let pane = self?.activePane else { return }
            let sourcePath = pane.tabList.activeTab?.viewModel.path ?? self?.homePath
            _ = pane.tabList.appendTab(at: sourcePath)
        }
        router.register(.closeTab) { [weak self] in
            guard let pane = self?.activePane else { return }
            pane.tabList.closeTab(at: pane.tabList.activeIndex)
        }
        router.register(.reopenClosedTab) { [weak self] in
            guard let pane = self?.activePane else { return }
            pane.tabList.reopenLastClosed()
        }
        router.register(.nextTab) { [weak self] in
            self?.activePane?.tabList.cycleTab(step: 1)
        }
        router.register(.previousTab) { [weak self] in
            self?.activePane?.tabList.cycleTab(step: -1)
        }

        // Display modes (F-4 start).
        router.register(.viewFull) { [weak self] in
            self?.activePane?.fileListView.viewModel.setViewMode(.full)
        }
        router.register(.viewBrief) { [weak self] in
            self?.activePane?.fileListView.viewModel.setViewMode(.brief)
        }

        // Selection (F-3). The mask commands open a mask prompt (T-07 note:
        // «диалог ввода маски — с командным слоем»).
        router.register(.selectAll) { [weak self] in
            self?.activePane?.fileListView.viewModel.selectAll()
        }
        router.register(.invertAll) { [weak self] in
            self?.activePane?.fileListView.viewModel.invertAll()
        }
        router.register(.restoreSelection) { [weak self] in
            self?.activePane?.fileListView.viewModel.restoreSelection()
        }
        router.register(.selectMasked) { [weak self] in
            self?.beginMaskDialog(deselecting: false)
        }
        router.register(.deselectMasked) { [weak self] in
            self?.beginMaskDialog(deselecting: true)
        }
    }

    private func swapPanels() {
        guard let leftList = leftTabList, let rightList = rightTabList else { return }
        leftPane.adoptTabList(rightList)
        rightPane.adoptTabList(leftList)
        leftTabList = rightList
        rightTabList = leftList
        applyFocus(focus.activePanel)
    }

    // MARK: mask dialog (F-3: Num +/− по шаблону)

    /// Sheet with a one-line mask field; Enter applies, Esc cancels.
    private func beginMaskDialog(deselecting: Bool) {
        guard let pane = activePane, let window = pane.view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: deselecting
            ? "dialog.mask.deselect"
            : "dialog.mask.select")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "dialog.mask.placeholder")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "dialog.mask.apply"))
        alert.addButton(withTitle: String(localized: "dialog.mask.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  !field.stringValue.isEmpty
            else { return }
            let mask = FileMask([field.stringValue])
            let viewModel = self.activePane?.fileListView.viewModel
            if deselecting {
                viewModel?.deselect(matching: mask)
            } else {
                viewModel?.select(matching: mask)
            }
        }
    }
}
