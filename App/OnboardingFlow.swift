// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import ServicesKit
import VFSKit

// Contract: docs/SDD/06 §6.10 «OnboardingFlow (F-20)» + «Контракт v1 (T-17)» —
// the FDA offer window is non-modal («Продолжить без FDA» / «Не показывать
// снова»); probing re-runs on every app activation and a grant closes the
// window on its own. The denial rule «max 2 runs, then only the badge» lives
// in OnboardingState (ServicesKit).

@MainActor
final class OnboardingFlow: NSObject {
    enum Strings {
        static let systemSettingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        static let hiddenKey = "mc.onboarding.hidden"
        static let dismissedKey = "mc.onboarding.dismissed"
    }

    /// The coordinator applies the badge/seed side effects.
    private weak var coordinator: PanelsCoordinator?
    private let defaults: UserDefaults

    private var onboardingState: OnboardingState
    private var accessWindowController: NSWindowController?
    private var lastReportedMode: AccessMode?

    init(coordinator: PanelsCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.onboardingState = OnboardingState(
            dismissedCount: defaults.integer(forKey: Strings.dismissedKey),
            hidden: defaults.bool(forKey: Strings.hiddenKey)
        )
        super.init()

        // F-20: the probe softens on every return to the app (the user may
        // have granted Full Disk Access in System Settings meanwhile).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Probe immediately and install the mode; the first offer opens only for
    /// an undecided state (OnboardingState.shouldOfferInitially).
    func begin() {
        refresh(acceptFirstOffer: onboardingState.shouldOfferInitially)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appBecameActive() {
        // A grant closes the offer window itself; a persisting denial does
        // not re-open it during this session.
        refresh(acceptFirstOffer: false)
    }

    @objc private func openSystemSettings(_ sender: Any) {
        if let url = URL(string: Strings.systemSettingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func continueWithoutAccess(_ sender: Any) {
        applyNewState(onboardingState.afterDismiss())
        accessWindowController?.close()
        accessWindowController = nil
    }

    @objc private func hideForever(_ sender: Any) {
        applyNewState(onboardingState.afterDismiss().hiddenPermanently)
        accessWindowController?.close()
        accessWindowController = nil
    }

    // MARK: plumbing

    /// Fresh probe → mode handling + badge; optionally presents the offer.
    private func refresh(acceptFirstOffer: Bool) {
        let report = AccessProbe.probe()
        let mode = AccessProbe.classify(report)
        coordinator?.applyAccessMode(mode, grantedZones: report.grantedZones)

        if mode == .full {
            accessWindowController?.close()
            accessWindowController = nil
            return
        }
        if acceptFirstOffer {
            showOffer()
        }
    }

    private func applyNewState(_ newState: OnboardingState) {
        onboardingState = newState
        defaults.set(newState.dismissedCount, forKey: Strings.dismissedKey)
        defaults.set(newState.hidden, forKey: Strings.hiddenKey)
    }

    /// The non-modal offer window (06 §6.10): explanation, action buttons;
    /// a second open inside one session reuses the controller.
    private func showOffer() {
        if let existing = accessWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "onboarding.title")
        window.center()

        let headline = NSTextField(labelWithString: String(localized: "onboarding.headline"))
        headline.font = NSFont.boldSystemFont(ofSize: 13)
        let body = NSTextField(labelWithString: String(localized: "onboarding.body"))
        body.font = NSFont.systemFont(ofSize: 12)
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [headline, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = NSButton(
            title: String(localized: "onboarding.openSettings"),
            target: self,
            action: #selector(openSystemSettings(_:))
        )
        settingsButton.keyEquivalent = "\r"
        let continueButton = NSButton(
            title: String(localized: "onboarding.continueWithout"),
            target: self,
            action: #selector(continueWithoutAccess(_:))
        )
        let hideButton = NSButton(
            title: String(localized: "onboarding.hide"),
            target: self,
            action: #selector(hideForever(_:))
        )
        let buttons = NSStackView(views: [settingsButton, continueButton, hideButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [stack, buttons])
        container.orientation = .vertical
        container.spacing = 18
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        window.contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])

        let controller = NSWindowController(window: window)
        accessWindowController = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
