// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import ListViewKit
import VFSKit

/// Active/opposite panel dispatcher (docs/SDD/11: PanelsCoordinator — активная/
/// противопоставленная панели, диспетчер операций) plus menu action entry
/// points. T-05 scope: navigation (Enter / ⌘↑ handled inside the panel table),
/// reload, home, focus switching, panel swap. Panel contexts (active/other) are
/// derived here through `FocusController`, which later feeds the CommandRouter.
@MainActor
final class PanelsCoordinator: NSObject {
    let focus = FocusController()
    private(set) var leftPane: FileListView!
    private(set) var rightPane: FileListView!

    /// The panel's data source. Volume identity note: `LocalVFS(at: "/")` owns
    /// the system disk; a `VFSRegistry`-driven per-volume adapter set (browse
    /// into other disks) comes with the registry task — single-disk browsing is
    /// the T-05 gate («navigate local disk directories»).
    private let fileSystem: LocalVFS
    /// Watch engine (T-06, docs/SDD/06 §6.3): one FSEventStream serves every
    /// watched directory of the file system above; both panels subscribe.
    private let watcher: FSEventsWatcher
    /// Volume mount/unmount fan-out (§5.4 `.volumeEvent`).
    private let volumeMonitor = VolumeMonitor()
    private var volumeTask: Task<Void, Never>?

    private var homePath: VFSPath {
        VFSPath.local(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    override init() {
        let fileSystem = LocalVFS(at: URL(fileURLWithPath: "/"))
        self.fileSystem = fileSystem
        self.watcher = FSEventsWatcher(vfs: fileSystem)
        super.init()
        let leftModel = PanelViewModel(source: fileSystem)
        let rightModel = PanelViewModel(source: fileSystem)
        leftModel.watchEngine = watcher
        rightModel.watchEngine = watcher
        leftPane = FileListView(viewModel: leftModel)
        rightPane = FileListView(viewModel: rightModel)
        leftPane.onActivated = { [weak self] in self?.focus.activate(.left) }
        rightPane.onActivated = { [weak self] in self?.focus.activate(.right) }
        focus.onFocusChanged = { [weak self] side in self?.applyFocus(side) }
    }

    deinit {
        volumeTask?.cancel()
    }

    /// Loads the initial listing of both panels (called at app launch).
    func start() async {
        try? await leftPane.viewModel.openDirectory(at: homePath)
        try? await rightPane.viewModel.openDirectory(at: homePath)
        applyFocus(.left)
        startVolumeLoop()
    }

    /// Unmount handling (§5.4/T-06): a panel currently browsing the volume that
    /// vanished reloads — the failed listing flows into `onError` and shows in
    /// the status line. Matching is by instance identity; per-volume panel
    /// instances arrive with the VFSRegistry task (browsing mounts through the
    /// single `/`-rooted adapter cannot match by identity — see «Уточнение T-06»).
    private func startVolumeLoop() {
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.volumeMonitor.subscribe() {
                guard case .volumeEvent(let instance, let mounted) = event else { continue }
                guard !mounted else { continue }   // mount handling: VFSRegistry task
                if self.leftPane.viewModel.path?.root == instance {
                    await self.leftPane.viewModel.reload()
                }
                if self.rightPane.viewModel.path?.root == instance {
                    await self.rightPane.viewModel.reload()
                }
            }
        }
    }

    private var activePane: FileListView? {
        focus.activePanel == .left ? leftPane : rightPane
    }

    private func applyFocus(_ side: FocusController.PanelSide) {
        let pane: FileListView = side == .left ? leftPane! : rightPane!
        pane.listTableView.window?.makeFirstResponder(pane.listTableView)
    }

    // MARK: menu action entry points (MenuBuilder targets)

    @objc func mcGoUp(_ sender: Any?) {
        guard let pane = activePane else { return }
        Task { _ = await pane.viewModel.goUp() }
    }

    @objc func mcReload(_ sender: Any?) {
        guard let pane = activePane else { return }
        Task { await pane.viewModel.reload() }
    }

    @objc func mcGoHome(_ sender: Any?) {
        guard let pane = activePane else { return }
        let target = homePath
        Task { try? await pane.viewModel.openDirectory(at: target) }
    }

    @objc func mcFocusLeft(_ sender: Any?) {
        focus.activate(.left)
    }

    @objc func mcFocusRight(_ sender: Any?) {
        focus.activate(.right)
    }

    @objc func mcSwapPanels(_ sender: Any?) {
        let leftModel = leftPane.viewModel
        let rightModel = rightPane.viewModel
        leftPane.rebind(viewModel: rightModel)
        rightPane.rebind(viewModel: leftModel)
        applyFocus(focus.activePanel)
    }

    // MARK: view modes (F-4 start: full/brief, docs/SDD/12 T-07)

    @objc func mcViewFull(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.viewModel.setViewMode(.full)
    }

    @objc func mcViewBrief(_ sender: Any?) {
        guard let pane = activePane else { return }
        pane.viewModel.setViewMode(.brief)
    }
}
