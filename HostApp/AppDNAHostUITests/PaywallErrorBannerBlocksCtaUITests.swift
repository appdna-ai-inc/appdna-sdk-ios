// PaywallErrorBannerBlocksCtaUITests.swift — #1072
//
// AFTER A PURCHASE FAILS, CAN THE USER STILL TAP BUY?
//
// 🔴 #1072 is "one purchase in seven records no StoreKit transaction at all, with no sign of why",
// and the "no sign of why" is the clue: a SwiftUI `Button` that never receives a touch runs no
// action, so it logs nothing, emits nothing, and calls no delegate. Everything inside
// `handleCTATap` — including #1074's `onAction?(.ctaTapped)`, which fires BEFORE the guards — is
// unreachable. From outside, that is indistinguishable from a store that refused.
//
// Three candidates were eliminated by measurement first: the resolution path is id-based end to end,
// `isPurchasing` is reset on every exit from `handlePurchase`, and the plan rows are hittable at 9 of
// 9 positions. The drift mechanism behind #1081 cannot reach the CTA either — `PaywallRenderer`
// excludes `cta` from the ScrollView (`section.type != "cta"`), so it is always pinned outside it.
//
// What is left is something COVERING the pinned CTA, and there is a specific candidate. The
// post-purchase error banner is pinned with a HARDCODED `.padding(.bottom, 80)` while the renderer
// separately MEASURES the pinned group as `pinnedZoneHeight` and uses that measurement only to
// decide overflow. Any paywall whose pinned zone is taller than 80 points — a CTA plus a restore
// link plus legal text, or a section authored `zone: "bottom"`, which #884 made possible for ANY
// section — has its CTA underneath that banner. The banner has an opaque red background, so it is
// hit-testable, and when `errorAllowRetry` is set it stays up until the user finds the Retry button.
//
// So: fail a purchase on purpose, then ask whether the user can buy. That is the real path, and it
// is ~1 in 7 if roughly 1 in 7 purchases is cancelled or refused first.
import XCTest
import StoreKitTest

final class PaywallErrorBannerBlocksCtaUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    private static let monthlyPrice = "4.49"

    @available(iOS 17.0, *)
    func testTheCtaIsStillUsableAfterAPurchaseFails() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchArguments = [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawBoth = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:2"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawBoth], timeout: 25) != .completed,
            "the session served fewer than both products (probe said \(probe.label))",
        )

        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        var row: XCUIElement?
        for _ in 0..<12 where row == nil {
            if open.isHittable { open.tap() }
            let b = app.buttons
                .containing(NSPredicate(format: "label CONTAINS[c] %@", Self.monthlyPrice))
                .firstMatch
            row = b.waitForExistence(timeout: 5) ? b : nil
        }
        XCTAssertNotNil(row, "no plan row drew at the monthly price")

        let cta = ctaButton(app)
        let before = try XCTUnwrap(cta, "no CTA button was found on the paywall")
        NSLog("[#1072] before any purchase: cta '\(before.label)' frame=\(before.frame) "
            + "enabled=\(before.isEnabled) hittable=\(before.isHittable)")

        /*
         🔴 THE FAILURE IS FORCED, because waiting for one is what made #1072 unreproducible for
         weeks. `failTransactionsEnabled` makes StoreKit refuse the next purchase, which is the state
         a user reaches by cancelling the sheet or having a card declined — the common case, not an
         exotic one.
        */
        session.failTransactionsEnabled = true
        before.tap()
        NSLog("[#1072] first CTA tap sent, with the store set to refuse")

        // Give the refusal time to land and the banner time to animate in.
        _ = waitUntil(timeout: 10) { self.bannerIsUp(app) }
        let bannerUp = bannerIsUp(app)
        NSLog("[#1072] after the refusal: banner up=\(bannerUp)")

        session.failTransactionsEnabled = false

        /*
         The claim: a user whose purchase just failed can try again. Whatever the paywall chose to
         show them, the button that buys must still be reachable — and the geometry is logged either
         way so a failure names WHY rather than only that.
        */
        let after = try XCTUnwrap(ctaButton(app), "the CTA button vanished after the failed purchase")
        NSLog("[#1072] after the refusal: cta '\(after.label)' frame=\(after.frame) "
            + "enabled=\(after.isEnabled) hittable=\(after.isHittable)")
        if let banner = bannerElement(app) {
            NSLog("[#1072] the error banner's frame=\(banner.frame) — overlaps the CTA: "
                + "\(banner.frame.intersects(after.frame))")
        }

        XCTAssertTrue(
            after.isEnabled,
            "the CTA is DISABLED after a failed purchase, so the user cannot retry — `isPurchasing` "
                + "was left set (this is the half #1072 ruled out by reading; a failure here means "
                + "the reading was wrong)",
        )
        XCTAssertTrue(
            after.isHittable,
            "the CTA is not hittable after a failed purchase — something is covering the pinned "
                + "button that buys, which is #1072 reproduced: a tap there reaches no action, so it "
                + "logs nothing, emits nothing and calls no delegate, and from outside the app it is "
                + "indistinguishable from a store that refused. Frames are in the log above.",
        )

        /*
         And hittable is not the same as working — a tap on a view that LOOKS like the CTA can land on
         an overlay above it and XCUITest reports no error (the disabled-button lesson). So the tap is
         actually sent and the host's own event readout is checked for a second purchase attempt.
        */
        after.tap()
        let events = app.staticTexts["host.lastEvents"]
        let sawRetry = waitUntil(timeout: 12) {
            events.exists && events.label.contains("purchase")
        }
        NSLog("[#1072] after the retry tap, host events: \(events.exists ? events.label : "(absent)")")
        XCTAssertTrue(
            sawRetry,
            "tapping the CTA after a failed purchase produced no purchase event at all — the tap "
                + "reached no action. That is #1072: no transaction, and no sign of why.",
        )
    }

    // MARK: - helpers

    /// The pinned CTA. Matched by its accessibility identifier where the renderer sets one, else by
    /// being the paywall's purchase button — never by position, which is what this test measures.
    private func ctaButton(_ app: XCUIApplication) -> XCUIElement? {
        let byId = app.buttons["paywall.cta"]
        if byId.exists { return byId }
        for label in ["Start Free Trial", "Continue", "Subscribe", "Start My Plan"] {
            let b = app.buttons[label]
            if b.exists { return b }
        }
        return nil
    }

    private func bannerElement(_ app: XCUIApplication) -> XCUIElement? {
        // The banner draws `errorMessage` as a static text over the bottom of the screen.
        for fragment in ["Payment failed", "failed", "error", "Try Again"] {
            let t = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
            if t.exists { return t }
        }
        return nil
    }

    private func bannerIsUp(_ app: XCUIApplication) -> Bool { bannerElement(app) != nil }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}
