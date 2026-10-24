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

    private var homePath: VFSPath {
        VFSPath.local(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    override init() {
        fileSystem = LocalVFS(at: URL(fileURLWithPath: "/"))
        super.init()
        let leftModel = PanelViewModel(source: fileSystem)
        let rightModel = PanelViewModel(source: fileSystem)
        leftPane = FileListView(viewModel: leftModel)
        rightPane = FileListView(viewModel: rightModel)
        leftPane.onActivated = { [weak self] in self?.focus.activate(.left) }
        rightPane.onActivated = { [weak self] in self?.focus.activate(.right) }
        focus.onFocusChanged = { [weak self] side in self?.applyFocus(side) }
    }

    /// Loads the initial listing of both panels (called at app launch).
    func start() async {
        try? await leftPane.viewModel.openDirectory(at: homePath)
        try? await rightPane.viewModel.openDirectory(at: homePath)
        applyFocus(.left)
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
}
