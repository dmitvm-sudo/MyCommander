// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import FileOpsKit
import Foundation
import ServicesKit

/// Application lifecycle (docs/SDD/11: MyCommanderApp.swift — entry, lifecycle).
/// Business logic never lives here; it owns only the app assembly
/// (coordinator + main menu + main window) and forwards UI events.
@MainActor
final class MyCommanderApp: NSObject, NSApplicationDelegate {
    private var coordinator: PanelsCoordinator?
    private var mainWindow: MainWindowController?
    private var onboardingFlow: OnboardingFlow?
    private var updater: UpdaterController?
    /// T-38 (06 §6.9 BetaTelemetry): local beta accounting — install hooks
    /// BEFORE any heavy work, open on launch, close on clean termination.
    private var betaTelemetry: BetaTelemetryStore?

    /// T-37 (README/help): the Help menu entry opens the repo README (online
    /// docs stay the single source of truth — no offline help book in v1).
    @objc func openHelp(_ sender: NSMenuItem?) {
        let docs = URL(string: "https://github.com/dmitvm-sudo/MyCommander#readme")  // l10n-allow: URL, not UI copy
            ?? URL(fileURLWithPath: "/")
        NSWorkspace.shared.open(docs)
    }

    /// T-38: «Экспорт отчёта беты…» — writes the local beta summary (no
    /// network, N-9) through a save panel; the user sends it themselves.
    @objc func exportBetaReport(_ sender: NSMenuItem?) {
        guard let telemetry = betaTelemetry, let window = mainWindow?.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mycommander-beta-\(Self.stampedFileName()).txt"
        panel.beginSheetModal(for: window) { [telemetry] response in
            guard response == .OK, let url = panel.url else { return }
            let version = Self.readableVersion()
            let os = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            let report = telemetry.makeFeedbackReport(appVersion: version, osVersion: os)
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = String(localized: "feedback.savedTitle")
                alert.informativeText = String(format: String(localized: "feedback.savedBody"), url.path)
                alert.addButton(withTitle: String(localized: "feedback.okButton"))
                alert.runModal()
            } catch let error as NSError {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = String(localized: "feedback.failedTitle")
                alert.informativeText = String(
                    format: String(localized: "feedback.failedBody"),
                    error.localizedDescription
                )
                alert.addButton(withTitle: String(localized: "feedback.okButton"))
                alert.runModal()
            }
        }
    }

    /// Version/build for human faces: CFBundle values when the bundle has
    /// them (release assembly), sensible placeholders in SPM dev builds.
    private static func readableVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Localized-safe filename stamp: digits and letters only.
    private static func stampedFileName() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return stamp
            .replacingOccurrences(of: ":", with: "")
            .prefix(16)
            .description
    }

    func run() {
        let application = NSApplication.shared
        application.delegate = self
        application.setActivationPolicy(.regular)

        // T-38: crash hooks first — a crash during bootstrap must leave a
        // tombstone (06 §6.9); the ledger session opens right after.
        let telemetry = BetaTelemetryStore()
        self.betaTelemetry = telemetry
        telemetry.installCrashHooks()
        telemetry.beginSession()

        let coordinator = PanelsCoordinator()
        self.coordinator = coordinator
        // T-37 (F-9): the updater starts only from a release bundle config;
        // the menu reflects availability (dev = disabled item).
        let updater = UpdaterController()
        self.updater = updater
        updater.start()
        // T-09: the menu reflects the active keymap profile (§6.10).
        coordinator.menuUpdater = updater
        coordinator.menuHelpTarget = self
        application.mainMenu = MenuBuilder.build(
            router: coordinator.router,
            keymap: coordinator.keymapStore,
            locations: coordinator.locationsStore,
            updater: updater,
            helpTarget: self
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
        // T-38: clean session end — the launch-side ledger stays consistent
        // (kill/force-quit paths stay unterminated per 06 §6.9).
        betaTelemetry?.endSessionClean()
        PreviewMaterializer.purgeTempCopies()
    }
}
