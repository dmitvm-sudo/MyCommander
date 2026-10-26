// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle

// T-37 (F-9): Sparkle 2 автообновления. Contract (03 N-9): EdDSA-подписанные
// appcast'ы с хостом GitHub Releases; фид + публичный EdDSA-ключ живут
// ТОЛЬКО в Info.plist релизного app-bundle (Tools/release/build-app.sh) —
// SPM dev-сборки Info.plist не имеют → контроллер остаётся неактивным
// (no-op), пункт меню проверок появляется, но disabled. Ни сети, ни
// промптов, пока конфигурации нет (N-9 «никакой сетевой активности кроме
// явно запрошенной»).

/// Sparkle wiring. Lives at the App level only (ServicesKit stays AppKit-
/// free). The updater checks on demand from the menu; automatic scheduled
/// checks come from Sparkle's defaults (disabled in a bare profile until
/// the first user-initiated run — Sparkle asks on first check).
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Non-nil only when the app bundle carries a release configuration.
    private(set) var updater: SPUUpdater?
    /// Menu enablement: «Check for Updates…» is disabled in dev builds.
    private(set) var isAvailable = false

    func start() {
        // Info.plist gate: SUFeedURL comes from the assembled release bundle;
        // a missing key means an SPM dev build → stay dormant (N-9).
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        let driver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: self)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: self
        )
        do {
            try updater.start()
            self.updater = updater
            isAvailable = true
        } catch let error as NSError {
            // Sparkle misconfiguration must never take the app down — log
            // and keep the manual check entry disabled; a wrong release
            // assembly shows up in the DMG smoke run (08 §8.4 п.1).
            let note = error.localizedDescription
            NSLog("MyCommander updater: start failed — %@", note)  // l10n-allow: system log, not UI copy
        }
    }

    /// Menu action (app menu item, target = self).
    @objc func checkForUpdates() {
        updater?.checkForUpdates()
    }
}
