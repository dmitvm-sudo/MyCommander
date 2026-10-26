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
    /// F-21 MVP (T-18): the settings store; consumers apply changes live.
    let settingsStore = SettingsStore()
    private var settingsWindow: SettingsWindowController?
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
    /// F-12 (T-21): archive mounts («архивы как папки») — idempotent identifiers,
    /// FIFO eviction (§6.4), per-mount extract cache under `…/extract/`.
    private let archiveRegistry = VFSRegistry()
    /// Session persistence (F-2: tabs survive relaunch).
    private let sessionStore: SessionStore
    /// F-13 (T-24): connections CRUD + Keychain secrets + host-key pins.
    let connectionStore = ConnectionStore()
    private var connectionsWindow: ConnectionsWindowController?
    /// F-11 (T-26): bookmarks, hotlist slots, recent folders.
    let locationsStore = LocationsStore()
    private var locationsWindow: LocationsWindowController?

    /// Operations engine (F-5, T-10): one executor for the shared local VFS;
    /// per-adapter executors arrive with the VFSRegistry task.
    private let transferJournal = JournalStorage()
    private let transferEvents = TransferEvents()
    private var operationExecutor: OperationExecutor!
    private var progressWindow: ProgressWindowController?

    private var homePath: VFSPath {
        VFSPath.local(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// F-20 (T-17): the initial launch seeds the panels in a TCC-granted
    /// zone under Safe Mode instead of the (possibly guarded) home root.
    private var initialSeedPath: VFSPath {
        let mode = AccessProbe.classify(AccessProbe.probe())
        if case let .safe(knownZones) = mode, let zone = knownZones.first {
            let zoneURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(zone.rawValue, isDirectory: true)
            return VFSPath.local(zoneURL)
        }
        return homePath
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
            leftTabList = makeTabList(for: .left)
            leftTabList.seed(with: initialSeedPath)
            rightTabList = makeTabList(for: .right)
            rightTabList.seed(with: initialSeedPath)
        }
        // T-26 (F-11): every displayed location lands in «recent folders».
        leftTabList.onPathVisited = { [weak self] path in
            self?.locationsStore.noteVisit(path)
        }
        rightTabList.onPathVisited = { [weak self] path in
            self?.locationsStore.noteVisit(path)
        }

        leftPane = PanelViewController(tabList: leftTabList)
        rightPane = PanelViewController(tabList: rightTabList)
        leftPane.fileListView.onActivated = { [weak self] in self?.focus.activate(.left) }
        rightPane.fileListView.onActivated = { [weak self] in self?.focus.activate(.right) }
        wireDragEngines()
        focus.onFocusChanged = { [weak self] side in self?.applyFocus(side) }

        operationExecutor = OperationExecutor(
            source: fileSystem,
            destination: fileSystem,
            journal: transferJournal,
            events: transferEvents
        )
        registerCommandHandlers()
        wireCommandBar()
        wireSettingsConsumers()
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

    /// F-18 wiring (T-16 / §6.1 v1): both panels drag their rows out through
    /// the App-built pasteboard items and accept drops onto the whole panel.
    private func wireDragEngines() {
        wireDragEngine(for: leftPane)
        wireDragEngine(for: rightPane)
    }

    private func wireDragEngine(for pane: PanelViewController) {
        pane.fileListView.onPasteboardWriterForRow = { [weak self] row in
            self?.dragItem(atRow: row, in: pane)
        }
        pane.fileListView.onDropReceived = { [weak self] urls, paths, isInternal, wantsCopy in
            self?.acceptDrop(
                urls: urls,
                paths: paths,
                isInternal: isInternal,
                wantsCopy: wantsCopy,
                into: pane
            )
        }
    }

    /// One dragged row → pasteboard item (LocalVFS rows only: the v1 scope
    /// keeps network/archive sources inert).
    private func dragItem(atRow row: Int, in pane: PanelViewController) -> NSPasteboardItem? {
        let viewModel = pane.fileListView.viewModel
        guard let item = viewModel.item(atVisibleIndex: row),
              let local = viewModel.source as? LocalVFS
        else { return nil }
        return DragBridge.entry(fileURL: local.url(for: item.id), path: item.id)
    }

    /// The whole pane is the drop target (F-18 «домашняя панель — дефолт-цель»):
    /// Finder files copy, another panel moves by default (⌥ copies).
    private func acceptDrop(
        urls: [URL],
        paths: [VFSPath],
        isInternal: Bool,
        wantsCopy: Bool,
        into pane: PanelViewController
    ) {
        guard pane.fileListView.viewModel.path != nil else { return }
        let op: TransferOpKind = (isInternal && !wantsCopy) ? .move : .copy

        let sources: [VFSPath]
        if !paths.isEmpty {
            sources = paths
        } else {
            // Finder brings raw local URLs; re-anchor to this app's single
            // LocalVFS coordinate space (§5.1 displayURL keeps the intent).
            sources = urls.map { localPath(from: $0) }
        }
        guard !sources.isEmpty else { return }
        guard sources.allSatisfy({ $0.root == fileSystem.id }) else {
            // v1 drag-out scope: non-local sources never accepted honestly.
            commandBar.appendOutput(
                String(localized: "drop.error.unsupportedSource"),
                isError: true
            )
            return
        }
        Task { await executeTransfer(op, sources: sources, source: fileSystem, destinationPane: pane) }
    }

    /// Finder URL → the app's LocalVFS path space (root stays the running
    /// instance so `LocalVFS.url(for:)` precondition holds).
    private func localPath(from url: URL) -> VFSPath {
        VFSPath(
            root: fileSystem.id,
            components: VFSPath.normalizedComponents(from: url),
            displayURL: url
        )
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

    private func makeTabList(for side: FocusController.PanelSide) -> PanelTabList {
        PanelTabList(
            makeViewModel: { [weak self, fileSystem, watcher] in
                let viewModel = PanelViewModel(source: fileSystem)
                viewModel.watchEngine = watcher
                self?.wireArchiveEnter(viewModel, side: side)   // 06 §6.1 T-21: every VM
                return viewModel
            },
            watchEngine: watcher
        )
    }

    /// «Общий» hook-сет для вкладок (06 §6.1 T-21): Enter на файле-архиве —
    /// смонтировать и подсадить во вкладку; для не-архивов — прежнее поведение.
    private func wireArchiveEnter(_ viewModel: PanelViewModel, side: FocusController.PanelSide) {
        viewModel.openEntryHandler = { [weak self, side] item in
            guard let self else { return false }
            return await self.openEntryAsArchive(item, side: side)
        }
    }

    /// F-12 (T-21): Enter на архиве — mount в реестре → interlude-VM поверх
    /// активной вкладки (swap; id/lock сохраняются). `false` для не-архивов.
    private func openEntryAsArchive(_ item: VFSItem, side: FocusController.PanelSide) async -> Bool {
        guard item.id.root.kind == .localDisk, let url = item.id.displayURL else { return false }
        guard let archive = try? await archiveRegistry.mountArchive(reading: url) else { return false }
        guard let pane = side == .left ? leftPane : rightPane else { return false }
        guard let host = pane.tabList.activeTab?.viewModel else { return false }
        let interlude = PanelViewModel(source: archive)
        interlude.watchEngine = watcher   // canWatch = false: «мёртвый» пустой поток (§5.4)
        wireArchiveEnter(interlude, side: side)
        interlude.onRootExit = { [weak self, weak interlude, side, host] in
            guard let self, let interlude else { return }
            self.exitArchiveInterlude(interlude, host: host, side: side)
        }
        // Root listing carries the host file URL for the tab title / QL export.
        do {
            try await interlude.openDirectory(at: VFSPath(root: archive.id, displayURL: url))
        } catch {
            return false
        }
        pane.swapActiveTabViewModel(interlude)
        return true
    }

    /// ⌘↑ at the archive root — rebind «назад» на хост-VM панели (06 §6.1 T-21).
    private func exitArchiveInterlude(
        _ interlude: PanelViewModel, host: PanelViewModel, side: FocusController.PanelSide
    ) {
        guard let pane = side == .left ? leftPane : rightPane else { return }
        guard pane.fileListView.viewModel === interlude else { return }   // interlude already exited
        _ = pane.swapActiveTabViewModel(host)
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
        leftTabList = makeTabList(for: .left)
        rightTabList = makeTabList(for: .right)
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
        // T-26 (F-11): per-tab history commands (mechanism — T-08).
        router.register(.navigateBack) { [weak self] in
            guard let pane = self?.activePane else { return }
            _ = pane.tabList.navigateBack()
        }
        router.register(.navigateForward) { [weak self] in
            guard let pane = self?.activePane else { return }
            _ = pane.tabList.navigateForward()
        }
        // T-26 (F-11): bookmarks / hotlist / the Locations window.
        router.register(.bookmarkAdd) { [weak self] in
            self?.addBookmarkFromActivePanel()
        }
        router.register(.openLocations) { [weak self] in
            self?.openLocationsWindow()
        }
        let hotSlots: [(CommandID, Int)] = [
            (.hotSlot1, 1), (.hotSlot2, 2), (.hotSlot3, 3),
            (.hotSlot4, 4), (.hotSlot5, 5), (.hotSlot6, 6),
            (.hotSlot7, 7), (.hotSlot8, 8), (.hotSlot9, 9),
        ]
        for (command, slot) in hotSlots {
            router.register(command) { [weak self] in
                self?.navigateHotSlot(slot)
            }
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
        // F-12 (T-22): pack the selection into ONE zip in the opposite panel.
        router.register(.packFiles) { [weak self] in
            self?.beginPackSelection()
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

        // F-14 (T-28): multi-rename over the effective selection of the
        // active panel; the dialog builds ONE .move plan (undo rides F-6).
        router.register(.multiRename) { [weak self] in
            self?.beginMultiRename()
        }

        // F-6 (T-20): ⌘Z — undo the newest journal record through the same
        // planner/conflicts/executor path as forward operations.
        router.register(.undo) { [weak self] in
            self?.undoLastJournalRecord()
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
                let directory = try await vfs.createDirectory(parts[0], in: viewModel.path ?? homePath)
                // F-6 (T-20): mkdir never routes through the transfer engine —
                // the App journals its own committed createDirectory here
                // (05 §5.6: the mkdir reversal is `deleteCreated`).
                transferJournal.append(JournalRecord(
                    timestamp: Date(),
                    op: .mkdir,
                    reversals: [.deleteCreated(path: directory)]
                ))
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

    // MARK: Settings (F-21 MVP — T-18; 06 §6.9 v1)

    /// Live application (§6.9 «DidUpdate»): the panel font re-applies to
    /// both panels; delete-confirm and the editor read the store on demand.
    private func wireSettingsConsumers() {
        settingsStore.onDidUpdate = { [weak self] schema in
            self?.applyPanelSetting(schema)
        }
        applyPanelSetting(settingsStore.settings)
        // F-21: ⌘, opens the (reusable) settings window.
        router.register(.openSettings) { [weak self] in
            self?.openSettingsWindow()
        }
        // F-13 (T-24): the reusable Connections window.
        router.register(.connectSftp) { [weak self] in
            self?.openConnectionsWindow()
        }
    }

    private func openConnectionsWindow() {
        if let window = connectionsWindow {
            window.activate()
        } else {
            let controller = ConnectionsWindowController(store: connectionStore)
            controller.onConnect = { [weak self] record in
                self?.connectSftp(record)
            }
            connectionsWindow = controller
            controller.activate()
        }
    }

    // MARK: Locations (F-11 — T-26; 06 §6.9)

    /// ⌘D: bookmarks the active panel's current directory (no hot slot).
    private func addBookmarkFromActivePanel() {
        guard let path = activePane?.fileListView.viewModel.path else { return }
        let name = path.components.last ?? String(localized: "locations.untitledRoot")
        locationsStore.addBookmark(name: name, target: .path(path))
        rebuildMenu()
    }

    private func openLocationsWindow() {
        if let window = locationsWindow {
            window.activate()
        } else {
            let controller = LocationsWindowController(store: locationsStore)
            controller.onNavigate = { [weak self] target in
                self?.navigate(target: target)
            }
            controller.onChanged = { [weak self] in
                self?.rebuildMenu()
            }
            locationsWindow = controller
            controller.activate()
        }
    }

    /// Hotlist slot: the bookmark's `panelHint` panel (двойная адресация) or
    /// the active one; `.connection` targets open through the SFTP flow.
    private func navigateHotSlot(_ slot: Int) {
        guard let bookmark = locationsStore.hotSlot(slot) else { return }
        navigate(target: bookmark.target, hint: bookmark.panelHint)
    }

    private func navigate(target: LocationTarget, hint: LocationSide? = nil) {
        let pane: PanelViewController?
        switch hint {
        case .left: pane = leftPane
        case .right: pane = rightPane
        case nil: pane = activePane ?? leftPane
        }
        guard let pane else { return }
        switch target {
        case .path(let path):
            Task { try? await pane.fileListView.viewModel.openDirectory(at: path) }
        case .connection(let id):
            guard let record = connectionStore.record(id: id) else { return }
            connectSftp(record)
        }
    }

    /// T-26: the Locations section carries live slot names — rebuild after
    /// bookmark changes (menu built once at launch otherwise).
    func rebuildMenu() {
        NSApp.mainMenu = MenuBuilder.build(router: router, keymap: keymapStore, locations: locationsStore)
    }

    // MARK: SFTP connect (F-13, T-24; 06 §6.5/§6.9)

    /// Opens a Connections-window record as an SFTP panel: connection →
    /// SftpVFS → registry → interlude-VM on the active tab (the T-21 swap
    /// pattern; ⌘↑ exits back to the host listing).
    private func connectSftp(_ record: ConnectionRecord) {
        Task { await performConnectSftp(record) }
    }

    private func performConnectSftp(_ record: ConnectionRecord) async {
        do {
            let auth = try sftpAuthMethod(for: record)
            let policy = HostKeyPolicy(pinnedFingerprint: record.hostKeyFingerprint)
            policy.decisionHandler = { [weak self] event in
                await self?.hostKeyDecision(event, record: record) ?? false
            }
            let config = SftpConnectionConfig(
                host: record.host,
                port: record.port,
                username: record.username,
                auth: auth,
                hostKeyValidator: .custom(policy)
            )
            let connection = try await SftpConnection(config: config)
            let vfs = SftpVFS(connection: connection)
            await archiveRegistry.register(vfs)

            guard let pane = activePane ?? leftPane else { return }
            guard let host = pane.tabList.activeTab?.viewModel else { return }
            let side: FocusController.PanelSide = pane === leftPane ? .left : .right
            let viewModel = PanelViewModel(source: vfs)
            wireArchiveEnter(viewModel, side: side)
            // T-25 (06 §6.5): supervisor states drive the status line
            // («Reconnect…») and the post-reconnect reload — SFTP has no
            // watch channel (05 §5.4), so the state callback IS the refresh.
            connection.setOnStateChange { [weak self, weak viewModel] state in
                Task { @MainActor in
                    self?.handleSftpState(state, viewModel: viewModel)
                }
            }
            viewModel.onRootExit = { [weak pane, weak host, weak viewModel] in
                guard let pane, let host, let viewModel else { return }
                guard pane.fileListView.viewModel === viewModel else { return }
                _ = pane.swapActiveTabViewModel(host)
            }
            try await viewModel.openDirectory(at: VFSPath(root: vfs.id))
            pane.swapActiveTabViewModel(viewModel)
        } catch let error as MCError {
            presentConnectionFailure(error, record: record)
        } catch {
            presentConnectionFailure(.unexpected(underlying: error), record: record)
        }
    }

    /// T-25: SFTP supervisor states → panel surface (06 §6.5 уточнение T-25).
    private func handleSftpState(_ state: SftpConnectionState, viewModel: PanelViewModel?) {
        guard let viewModel else { return }
        switch state {
        case .connected:
            Task { await viewModel.reload() }
        case .reconnecting(let attempt, _):
            viewModel.onError?(.interrupted(reason: "reconnecting (attempt \(attempt))…"))
        case .failed:
            viewModel.onError?(.interrupted(reason: "connection lost — reconnect failed"))
        }
    }

    /// Auth material for the connection (06 §6.5): the password rides from the
    /// Keychain; Ed25519 keys come from the OpenSSH container file (v1:
    /// unencrypted; 06 §6.5 уточнение T-24).
    private func sftpAuthMethod(for record: ConnectionRecord) throws -> SftpAuthMethod {
        switch record.auth {
        case .password:
            guard let secret = connectionStore.password(for: record.id), !secret.isEmpty else {
                throw MCError.vfsUnsupported(
                    VFSInstanceID(kind: .sftp, specID: record.host),
                    "no password stored for this connection"
                )
            }
            return .password(secret)
        case .privateKey(let path, _):
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let key = try SftpPrivateKey.ed25519(fromOpenSSH: content)
            return .ed25519(privateKey: key)
        }
    }

    /// Host-key decisions (F-13): first use — the regular trust dialog;
    /// fingerprint change — the critical MITM red screen. Accepting a first
    /// use or a changed key PINS the fingerprint in the store.
    private func hostKeyDecision(_ event: HostKeyEvent, record: ConnectionRecord) async -> Bool {
        switch event {
        case .firstUse(let fingerprint):
            let alert = NSAlert()
            alert.messageText = String(localized: "connections.hostkey.firstUse.title")
            alert.informativeText = String(
                localized: "connections.hostkey.firstUse.\(record.host)\(fingerprint)"
            )
            alert.addButton(withTitle: String(localized: "connections.hostkey.trust"))
            alert.addButton(withTitle: String(localized: "connections.hostkey.abort"))
            let trusted = alert.runModal() == .alertFirstButtonReturn
            if trusted {
                connectionStore.pinHostKey(id: record.id, fingerprint: fingerprint)
            }
            return trusted
        case .changed(let pinned, let presented):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "connections.hostkey.changed.title")
            alert.informativeText = String(
                localized: "connections.hostkey.changed.\(record.host)\(pinned)\(presented)"
            )
            alert.addButton(withTitle: String(localized: "connections.hostkey.abort"))
            alert.addButton(withTitle: String(localized: "connections.hostkey.retrust"))
            let reTrust = alert.runModal() == .alertSecondButtonReturn
            if reTrust {
                connectionStore.pinHostKey(id: record.id, fingerprint: presented)
            }
            return reTrust
        }
    }

    private func presentConnectionFailure(_ error: MCError, record: ConnectionRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "connections.failure.title")
        alert.informativeText = "\(record.name): \(error.errorDescription ?? String(describing: error))"
        alert.runModal()
    }

    private func openSettingsWindow() {
        if let window = settingsWindow {
            window.activate()
        } else {
            let controller = SettingsWindowController(store: settingsStore)
            settingsWindow = controller
            controller.activate()
        }
    }

    /// NSFont construction belongs to App (ServicesKit stays AppKit-free).
    private func applyPanelSetting(_ schema: SettingsSchema) {
        let font = NSFont.wrappedPanelFont(from: schema)
        leftPane?.fileListView.applyPanelFont(font)
        rightPane?.fileListView.applyPanelFont(font)
    }

    // MARK: Access mode (F-20 — T-17; 06 §6.10 v1)
    /// The badge rides both panels' status lines; the seed re-target happens
    /// only for a fresh session (T-17: initial launch without a session).
    func applyAccessMode(_ mode: AccessMode, grantedZones: [AccessZone]) {
        let badge: String?
        switch mode {
        case .full:
            badge = String(localized: "access.badge.full")
        case .safe:
            let zoneText = grantedZones.map(\.rawValue).joined(separator: ", ")
            badge = String(localized: "access.badge.safe \(zoneText)")
        case .restricted:
            badge = String(localized: "access.badge.restricted")
        }
        leftPane.fileListView.accessBadge = badge
        rightPane.fileListView.accessBadge = badge
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
            // F-4 / F-21 MVP (§6.9 v1): a configured editor wins; an empty
            // path or a missing/non-executable one stays on the system
            // default app. Bundles (.app) open as-is, binaries through the
            // same launch API.
            let editorPath = settingsStore.settings.textEditorPath
            if !editorPath.isEmpty,
               editorPath.hasSuffix(".app") || FileManager.default.isExecutableFile(atPath: editorPath) {
                try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: URL(fileURLWithPath: editorPath),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                NSWorkspace.shared.open(url)
            }
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
              let viewModel = activePane?.fileListView.viewModel
        else { return }
        let sources = selectedSources
        guard !sources.isEmpty else { return }
        Task { await executeTransfer(op, sources: sources, source: viewModel.source, destinationPane: destinationPane) }
    }

    /// Shared execution path for F5/F6 and the DnD drops (§6.1 v1, T-16):
    /// plan → planner-precomputed conflicts dialog (preview + per-item/all
    /// policy) → enqueue → progress window. Cancel aborts the operation.
    private func executeTransfer(
        _ op: TransferOpKind,
        sources: [VFSPath],
        source: any VFS,
        destinationPane: PanelViewController
    ) async {
        guard let target = destinationPane.fileListView.viewModel.path else { return }
        let destination = destinationPane.fileListView.viewModel.source
        do {
            let plan: TransferPlan
            switch op {
            case .move:
                plan = try await TransferPlanner.planMove(
                    sources: sources,
                    into: target,
                    source: source,
                    destination: destination
                )
            default:
                plan = try await TransferPlanner.planCopy(
                    sources: sources,
                    into: target,
                    source: source,
                    destination: destination
                )
            }
            guard !plan.items.isEmpty else { return }
            var policy = ConflictPolicy(defaultResolution: .keepBoth)
            if !plan.conflicts.isEmpty {
                let rows = await ConflictModels.preparePreviewRows(
                    plan.conflicts,
                    source: source,
                    destination: destination
                )
                guard let chosen = ConflictDialogController.run(rows: rows) else { return }
                policy = chosen
            }
            // T-27 (unified queue): the operation rides the ONE executor with
            // ITS OWN VFS pair (05 §5.6 уточнение T-27) — archive/SFTP panels
            // included.
            let (id, stream) = await operationExecutor.enqueue(
                plan,
                policy: policy,
                source: source,
                destination: destination
            )
            showProgress(id: id, operation: stream, itemCount: plan.items.count)
        } catch let error as MCError {
            _ = error   // status-line surfacing arrives with T-12 UX pass
        } catch {
            _ = error
        }
    }

    /// F-12 (T-22): pack the effective selection of the ACTIVE pane into ONE
    /// zip (Pack dialog: name + compression method). The zip lands in the
    /// opposite pane's current directory (v1 destination is fixed — 02 F-12);
    /// a queued `.packZip` plan runs through the same progress window.
    private func beginPackSelection() {
        guard let destinationPane = oppositePane, let sourcePane = activePane else { return }
        let viewModel = sourcePane.fileListView.viewModel
        let sources = selectedSources
        guard !sources.isEmpty else { return }
        guard let target = destinationPane.fileListView.viewModel.path else { return }
        let destination = destinationPane.fileListView.viewModel.source
        // v1 honest limit (06 §6.2 T-22): the zip is published locally.
        guard destination is LocalVFS else {
            let alert = NSAlert()
            alert.messageText = String(localized: "pack.onlyLocalDestination")
            alert.alertStyle = .warning
            _ = alert.runModal()
            return
        }
        let defaultName: String
        if sources.count == 1, let single = sources.first?.components.last, !single.isEmpty {
            defaultName = single + ".zip"
        } else {
            defaultName = String(localized: "pack.defaultName")
        }
        guard let choice = PackDialog.run(defaultName: defaultName) else { return }
        let zipName = choice.name.hasSuffix(".zip") ? choice.name : choice.name + ".zip"
        let compression = choice.compression
        let source = viewModel.source
        Task { await executePack(
            sources: sources,
            from: source,
            into: target,
            zipName: zipName,
            compression: compression,
            destination: destination
        ) }
    }

    /// Shared pack execution: plan → conflict dialog (the shared zip target)
    /// → enqueue → progress window (06 §6.2 T-22).
    private func executePack(
        sources: [VFSPath],
        from source: any VFS,
        into target: VFSPath,
        zipName: String,
        compression: ZipPackCompression,
        destination: any VFS
    ) async {
        do {
            let plan = try await ZipPackPlanner.planPack(
                sources: sources,
                into: target,
                zipName: zipName,
                source: source,
                destination: destination,
                compression: compression
            )
            guard !plan.items.isEmpty else { return }
            var policy = ConflictPolicy(defaultResolution: .keepBoth)
            if !plan.conflicts.isEmpty {
                let rows = await ConflictModels.preparePreviewRows(
                    plan.conflicts,
                    source: source,
                    destination: destination
                )
                guard let chosen = ConflictDialogController.run(rows: rows) else { return }
                policy = chosen
            }
            let (id, stream) = await operationExecutor.enqueue(plan, policy: policy)
            showProgress(id: id, operation: stream, itemCount: plan.items.count)
        } catch let error as MCError {
            _ = error   // status-line surfacing arrives with T-12 UX pass
        } catch {
            _ = error
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
            // F-21 / 07 §7.3: confirmation at ≥ N items (T-18 settings).
            let schema = settingsStore.settings
            if schema.confirmDelete, sources.count >= max(1, schema.deleteConfirmThreshold) {
                let alert = NSAlert()
                alert.messageText = String(localized: "settings.deletion.confirm.message \(sources.count)")
                alert.addButton(withTitle: String(localized: "settings.deletion.confirm.ok"))
                alert.addButton(withTitle: String(localized: "settings.deletion.confirm.cancel"))
                alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            do {
                let plan = try await TransferPlanner.planDelete(sources: sources, source: viewModel.source)
                guard !plan.items.isEmpty else { return }
                // T-27: delete rides the unified queue with the panel's VFS.
                let (id, stream) = await operationExecutor.enqueue(
                    plan,
                    policy: ConflictPolicy(),
                    source: viewModel.source,
                    destination: viewModel.source
                )
                showProgress(id: id, operation: stream, itemCount: plan.items.count)
            } catch let error as MCError {
                _ = error   // status-line surfacing arrives with T-12 UX pass
            } catch {
                _ = error
            }
        }
    }

    /// F-6 (T-20): ⌘Z — undo the newest journaled change. The record is popped
    /// BEFORE the reverse plan runs; a plan that cannot be built re-appends the
    /// record and reports «undo недоступен» (05 §5.6 уточнение T-20). Cancelling
    /// the conflicts dialog leaves the record popped — lossy undo v1.
    private func undoLastJournalRecord() {
        Task {
            guard let record = transferJournal.popLast() else {
                presentUndoUnavailable()
                return
            }
            guard let plan = await UndoPlanner.plan(record: record, source: fileSystem, destination: fileSystem) else {
                transferJournal.append(record)
                presentUndoUnavailable()
                return
            }
            var policy = ConflictPolicy()
            if !plan.conflicts.isEmpty {
                let rows = await ConflictModels.preparePreviewRows(
                    plan.conflicts,
                    source: fileSystem,
                    destination: fileSystem
                )
                guard let chosen = ConflictDialogController.run(rows: rows) else { return }
                policy = chosen
            }
            let (id, stream) = await operationExecutor.enqueue(plan, policy: policy)
            showProgress(id: id, operation: stream, itemCount: plan.items.count)
        }
    }

    /// F-14 (T-28): multi-rename over the effective selection. The dialog is
    /// the dry run (live preview, conflicts red, Apply disabled while
    /// invalid); Apply builds ONE `.move` plan executed through the unified
    /// queue with the PANEL's VFS pair (05 §5.6 уточнение T-27). The stream is
    /// consumed here and the panel reloads on finish (SFTP has no watch).
    private func beginMultiRename() {
        guard let pane = activePane else { return }
        let viewModel = pane.fileListView.viewModel
        let selection = viewModel.effectiveSelection
        guard !selection.isEmpty else { return }
        let items = (0 ..< viewModel.visibleCount).compactMap { viewModel.item(atVisibleIndex: $0) }
            .filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        let occupied = Set(viewModel.rawItems.map(\.name))
        let panelVFS = viewModel.source

        guard let plan = MultiRenameDialog.run(items: items, occupiedNames: occupied) else { return }
        Task { [weak self] in
            guard let self else { return }
            let (id, stream) = await self.operationExecutor.enqueue(
                plan,
                policy: ConflictPolicy(defaultResolution: .skip),
                source: panelVFS,
                destination: panelVFS
            )
            _ = id
            for await _ in stream {}
            await viewModel.reload()
        }
    }

    private func presentUndoUnavailable() {
        let alert = NSAlert()
        alert.messageText = String(localized: "undo.unavailable")
        alert.alertStyle = .informational
        _ = alert.runModal()
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
