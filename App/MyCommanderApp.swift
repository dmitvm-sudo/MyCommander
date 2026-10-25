// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import FileOpsKit
import Foundation

/// Application lifecycle (docs/SDD/11: MyCommanderApp.swift — entry, lifecycle).
/// Business logic never lives here; it owns only the app assembly
/// (coordinator + main menu + main window) and forwards UI events.
@MainActor
final class MyCommanderApp: NSObject, NSApplicationDelegate {
    private var coordinator: PanelsCoordinator?
    private var mainWindow: MainWindowController?
    private var onboardingFlow: OnboardingFlow?

    func run() {
        let application = NSApplication.shared
        application.delegate = self
        application.setActivationPolicy(.regular)

        let coordinator = PanelsCoordinator()
        self.coordinator = coordinator
        // T-09: the menu reflects the active keymap profile (§6.10).
        application.mainMenu = MenuBuilder.build(
            router: coordinator.router,
            keymap: coordinator.keymapStore,
            locations: coordinator.locationsStore
        )

        let mainWindow = MainWindowController(coordinator: coordinator)
        self.mainWindow = mainWindow
        mainWindow.window?.makeKeyAndOrderFront(nil)

        // F-20 (T-17): the FDA probe rides app activation; the offer window
        // opens only for an undecided onboarding state (max 2 runs).
        let flow = OnboardingFlow(coordinator: coordinator)
        self.onboardingFlow = flow
        flow.begin()

        Task { await coordinator.start() }

        application.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// F-2: the tab stacks survive relaunch — persist on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.saveSession()
        PreviewMaterializer.purgeTempCopies()
    }
}
