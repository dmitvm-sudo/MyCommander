// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ListViewKit

/// Main window layout (docs/SDD/11: MainWindowController — layout окна,
/// геометрия, split). Geometry persists through AppKit autosave names:
/// "MCMainWindow" (window frame) and "MCMainSplit" (divider position).
/// T-31 (F-17): between the panel split and the command bar sits the
/// terminal segment — height 0 until the first ⌃`, then 40% of the window
/// height (07 layout); the pane itself is spawned by PanelsCoordinator.
@MainActor
final class MainWindowController: NSWindowController {
    private let splitView = NSSplitView()
    /// T-31 (F-17): the bottom segment hosts the embedded terminal pane; the
    /// 0-vs-40% height is latched by `setTerminalShown`.
    private let terminalSegment = NSView()
    private var terminalZeroHeight: NSLayoutConstraint?
    private var terminalOpenHeight: NSLayoutConstraint?
    private weak var coordinator: PanelsCoordinator?

    init(coordinator: PanelsCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "window.title")
        _ = window.setFrameAutosaveName("MCMainWindow")    // geometry restore (docs/SDD/11)
        super.init(window: window)
        self.coordinator = coordinator

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MCMainSplit"
        splitView.addArrangedSubview(coordinator.leftPane.view)
        splitView.addArrangedSubview(coordinator.rightPane.view)

        guard let contentView = window.contentView else { return }
        // 07 §7.2: the command bar (⌘L) with its mini console sits below the
        // panel split — T-31 adds the terminal segment in between. The App
        // driver owns the panel state; the coordinator orchestrates
        // cd/mkdir/open/! and the terminal lifecycle.
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)
        let commandBar = coordinator.commandBar
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(commandBar)
        terminalSegment.translatesAutoresizingMaskIntoConstraints = false
        terminalSegment.isHidden = true
        contentView.addSubview(terminalSegment)

        let zero = terminalSegment.heightAnchor.constraint(equalToConstant: 0)
        let open = terminalSegment.heightAnchor.constraint(
            equalTo: contentView.heightAnchor, multiplier: 0.4
        )
        terminalZeroHeight = zero
        terminalOpenHeight = open

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: terminalSegment.topAnchor, constant: -4),
            terminalSegment.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            terminalSegment.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalSegment.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -4),
            zero,

            commandBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // T-31 wiring (06 §6.8): the coordinator spawns TerminalPane here at
        // the first ⌃` and reports visibility; this controller latches the
        // segment height (0 → 40% of the window).
        coordinator.terminalSegment = terminalSegment
        coordinator.onTerminalVisibilityChange = { [weak self] shown in
            self?.setTerminalShown(shown)
        }

        // T-31: the shell child dies with the window (v1, no confirmation).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidCloseNotification(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func setTerminalShown(_ shown: Bool) {
        guard let terminalZeroHeight, let terminalOpenHeight else { return }
        terminalZeroHeight.isActive = !shown
        terminalOpenHeight.isActive = shown
        terminalSegment.isHidden = !shown
    }

    @objc private func windowDidCloseNotification(_ notification: Notification) {
        coordinator?.shutdownTerminal()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created programmatically only")
    }
}
