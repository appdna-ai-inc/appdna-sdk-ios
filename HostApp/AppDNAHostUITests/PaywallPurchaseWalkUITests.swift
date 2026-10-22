// PaywallPurchaseWalkUITests.swift — #1018
//
// A REAL STOREKIT PURCHASE, THROUGH THE PAYWALL'S OWN CTA, ON A DEVICE.
//
// #1018 was parked on #934 — the simulator's scheme has no StoreKit configuration for the TEST
// action, so a paywall opened under `xcodebuild test` saw an empty store and the CTA could not buy
// anything. The stated reason it could not borrow #933's route was that "a UI test drives the app
// from outside it, and the test process is the only place that can hold an SKTestSession".
//
// 🔴 THAT WAS WRONG, and `StoreSessionReachesTheAppUITests` measures it: a session held HERE serves
// the app this test launches (`store:1 … =$9.99`). `SKTestSession` configures the simulator's
// StoreKit environment, not the calling process's. So the walk is possible without #934.
//
// What this proves that a unit test cannot: the CTA a user actually taps reaches StoreKit, the
// purchase completes against a real (test) store, and the SDK reports it — the whole chain, from
// the pixel to the event.
import XCTest
import StoreKitTest

final class PaywallPurchaseWalkUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    func testTheCTABuysThroughRealStoreKit() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("SKTestSession needs iOS 17") }
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        /*
         The HOST's catalogue, because the published paywall's plan references `premium_monthly`
         and the session must serve THAT id. A session over the other fixture would leave the
         product unknown and the CTA would fail for a reason that has nothing to do with the CTA.
         */
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }

        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        // No purchase sheet: the walk is about what the CTA reaches, not about Apple's UI.
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchArguments += [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        /*
         🔴 THE HARNESS CHECK FIRST. A paywall that shows its authored price means either "the SDK
         never asked" or "this simulator has no catalogue", and the two are indistinguishable from
         the screen. If the store is empty, everything below is meaningless — so it skips with the
         measurement rather than failing as if the CTA were broken.
         */
        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawProducts = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:1"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawProducts], timeout: 25) != .completed,
            "the session served no products to the app (probe said \(probe.label)) — nothing about "
                + "the CTA can be proved from here",
        )
        NSLog("[#1018] store probe: \(probe.label)")

        // Open the paywall the way a user does.
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the host has no paywall button")
        open.tap()

        /*
         The CTA, found by its LABEL rather than an identifier: it is the SDK's own rendered button,
         not the host's, so the host cannot give it one. The published fixture's CTA reads
         "Start Free Trial".
         */
        let cta = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Start")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 25), "the paywall never drew its CTA")
        NSLog("[#1018] tapping the CTA: \(cta.label)")
        cta.tap()

        /*
         🔴 THE ASSERTION IS THE EVENT, not the screen. A paywall may dismiss, stay, or route
         somewhere on success depending on how it is authored — but `purchase_completed` is emitted
         by `EventTracker` once StoreKit has actually granted the product, and the host mirrors
         every tracked event into `host.lastEvents` (#1047). So this asserts the purchase HAPPENED
         rather than that the screen changed.
         *
         🔴 AND IT IS READ ONLY ONCE THE HOST IS FRONTMOST AGAIN. `host.lastEvents` lives in the
         host's own view, UNDERNEATH the presented paywall, and XCUITest cannot see it while the
         paywall covers the screen — the first version of this test failed on
         "No matches found for Elements matching predicate 'host.lastEvents'" while the paywall was
         still up, which reads exactly like "no purchase happened". So: wait for the host to come
         back, dismissing the paywall ourselves if it does not dismiss itself.
         */
        let hostTitle = app.staticTexts["host.title"]
        if !hostTitle.waitForExistence(timeout: 30) {
            // The paywall stayed up — close it so the host's event mirror is reachable. A paywall
            // that does not auto-dismiss on purchase is a legitimate authoring choice, not a
            // failure, so this is a step rather than an assertion.
            let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "close")).firstMatch
            if close.exists { close.tap() } else { app.swipeDown() }
            XCTAssertTrue(hostTitle.waitForExistence(timeout: 20), "could not get back to the host")
        }

        let events = app.staticTexts["host.lastEvents"]
        XCTAssertTrue(events.waitForExistence(timeout: 15), "the host never rendered its event mirror")
        let purchased = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "purchase_completed"),
            object: events,
        )
        let outcome = XCTWaiter().wait(for: [purchased], timeout: 45)
        NSLog("[#1018] events after the CTA tap: \(events.label)")
        XCTAssertEqual(
            outcome, .completed,
            "the CTA did not complete a purchase — events were: \(events.label)",
        )
    }
}
