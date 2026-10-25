// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit

/// The whole panel (docs/SDD/06 §6.1): tab strip on top, the file list of the
/// active tab below (the status line lives inside `FileListView`). The tab
/// strip is a dumb view — this controller is the single place that keeps the
/// tab model (`PanelTabList`) and the visible list in sync.
@MainActor
public final class PanelViewController: NSViewController {
    public private(set) var tabList: PanelTabList
    private let tabsView = PanelTabsView()
    public let fileListView: FileListView
    private let iconCache: ItemCache

    /// First-responder routing for `FocusController` (docs/SDD/06 §6.1).
    public var listTableView: PanelTableView {
        fileListView.listTableView
    }

    /// Replaces the tab list (⌘U swap): reconnect the change feed, rebuild.
    public func adoptTabList(_ newTabList: PanelTabList) {
        tabList.onTabsChanged = nil
        tabList = newTabList
        wireTabList()
        refreshFromTabList(force: true)
    }

    /// Уточнение T-21 (06 §6.1/§6.4, archive interlude): swaps the ACTIVE tab's
    /// view model in place and refreshes the strip + list. Returns the previous
    /// view model — the ⌘↑-root-exit path rebinds it back.
    @discardableResult
    public func swapActiveTabViewModel(_ newViewModel: PanelViewModel) -> PanelViewModel? {
        let previous = tabList.swapActiveTabViewModel(newViewModel)
        refreshFromTabList(force: true)
        return previous
    }

    /// Session snapshots (T-08) are assembled by the App layer from the tab
    /// model; the controller only guarantees the tab list is live.
    public func snapshotTabs() -> (tabs: [PanelTab], activeIndex: Int) {
        (tabList.tabs, tabList.activeIndex)
    }

    public init(tabList: PanelTabList, iconCache: ItemCache = ItemCache()) {
        self.tabList = tabList
        self.iconCache = iconCache
        guard let activeViewModel = tabList.activeTab?.viewModel else {
            fatalError("PanelTabList must be seeded before building the panel view")
        }
        fileListView = FileListView(viewModel: activeViewModel, iconCache: iconCache)
        super.init(nibName: nil, bundle: nil)
        buildLayout()
        wireTabList()
        refreshFromTabList(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("PanelViewController is created programmatically only")
    }

    override public func loadView() {
        let container = NSStackView(views: [tabsView, fileListView])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
            tabsView.widthAnchor.constraint(equalTo: container.widthAnchor),
            fileListView.widthAnchor.constraint(equalTo: container.widthAnchor),
        ])
    }

    private func buildLayout() {
        tabsView.onSelectTab = { [weak self] in self?.tabList.selectTab(at: $0) }
        tabsView.onCloseTab = { [weak self] in self?.tabList.closeTab(at: $0) }
        tabsView.onToggleLock = { [weak self] in self?.tabList.toggleLock(at: $0) }
    }

    private func wireTabList() {
        tabList.onTabsChanged = { [weak self] in self?.refreshFromTabList(force: false) }
    }

    private func refreshFromTabList(force: Bool) {
        tabsView.refresh(tabs: tabList.tabs, activeIndex: tabList.activeIndex)
        if let viewModel = tabList.activeTab?.viewModel, force || fileListView.viewModel !== viewModel {
            fileListView.rebind(viewModel: viewModel)
        }
    }
}
