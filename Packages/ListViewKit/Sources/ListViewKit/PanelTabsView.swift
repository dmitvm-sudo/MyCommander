// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit

// One file, one story: panel tabs (docs/SDD/02 F-2, §6.1 «страница табов»).
// Contents: NavigationHistory (back/forward), PanelTab + PanelTabList (the
// model: per-tab workdir/selection/filter state lives inside each tab's own
// PanelViewModel), and PanelTabsView + TabCellView (the tab strip UI).

/// Back/forward navigation of one tab. The tab list owns the transitions; the
/// history stores only paths (docs/SDD/02 F-2 «история навигации вперёд/назад»).
public struct NavigationHistory: Sendable {
    public private(set) var back: [VFSPath] = []
    public private(set) var forward: [VFSPath] = []

    public init() {}

    /// A user-driven navigation: the previous location becomes a back entry,
    /// the forward chain is invalidated. Consecutive duplicates collapse.
    public mutating func record(from previous: VFSPath?, to target: VFSPath) {
        guard previous != target else { return }
        if let previous {
            back.append(previous)
            forward.removeAll()
        }
    }

    /// Pops the back entry; `current` becomes a forward entry. Returns the
    /// destination (the caller performs the navigation itself).
    public mutating func popBack(from current: VFSPath?) -> VFSPath? {
        guard let previous = back.popLast() else { return nil }
        if let current { forward.append(current) }
        return previous
    }

    public mutating func popForward(from current: VFSPath?) -> VFSPath? {
        guard let next = forward.popLast() else { return nil }
        if let current { back.append(current) }
        return next
    }
}

/// One tab of a panel: its own PanelViewModel carries the workdir, selection,
/// sort, filter and view mode (F-2 «у каждой tab свой workdir … своё выделение»).
public struct PanelTab {
    public let id: UUID
    public let viewModel: PanelViewModel
    public var isLocked: Bool
    public var history = NavigationHistory()

    /// Tab title = name of the browsed directory (F-2 acceptance). MainActor
    /// because it reads the view model; every reader (tab list, strip UI) is
    /// already main-actor confined.
    @MainActor
    public var title: String {
        guard let path = viewModel.path else { return "/" }
        // Archive interlude root (T-21): empty components + host file URL → name.
        if path.components.isEmpty, let display = path.displayURL {
            return display.lastPathComponent
        }
        return path.components.last ?? "/"
    }

    init(id: UUID, viewModel: PanelViewModel, isLocked: Bool) {
        self.id = id
        self.viewModel = viewModel
        self.isLocked = isLocked
    }
}

/// The tab strip model of one panel. A panel never ends up without a tab:
/// closing the last one is a no-op. Reopening (⌘⇧T) restores the most recently
/// closed tab at its original position, with its full view model state.
@MainActor
public final class PanelTabList {
    public private(set) var tabs: [PanelTab] = []
    public private(set) var activeIndex: Int = 0

    /// Factory for new tab view models (the App assembly wires source +
    /// watch engine); `watchEngine` re-attaches on reopen after a close.
    private let makeViewModel: @MainActor () -> PanelViewModel
    private let watchEngine: (any FileWatchEngineProtocol)?

    /// Closed tabs for ⌘⇧T, newest last; bounded so a closing spree stays cheap.
    private var closedStack: [(position: Int, tab: PanelTab)] = []
    private var closedCapacity = 20
    /// True while a history replay performs the navigation itself.
    private var suppressHistoryRecording = false
    /// Last observed path per tab id — the «previous» for history records.
    private var lastRecordedPaths: [UUID: VFSPath] = [:]

    /// Fires after every structural change: the controller refreshes the tab
    /// strip and rebinds the file list.
    public var onTabsChanged: (() -> Void)?
    /// Fires when a locked tab diverts a navigation into a fresh tab (F-2).
    public var onNavigationDenied: ((VFSPath) -> Void)?

    public init(
        makeViewModel: @MainActor @escaping () -> PanelViewModel,
        watchEngine: (any FileWatchEngineProtocol)? = nil
    ) {
        self.makeViewModel = makeViewModel
        self.watchEngine = watchEngine
    }

    public var activeTab: PanelTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    /// Creates the panel's first tab (idempotent — only when empty).
    public func seed(with path: VFSPath) {
        guard tabs.isEmpty else { return }
        appendTab(at: path, locked: false, restoringSelection: nil, insertionIndex: nil)
    }

    /// Appends a tab and activates it. `path` loads asynchronously; a restored
    /// selection applies after the listing arrives (session restore).
    @discardableResult
    public func appendTab(
        at path: VFSPath?,
        locked: Bool = false,
        restoringSelection: Set<VFSPath>? = nil,
        insertionIndex: Int? = nil
    ) -> Int {
        let tabID = UUID()
        let viewModel = makeViewModel()
        viewModel.watchEngine = watchEngine
        wire(viewModel)
        if let restoringSelection {
            viewModel.stageSelectionRestore(restoringSelection)
        }
        if let path {
            lastRecordedPaths[tabID] = path
            Task { [weak viewModel] in
                try? await viewModel?.openDirectory(at: path)
            }
        }
        let position = insertionIndex.map { min($0, tabs.count) } ?? min(activeIndex + 1, tabs.count)
        let insertAt = min(position, tabs.count)
        tabs.insert(PanelTab(id: tabID, viewModel: viewModel, isLocked: locked), at: insertAt)
        activate(insertAt)
        onTabsChanged?()
        return insertAt
    }

    /// ⌘W. The last tab never closes (the panel must stay browsable).
    public func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        unwire(tab.viewModel)
        tabs.remove(at: index)
        closedStack.append((position: index, tab: tab))
        if closedStack.count > closedCapacity {
            closedStack.removeFirst()
        }
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if activeIndex > index {
            activeIndex -= 1
        }
        onTabsChanged?()
    }

    /// ⌘⇧T: reopens the most recently closed tab at its original position.
    @discardableResult
    public func reopenLastClosed() -> Bool {
        guard let entry = closedStack.popLast() else { return false }
        let position = min(entry.position, tabs.count)
        tabs.insert(entry.tab, at: position)
        wire(entry.tab.viewModel)
        entry.tab.viewModel.watchEngine = watchEngine
        if let restored = lastRecordedPaths[entry.tab.id] {
            // Same semantics as a fresh open: reload the stored directory.
            Task { [weak viewModel = entry.tab.viewModel] in
                try? await viewModel?.openDirectory(at: restored)
            }
        }
        activate(position)
        onTabsChanged?()
        return true
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activate(index)
        onTabsChanged?()
    }

    /// ⌃Tab / ⌃⇧Tab (07 §7.3): cycle within the same panel, wrapping around.
    public func cycleTab(step: Int) {
        guard tabs.count > 1 else { return }
        let wrapped = ((activeIndex + step) % tabs.count + tabs.count) % tabs.count
        activate(wrapped)
        onTabsChanged?()
    }

    public func toggleLock(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isLocked.toggle()
        onTabsChanged?()
    }

    /// History «back» (⌥←-style commands arrive with the keymap task). A locked
    /// tab still follows its own recorded history — the lock governs *new*
    /// navigations only (documented in docs/SDD/12 T-08).
    @discardableResult
    public func navigateBack() -> Bool {
        replay { tab in tab.history.popBack(from: lastRecordedPaths[tab.id]) }
    }

    @discardableResult
    public func navigateForward() -> Bool {
        replay { tab in tab.history.popForward(from: lastRecordedPaths[tab.id]) }
    }

    private func replay(_ pop: (inout PanelTab) -> VFSPath?) -> Bool {
        guard tabs.indices.contains(activeIndex) else { return false }
        var tab = tabs[activeIndex]
        guard let target = pop(&tab) else { return false }
        tabs[activeIndex] = tab
        lastRecordedPaths[tab.id] = target
        suppressHistoryRecording = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.suppressHistoryRecording = false }
            guard self.tabs.indices.contains(self.activeIndex) else { return }
            try? await self.tabs[self.activeIndex].viewModel.openDirectory(at: target, bypassingGate: true)
        }
        return true
    }

    private func activate(_ index: Int) {
        activeIndex = max(0, min(index, max(tabs.count - 1, 0)))
    }

    private func wire(_ viewModel: PanelViewModel) {
        viewModel.navigationGate = { [weak self] target in
            guard let self, let active = self.activeTab, active.isLocked else { return true }
            // F-2: locked tabs never change directory — the opened path lands
            // in a fresh tab next to the locked one.
            self.appendTab(at: target, locked: false, restoringSelection: nil, insertionIndex: self.activeIndex + 1)
            self.onNavigationDenied?(target)
            return false
        }
        viewModel.onPathChanged = { [weak self] path in
            guard let self, !self.suppressHistoryRecording, let path else { return }
            guard self.tabs.indices.contains(self.activeIndex) else { return }
            let activeTab = self.tabs[self.activeIndex]
            let previous = self.lastRecordedPaths[activeTab.id]
            self.tabs[self.activeIndex].history.record(from: previous, to: path)
            self.lastRecordedPaths[activeTab.id] = path
        }
    }

    private func unwire(_ viewModel: PanelViewModel) {
        viewModel.navigationGate = nil
        viewModel.onPathChanged = nil
        viewModel.watchEngine = nil   // stop watching directories of a closed tab
    }

    /// Уточнение T-21 (06 §6.1, archive interlude): swaps the view model of the
    /// ACTIVE tab in place — id and lock survive, history starts fresh, watch is
    /// rewired. Returns the previous view model (the ⌘↑-exit path rebinds it).
    @discardableResult
    public func swapActiveTabViewModel(_ newViewModel: PanelViewModel) -> PanelViewModel? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        let previous = tabs[activeIndex]
        unwire(previous.viewModel)
        previous.viewModel.onContentsChanged = nil
        previous.viewModel.onContentsDelta = nil
        previous.viewModel.onError = nil
        previous.viewModel.onRootExit = nil   // the interlude hook dies with the VM
        lastRecordedPaths.removeValue(forKey: previous.id)
        tabs[activeIndex] = PanelTab(id: previous.id, viewModel: newViewModel, isLocked: previous.isLocked)
        newViewModel.watchEngine = watchEngine
        wire(newViewModel)
        onTabsChanged?()
        return previous.viewModel
    }
}

// MARK: tab strip UI

/// The visual tab strip (§6.1: NSStackView + custom tab cells). Dumb view: the
/// controller feeds `refresh` and receives cell intents as closures.
@MainActor
public final class PanelTabsView: NSView {
    private let stack = NSStackView()
    public var onSelectTab: ((Int) -> Void)?
    public var onCloseTab: ((Int) -> Void)?
    public var onToggleLock: ((Int) -> Void)?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PanelTabsView is created programmatically only")
    }

    /// Rebuilds the strip. With ≤ 20 tabs (F-2 budget) a full rebuild per
    /// change stays far below frame cost; virtualization arrives if ever needed.
    public func refresh(tabs: [PanelTab], activeIndex: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let cell = TabCellView(
                title: tab.title,
                isLocked: tab.isLocked,
                isActive: index == activeIndex
            )
            cell.onSelect = { [weak self] in self?.onSelectTab?(index) }
            cell.onClose = { [weak self] in self?.onCloseTab?(index) }
            cell.onToggleLock = { [weak self] in self?.onToggleLock?(index) }
            stack.addArrangedSubview(cell)
        }
    }
}

/// One tab cell: [lock] title [×]. Click selects; × closes; the lock glyph
/// toggles the lock (F-2 locked tabs).
@MainActor
final class TabCellView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleLock: (() -> Void)?

    private let lockButton = NSButton()
    private let titleButton = NSButton()
    private let closeButton = NSButton()
    private let lockImageView = NSImageView()

    init(title: String, isLocked: Bool, isActive: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 110, height: 22))

        titleButton.title = title
        titleButton.isBordered = false
        titleButton.bezelStyle = .regularSquare
        titleButton.target = self
        titleButton.action = #selector(selectClicked)
        titleButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "tab.close"))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        lockImageView.image = NSImage(systemSymbolName: isLocked ? "lock.fill" : "lock.open", accessibilityDescription: String(localized: "tab.lock"))
        lockImageView.alphaValue = isLocked ? 1.0 : 0.35

        let tapRecognizer = NSClickGestureRecognizer(target: self, action: #selector(lockClicked))
        lockImageView.addGestureRecognizer(tapRecognizer)

        let row = NSStackView(views: [lockImageView, titleButton, closeButton])
        row.orientation = .horizontal
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = isActive
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 4
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            lockImageView.widthAnchor.constraint(equalToConstant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabCellView is created programmatically only")
    }

    @objc private func selectClicked() { onSelect?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func lockClicked() { onToggleLock?() }
}
