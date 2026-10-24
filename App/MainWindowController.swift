// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ListViewKit

/// Main window layout (docs/SDD/11: MainWindowController — layout окна,
/// геометрия, split). Geometry persists through AppKit autosave names:
/// "MCMainWindow" (window frame) and "MCMainSplit" (divider position).
@MainActor
final class MainWindowController: NSWindowController {
    private let splitView = NSSplitView()

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

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MCMainSplit"
        splitView.addArrangedSubview(coordinator.leftPane)
        splitView.addArrangedSubview(coordinator.rightPane)

        guard let contentView = window.contentView else { return }
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created programmatically only")
    }
}
