import Testing
@testable import HmunmawiCore

@Suite struct AppStorePitchExtractTests {
    @Test func summarizeExtractsOutcomeBulletsAndWhatsNewStrippingFooters() {
        let description = """
        ExampleApp connects your daily signals on your iPhone so you notice patterns days before burnout hits.

        CORRELATIONS
        - Signal A vs Signal B - shows when late sessions trigger a dip the next morning
        - Signal C vs Signal D - pairs sleep debt with readiness score privately with no account
        - Signal E vs Signal F - tracks habit streaks without noisy charts

        IN-APP PURCHASE
        - Pro (Monthly or Annual auto-renew subscription) - unlock every theme

        Found a bug? Email support@example.com
        Privacy Policy: https://example.com/privacy
        Terms of Use and medical advice disclaimer apply.
        """
        let whatsNew = """
        What's New:
        - Faster correlation timeline on launch
        - New weekly readiness summary card
        Found a bug? Email support@example.com
        """

        let highlights = AppStorePitchExtract.summarize(description: description, whatsNew: whatsNew)

        #expect(highlights.outcome.contains("ExampleApp connects your daily signals"))
        #expect(!highlights.outcome.lowercased().contains("in-app purchase"))
        #expect(!highlights.outcome.lowercased().contains("example.com"))

        #expect((2...3).contains(highlights.bullets.count))
        #expect(highlights.bullets.contains { $0.contains("Signal A vs Signal B") })
        #expect(highlights.bullets.contains { $0.contains("Signal C vs Signal D") })
        #expect(highlights.bullets.allSatisfy { !$0.lowercased().contains("auto-renew") && !$0.lowercased().contains("example.com") && !$0.lowercased().contains("found a bug") })

        #expect(highlights.whatsNew == [
            "Faster correlation timeline on launch",
            "New weekly readiness summary card",
        ])
    }

    @Test func replyWantsPromoCodeDetectsExplicitRequestsAndIgnoresNormalOrDeclineReplies() {
        #expect(AppStorePitchExtract.replyWantsPromoCode("Could you send a promo code to try Pro?"))
        #expect(!AppStorePitchExtract.replyWantsPromoCode("Thanks, downloading from the App Store"))
        #expect(!AppStorePitchExtract.replyWantsPromoCode("No thanks, not a fit"))
    }

    @Test func couponLeakProblemBlocksUnsolicitedCodesUnlessAllowed() {
        #expect(AppStorePitchExtract.couponLeakProblem("Happy to send a free code if you want to try it.", allowCode: false) != nil)
        #expect(AppStorePitchExtract.couponLeakProblem("Unlock free lifetime access today!", allowCode: false) != nil)
        #expect(AppStorePitchExtract.couponLeakProblem("Here is the free code you asked for.", allowCode: true) == nil)
        #expect(AppStorePitchExtract.couponLeakProblem("Here is a free lifetime pass you requested.", allowCode: true) == nil)
    }
}
