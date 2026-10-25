// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import ServicesKit

// T-17: the pure onboarding state model (F-20, 06 §6.10 v1) — the «max 2
// re-offers, then only the badge» rule and the hide transition. Helpers use
// the `ob` name-space (the test module compiles neighbouring files together).

@Test func obFirstLaunchOffersOnce() {
    let fresh = OnboardingState()
    #expect(fresh.shouldOfferInitially)
    #expect(fresh.canOfferAgain)
}

@Test func obDismissCountsUpToTwoThenStops() {
    var state = OnboardingState()
    state = state.afterDismiss()
    #expect(state.dismissedCount == 1)
    #expect(!state.shouldOfferInitially)   // the initial offer happened
    #expect(state.canOfferAgain)           // second offer still allowed

    state = state.afterDismiss()
    #expect(state.dismissedCount == 2)
    #expect(!state.canOfferAgain)          // «max 2 раса» — only the badge now
}

@Test func obHideIsTerminal() {
    let state = OnboardingState(dismissedCount: 1).hiddenPermanently
    #expect(state.hidden)
    #expect(!state.shouldOfferInitially)
    #expect(!state.canOfferAgain)
}
