// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Contract: docs/SDD/06 §6.10 «Контракт v1 (T-17)» — the pure state model of
// the onboarding offer rule («повторная навязка — max 2 раза, потом только
// бейдж»). UserDefaults persistence belongs to the App layer (keys
// `mc.onboarding.*`); ServicesKit owns only the transitions, testable headless.

/// One persisted pull of the onboarding decision.
public struct OnboardingState: Sendable, Equatable {
    /// How many times the offer window has been dismissed without a grant
    /// («Продолжить без FDA» counts; System Settings round-trips that end in
    /// a grant do not — the flow closes itself on grant).
    public let dismissedCount: Int
    /// «Не показывать снова» — the offer stays closed forever, only the badge.
    public let hidden: Bool

    public init(dismissedCount: Int = 0, hidden: Bool = false) {
        self.dismissedCount = dismissedCount
        self.hidden = hidden
    }

    /// The very first launch: the offer may open once Activation probing ran.
    public var shouldOfferInitially: Bool {
        !hidden && dismissedCount == 0
    }

    /// Navied again after a denial (§6.10: max 2 total).
    public var canOfferAgain: Bool {
        !hidden && dismissedCount < 2
    }

    /// Dismissed without a grant.
    public func afterDismiss() -> OnboardingState {
        OnboardingState(dismissedCount: dismissedCount + 1, hidden: hidden)
    }

    /// «Не показывать снова» — terminal state of the offer.
    public var hiddenPermanently: OnboardingState {
        OnboardingState(dismissedCount: dismissedCount, hidden: true)
    }
}
