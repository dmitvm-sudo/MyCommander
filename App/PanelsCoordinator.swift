// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import FileOpsKit
import ListViewKit
import ServicesKit
import TerminalKit
import VFSKit

/// Active/opposite panel dispatcher (docs/SDD/11: PanelsCoordinator — активная/
/// противопоставленная панели, диспетчер операций). T-09: every action is a
/// `CommandID` dispatched through `router`; menu key equivalents come from
/// `keymapStore` (active profile «tc» = the 07 map).
@MainActor
final class PanelsCoordinator: NSObject {
    let focus = FocusController()
    let router = CommandRouter()
    /// Command bar (⌘L, F-17а / §6.8 v1): hosted by MainWindowController at
    /// the window bottom; the driver below parses and executes its lines.
    let commandBar = CommandBarView()
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

    /// Operations engine (F-5, T-10): one executor for the shared local VFS;
    /// per-adapter executors arrive with the VFSRegistry task.
    private let transferJournal = JournalStorage()
    private let transferEvents = TransferEvents()
    private var operationExecutor: OperationExecutor!
    private var progressWindow: ProgressWindowController?

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

        operationExecutor = OperationExecutor(
            source: fileSystem,
            destination: fileSystem,
            journal: transferJournal,
            events: transferEvents
        )
        registerCommandHandlers()
        wireCommandBar()
    }

    /// F-17а wiring: the bar submits raw lines, 07 §7.2 single-focus contract
    /// on Esc (clear the line first, second Esc returns to the panel list).
    private func wireCommandBar() {
        commandBar.onSubmit = { [weak self] raw in
            self?.handleCommandBarLine(raw)
        }
        commandBar.onEscape = { [weak self] in
            guard let self else { return }
            if !commandBar.inputText.isEmpty {
                commandBar.clearInput()
            } else {
                activatePanelList()
            }
        }
        commandBar.updatePrompt(displayPath: posixPath(homePath))
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
        // Command bar (⌘L, T-14 / F-17а v1).
        router.register(.focusCommandBar) { [weak self] in
            self?.commandBar.focusInput()
        }

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

        // Operations (F-5 core, T-10/T-11): copy and move act on the effective
        // selection of the active pane into the opposite pane (TC semantics);
        // delete trashes the selection by default (F-5). The progress window
        // observes the events.
        router.register(.copyFiles) { [weak self] in
            self?.beginTransferToOppositePane(.copy)
        }
        router.register(.moveRenameFiles) { [weak self] in
            self?.beginTransferToOppositePane(.move)
        }
        router.register(.deleteFiles) { [weak self] in
            self?.beginDeleteSelection()
        }

        // View (F-8/F-9, T-13): Lister on the first selected file (F3), the
        // external editor (F4) and the native Quick Look (⌘Y) over the
        // effective selection.
        router.register(.viewFile) { [weak self] in
            self?.openLister()
        }
        router.register(.editFile) { [weak self] in
            self?.editFirstInExternalEditor()
        }
        router.register(.quickLook) { [weak self] in
            self?.quickLookSelection()
        }
        // Info card (F-19, T-15): ⌃A / remap over the cursor item.
        router.register(.itemInfo) { [weak self] in
            self?.openItemInfo()
        }
    }

    // MARK: Command bar driver (⌘L — F-17а, T-14; 06 §6.8 v1)

    /// Raw typed line → expanded+parsed command → executed against the
    /// active panel's VFS. ListViewKit knows nothing about VFS — the driver
    /// supplies panel state here.
    private func handleCommandBarLine(_ raw: String) {
        guard let pane = activePane else { return }
        switch CommandBarParser.parse(line: raw, context: commandBarContext(for: pane)) {
        case .empty:
            // Enter on the empty line behaves like Esc: back to the panel.
            activatePanelList()
        case let .invalid(message):
            commandBar.appendOutput(message, isError: true)
        case let .command(command):
            Task { await executeCommand(command, in: pane) }
        }
    }

    /// Placeholder context of the active panel (07 «Command bar»): cursor
    /// item, both directories, visible-order selection.
    private func commandBarContext(for pane: PanelViewController) -> CommandPlaceholderContext {
        let viewModel = pane.fileListView.viewModel
        let directory = viewModel.path ?? homePath
        let directoryText = posixPath(directory)
        let oppositeText = posixPath((oppositePane ?? pane).fileListView.viewModel.path ?? homePath)

        let selection = viewModel.effectiveSelection
        var selectedNames: [String] = []
        for index in 0 ..< viewModel.visibleCount {
            guard let item = viewModel.item(atVisibleIndex: index), selection.contains(item.id) else { continue }
            selectedNames.append(item.name)
        }
        let cursor = viewModel.item(atVisibleIndex: viewModel.cursor)
        return CommandPlaceholderContext(
            cursorName: cursor?.name,
            cursorPath: cursor.map { directoryText + "/" + $0.name },
            activeDirectory: directoryText,
            oppositeDirectory: oppositeText,
            selectionNames: selectedNames
        )
    }

    private func executeCommand(_ command: CommandBarCommand, in pane: PanelViewController) async {
        let viewModel = pane.fileListView.viewModel
        let vfs: any VFS = viewModel.source

        switch command {
        case let .cd(path):
            guard let target = await resolveEntry(path, current: viewModel.path ?? homePath, vfs: vfs, kind: .directory) else {
                commandBar.appendOutput(String(localized: "commandBar.error.pathNotFound \(path)"), isError: true)
                return
            }
            do {
                try await viewModel.openDirectory(at: target)
                commandBar.updatePrompt(displayPath: posixPath(viewModel.path ?? target))
            } catch let error as MCError {
                commandBar.appendOutput(error.localizedDescription, isError: true)
            } catch {
                commandBar.appendOutput(String(describing: error), isError: true)
            }
        case let .mkdir(name):
            let parts = commandPathComponents(name)
            guard parts.count == 1, !parts[0].isEmpty else {
                commandBar.appendOutput(String(localized: "commandBar.error.mkdirNesting \(name)"), isError: true)
                return
            }
            do {
                _ = try await vfs.createDirectory(parts[0], in: viewModel.path ?? homePath)
                await viewModel.reload()
            } catch let error as MCError {
                commandBar.appendOutput(error.localizedDescription, isError: true)
            } catch {
                commandBar.appendOutput(String(describing: error), isError: true)
            }
        case let .open(path):
            guard let target = await resolveEntry(path, current: viewModel.path ?? homePath, vfs: vfs, kind: nil) else {
                commandBar.appendOutput(String(localized: "commandBar.error.pathNotFound \(path)"), isError: true)
                return
            }
            if let item = try? await vfs.metadata(of: target), matchesKind(item.kind, .directory) {
                do { try await viewModel.openDirectory(at: target) } catch {
                    commandBar.appendOutput(String(describing: error), isError: true)
                }
                commandBar.updatePrompt(displayPath: posixPath(viewModel.path ?? target))
            } else if let local = vfs as? LocalVFS {
                NSWorkspace.shared.open(local.url(for: target))
            } else {
                commandBar.appendOutput(String(localized: "commandBar.error.shellLocalOnly"), isError: true)
            }
        case let .shell(command):
            guard let local = vfs as? LocalVFS else {
                commandBar.appendOutput(String(localized: "commandBar.error.shellLocalOnly"), isError: true)
                return
            }
            commandBar.appendOutput("$ \(command)")
            do {
                let outcome = try await ShellSession.exec(
                    command: command,
                    workingDirectory: local.url(for: viewModel.path ?? homePath)
                )
                if !outcome.standardOutput.isEmpty {
                    commandBar.appendOutput(outcome.standardOutput)
                }
                if !outcome.standardError.isEmpty {
                    commandBar.appendOutput(outcome.standardError, isError: true)
                }
                if outcome.exitCode != 0 {
                    commandBar.appendOutput(
                        String(localized: "commandBar.console.exitCode \(outcome.exitCode)"),
                        isError: true
                    )
                }
            } catch {
                commandBar.appendOutput(error.localizedDescription, isError: true)
            }
        }
    }

    /// `~`, absolute and panel-relative spellings (07 «Command bar»); one
    /// normalized candidate. `kind: nil` accepts any entry (open).
    private func resolveEntry(
        _ raw: String,
        current: VFSPath,
        vfs: any VFS,
        kind: VFSItemKind? = nil
    ) async -> VFSPath? {
        var components: [String]
        if raw == "~" || raw.hasPrefix("~/") {
            components = homePath.components
            if raw.count > 2 {
                components += commandPathComponents(String(raw.dropFirst(2)))
            }
        } else if raw.hasPrefix("/") {
            components = commandPathComponents(raw)
        } else {
            components = current.components + commandPathComponents(raw)
        }
        let candidate = VFSPath(root: vfs.id, components: components)
        guard let item = try? await vfs.metadata(of: candidate) else { return nil }
        guard kind == nil || matchesKind(item.kind, kind) else { return nil }
        return candidate
    }

    /// `VFSItemKind` carries an associated value (symlink target) and is not
    /// Equatable; symlinks pass for any wanted kind (native resolution).
    private func matchesKind(_ actual: VFSItemKind, _ wanted: VFSItemKind?) -> Bool {
        guard let wanted else { return true }
        switch (actual, wanted) {
        case (.directory, .directory), (.file, .file), (.special, .special):
            return true
        case (.symlink, _):
            return true
        default:
            return false
        }
    }

    private func commandPathComponents(_ raw: String) -> [String] {
        var result: [String] = []
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default:
                result.append(String(segment).precomposedStringWithCanonicalMapping)
            }
        }
        return result
    }

    private func posixPath(_ path: VFSPath) -> String {
        path.components.isEmpty ? "/" : "/" + path.components.joined(separator: "/")
    }

    /// Returns focus from the command bar to the active panel list.
    private func activatePanelList() {
        guard let pane = activePane ?? leftPane else { return }
        let table = pane.listTableView
        table.window?.makeFirstResponder(table)
    }

    // MARK: Info card (F-19 — T-15; 06 §6.11 v1)

    /// The card window is reusable (a second ⌃A rewrites the contents).
    private var infoWindow: InfoWindowController?

    /// ⌃A: the cursor item (not the selection — NC/TC semantics of the card).
    private func openItemInfo() {
        guard let pane = activePane else { return }
        let viewModel = pane.fileListView.viewModel
        guard let item = viewModel.item(atVisibleIndex: viewModel.cursor) else { return }
        let vfs: any VFS = viewModel.source

        if let window = infoWindow {
            window.reset(to: item)
            window.activate()
        } else {
            let controller = InfoWindowController(item: item)
            infoWindow = controller
            controller.activate()
        }

        // Recursive directory size — фоново (F-19 acceptance): the walk never
        // touches the UI thread, the finale replaces the «—» row afterwards.
        if case .directory = item.kind {
            let path = item.id
            Task { [weak self] in
                let sink: ProgressSink = { _ in }   // v1: renders the finale only
                var size: Int64?
                do {
                    size = try await vfs.directorySize(of: path, progress: sink)
                } catch {
                    return
                }
                guard let final = size, let self else { return }
                self.infoWindow?.update(size: final)
            }
        }
    }

    // MARK: View: Lister / editor / Quick Look (F-8, F-9 — T-13)

    /// The Lister window is reusable: a second F3 replaces its content.
    private var listerWindow: ListerWindowController?

    /// Selected file items of the active pane (visible order; directories
    /// never preview — F-8 lists files).
    private var selectedFileItems: [VFSItem] {
        guard let pane = activePane else { return [] }
        let viewModel = pane.fileListView.viewModel
        let selection = viewModel.effectiveSelection
        guard !selection.isEmpty else { return [] }
        var items: [VFSItem] = []
        for index in 0 ..< viewModel.visibleCount {
            guard let item = viewModel.item(atVisibleIndex: index),
                  selection.contains(item.id)
            else { continue }
            if case .directory = item.kind { continue }
            items.append(item)
        }
        return items
    }

    /// F3 (`.viewFile`): build the model from the streaming loader and show
    /// (or replace the content in) the Lister window.
    private func openLister() {
        guard let pane = activePane, let item = selectedFileItems.first else { return }
        let vfs = pane.fileListView.viewModel.source
        let path = item.id
        let name = item.name
        Task { [weak self] in
            guard let self, let source = await ListerLoader.open(path: path, in: vfs) else { return }
            // The image-URL provider fires only when the sniffed mode is image.
            let model = await ListerBootstrap.open(name: name, source: source) {
                await PreviewMaterializer.prepareFileURL(path: path, in: vfs)
            }
            if let window = listerWindow {
                window.reset(to: model)
                window.activate()
            } else {
                let controller = ListerWindowController(model: model)
                listerWindow = controller
                controller.activate()
            }
        }
    }

    /// F4 (`.editFile`): first selected file in the external editor
    /// (TextEdit by default); VFS objects go through a temp copy.
    private func editFirstInExternalEditor() {
        guard let pane = activePane, let item = selectedFileItems.first else { return }
        let vfs = pane.fileListView.viewModel.source
        let path = item.id
        Task {
            guard let url = await PreviewMaterializer.prepareFileURL(path: path, in: vfs) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// ⌘Y (`.quickLook`): native preview of selected files; multiple items
    /// enable the panel's own navigation (F-9 acceptance).
    private func quickLookSelection() {
        guard let pane = activePane else { return }
        let items = selectedFileItems
        guard !items.isEmpty else { return }
        let vfs = pane.fileListView.viewModel.source
        Task {
            var requests: [(url: URL, displayName: String)] = []
            for item in items.prefix(100) {
                if let url = await PreviewMaterializer.prepareFileURL(path: item.id, in: vfs) {
                    requests.append((url: url, displayName: item.name))
                }
            }
            QuickLookPresenter.show(urls: requests)
        }
    }

    private var oppositePane: PanelViewController? {
        focus.activePanel == .left ? rightPane : leftPane
    }

    /// Effective selection of the active pane as planned source paths (empty
    /// when there is nothing to operate on).
    private var selectedSources: [VFSPath] {
        guard let sourcePane = activePane else { return [] }
        let viewModel = sourcePane.fileListView.viewModel
        let selection = viewModel.effectiveSelection
        guard !selection.isEmpty else { return [] }
        let sources = (0 ..< viewModel.visibleCount)
            .compactMap { viewModel.item(atVisibleIndex: $0) }
            .filter { selection.contains($0.id) }
            .map(\.id)
        return sources
    }

    /// F-5: copy or move the effective selection of the active pane into the
    /// other pane's current directory; conflicts default to «keep both»
    /// (auto-suffix) until the T-12 conflict dialog lands.
    private func beginTransferToOppositePane(_ op: TransferOpKind) {
        guard let destinationPane = oppositePane,
              let target = destinationPane.fileListView.viewModel.path
        else { return }
        let viewModel = activePane?.fileListView.viewModel
        let sources = selectedSources
        guard !sources.isEmpty, let viewModel else { return }

        Task {
            do {
                let plan: TransferPlan
                switch op {
                case .move:
                    plan = try await TransferPlanner.planMove(
                        sources: sources,
                        into: target,
                        source: viewModel.source,
                        destination: destinationPane.fileListView.viewModel.source
                    )
                default:
                    plan = try await TransferPlanner.planCopy(
                        sources: sources,
                        into: target,
                        source: viewModel.source,
                        destination: destinationPane.fileListView.viewModel.source
                    )
                }
                guard !plan.items.isEmpty else { return }
                // T-12: planner-precomputed conflicts go through the dialog
                // (preview + per-item/all policy); cancel aborts the operation.
                var policy = ConflictPolicy(defaultResolution: .keepBoth)
                if !plan.conflicts.isEmpty {
                    let rows = await ConflictModels.preparePreviewRows(
                        plan.conflicts,
                        source: viewModel.source,
                        destination: destinationPane.fileListView.viewModel.source
                    )
                    guard let chosen = ConflictDialogController.run(rows: rows) else { return }
                    policy = chosen
                }
                let (id, stream) = await operationExecutor.enqueue(
                    plan,
                    policy: policy
                )
                showProgress(id: id, operation: stream, itemCount: plan.items.count)
            } catch let error as MCError {
                _ = error   // status-line surfacing arrives with T-12 UX pass
            } catch {
                _ = error
            }
        }
    }

    /// F-5: delete the selection. The executor defaults to the Trash (F-5
    /// «в корзину по умолчанию»); the permanent-delete path is a confirmation
    /// dialog away (T-12 UX pass).
    private func beginDeleteSelection() {
        let viewModel = activePane?.fileListView.viewModel
        let sources = selectedSources
        guard !sources.isEmpty, let viewModel else { return }

        Task {
            do {
                let plan = try await TransferPlanner.planDelete(sources: sources, source: viewModel.source)
                guard !plan.items.isEmpty else { return }
                let (id, stream) = await operationExecutor.enqueue(plan, policy: ConflictPolicy())
                showProgress(id: id, operation: stream, itemCount: plan.items.count)
            } catch let error as MCError {
                _ = error   // status-line surfacing arrives with T-12 UX pass
            } catch {
                _ = error
            }
        }
    }

    private func showProgress(id: OperationID, operation stream: AsyncStream<TransferEvent>, itemCount: Int) {
        let window = ProgressWindowController(
            id: id,
            events: stream,
            executor: operationExecutor,
            itemCount: itemCount
        )
        progressWindow = window
        window.window?.makeKeyAndOrderFront(nil)
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
