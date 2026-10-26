// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftTerm

// Contract: docs/SDD/06 §6.8 «Уточнение T-31» (F-17) — the embedded terminal
// pane hosts SwiftTerm's `LocalProcessTerminalView` running a login zsh. The
// App layer (PanelsCoordinator) creates it by demand at the first ⌃` and pins
// it into the bottom 40% window segment; the shell child survives hiding and
// is killed with the window (v1, no confirmation). Panel paths enter the PTY
// only through `TerminalPathSeeder` (pure, unit-tested); selection, copy/paste
// and link-follow come from SwiftTerm as-is.

@MainActor
public final class TerminalPane: NSView {
    /// The PTY host; the child shell starts at the first window attach, when
    /// the real geometry (and winsize) exists. SwiftTerm re-syncs the PTY size
    /// itself on every view resize.
    private let processView = LocalProcessTerminalView(frame: .zero)
    private var shellStarted = false
    /// The shell's seed directory, updated by every auto-CD; the manual
    /// buttons reuse it while the terminal is hidden or just opened.
    private var shellDirectory: String

    // Header strip: re-cd to the panel directory / paste it as a path.
    private let cdButton = NSButton(
        title: String(localized: "terminal.cdToDirectory"), target: nil, action: nil
    )
    private let insertButton = NSButton(
        title: String(localized: "terminal.insertPanelPath"), target: nil, action: nil
    )
    private let directoryLabel = NSTextField(labelWithString: "")

    public init(initialDirectory: String) {
        self.shellDirectory = initialDirectory
        super.init(frame: .zero)
        directoryLabel.stringValue = initialDirectory
        directoryLabel.lineBreakMode = .byTruncatingHead
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cdButton.target = self
        cdButton.action = #selector(cdToPanelDirectory)
        cdButton.controlSize = .small
        insertButton.target = self
        insertButton.action = #selector(insertPanelDirectory)
        insertButton.controlSize = .small

        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalPane is created programmatically only")
    }

    private func buildLayout() {
        let strip = NSStackView(views: [cdButton, insertButton, directoryLabel])
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        addSubview(strip)
        addSubview(processView)
        for subview in [strip, processView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 26),

            processView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            processView.leadingAnchor.constraint(equalTo: leadingAnchor),
            processView.trailingAnchor.constraint(equalTo: trailingAnchor),
            processView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startShellIfNeeded()
    }

    /// The login zsh (`zsh -l`) starts exactly once, at the first window
    /// attach; `currentDirectory` seeds the child inside the panel directory
    /// (06 §6.8) so no welcome cd is needed.
    private func startShellIfNeeded() {
        guard window != nil, !shellStarted else { return }
        shellStarted = true
        processView.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: nil,
            execName: nil,
            currentDirectory: shellDirectory
        )
    }

    // MARK: seeding (the PTY receives only TerminalPathSeeder output)

    /// Auto-CD (06 §6.8): `cd -- '…'` typed into the child shell. The App
    /// layer debounces; the pane just forwards and mirrors the directory.
    public func cdTo(path posix: String) {
        shellDirectory = posix
        directoryLabel.stringValue = posix
        processView.send(txt: TerminalPathSeeder.cdTo(URL(fileURLWithPath: posix)))
    }

    /// ⌃⇧V: the quoted path lands on the command line without a newline —
    /// the command stays open for editing (06 §6.8 `insertSequence`).
    public func insert(path posix: String) {
        processView.send(txt: TerminalPathSeeder.insertSequence(URL(fileURLWithPath: posix)))
    }

    /// Focus ownership (07 §7.2 lists `terminal` as its own focus target).
    public func focusInput() {
        window?.makeFirstResponder(processView)
    }

    /// Window teardown (PanelsCoordinator.shutdownTerminal); v1 kills the
    /// child without a confirmation dialog.
    public func terminateShell() {
        processView.terminate()
    }

    @objc private func cdToPanelDirectory() {
        cdTo(path: shellDirectory)
    }

    @objc private func insertPanelDirectory() {
        insert(path: shellDirectory)
    }
}
