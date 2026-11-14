// PaywallPurchaseWalkUITests.swift
//
// A REAL STOREKIT PURCHASE, THROUGH THE PAYWALL'S OWN CTA, ON A DEVICE.
//
// This walk was once considered blocked — the simulator's scheme has no StoreKit configuration for the TEST
// action, so a paywall opened under `xcodebuild test` saw an empty store and the CTA could not buy
// anything. The stated reason it could not borrow the hosted trial-eligibility test's route was that "a UI test drives the app
// from outside it, and the test process is the only place that can hold an SKTestSession".
//
// 🔴 THAT WAS WRONG, and `StoreSessionReachesTheAppUITests` measures it: a session held HERE serves
// the app this test launches (`store:1 … =$9.99`). `SKTestSession` configures the simulator's
// StoreKit environment, not the calling process's. So the walk is possible without a scheme-level StoreKit configuration.
//
// What this proves that a unit test cannot: the CTA a user actually taps reaches StoreKit, the
// purchase completes against a real (test) store, and the SDK reports it — the whole chain, from
// the pixel to the event.
import XCTest
import StoreKitTest

final class PaywallPurchaseWalkUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }
    /*
     #1365 — THE EXPECTED PRODUCT IS A PARAMETER. The fixture paywall defaults to its monthly plan,
     and a paywall that pre-selects ANNUAL (a generated one does) made this walk assert a monthly
     purchase it could never see. `purchasePlanText` taps a plan row first, so the walk can also
     prove that the row a user picks is the product StoreKit is asked for.
     */
    private var expectedProduct: String {
        TestCredentials.purchaseProduct.isEmpty ? "premium_monthly" : TestCredentials.purchaseProduct
    }
    private var planText: String? {
        TestCredentials.purchasePlanText.isEmpty ? nil : TestCredentials.purchasePlanText
    }

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
            "-appdnaProbeStore", expectedProduct,
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
        NSLog("[purchase-walk] store probe: \(probe.label)")

        // Open the paywall the way a user does.
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the host has no paywall button")

        /*
         The CTA, found by its LABEL rather than an identifier: it is the SDK's own rendered button,
         not the host's, so the host cannot give it one. The published fixture's CTA reads
         "Start Free Trial".
         *
         🔴 TAPPED AND RETRIED, BECAUSE ONE TAP IS A RACE. `showPaywall` presents whatever
         config has ALREADY landed, and the SDK fetches it after `configure()` — a tap that arrives
         first does nothing and says nothing. One tap then spent its whole timeout waiting for a
         paywall nobody had asked for a second time, and failed as "the paywall never drew its CTA".
         `StorePriceUITests` carries this loop too, for the same reason.
         */
        let cta = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Start")).firstMatch
        for attempt in 0..<12 where !cta.exists {
            // Only while the host is still in front: once the paywall covers it, another tap here
            // would land on the paywall's own controls.
            if open.isHittable { open.tap() }
            if !cta.waitForExistence(timeout: 5) { NSLog("[purchase-walk] paywall not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(cta.exists, "the paywall never drew its CTA after 12 attempts")

        if let planText {
            /*
             The plan row, by text on it (a price), EXCLUDING the CTA: a CTA that restates the plan
             name would otherwise match first. The selection is read back through the row's
             `.isSelected` trait before the CTA is pressed, so a tap that never reached `selectPlan`
             fails here, not as a wrong product in the ledger.
             */
            let row = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)", planText, "Start",
            )).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no plan row shows \"\(planText)\"")
            NSLog("[purchase-walk] tapping the plan row: \(row.label) (selected=\(row.isSelected) before)")
            row.tap()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && !row.isSelected { Thread.sleep(forTimeInterval: 0.25) }
            NSLog("[purchase-walk] the plan row reports selected=\(row.isSelected); CTA now: \(cta.label)")
            XCTAssertTrue(row.isSelected, "the plan row did not take the selection")
        }
        NSLog("[purchase-walk] tapping the CTA: \(cta.label)")
        cta.tap()

        /*
         🔴 STOREKIT'S OWN LEDGER FIRST, because it is readable whatever the screen is doing. The
         event mirror below lives in the HOST's view, underneath the presented paywall, so reading
         it needs the paywall out of the way — and when that fails, "no purchase happened" and "the
         paywall would not dismiss" look identical. `allTransactions()` is held by THIS process and
         separates them. Measured: a run where the paywall stayed up reported "could not get back
         to the host" for a purchase that had in fact completed.
         */
        var bought: [SKTestTransaction] = []
        let storeDeadline = Date().addingTimeInterval(45)
        while Date() < storeDeadline {
            bought = session.allTransactions()
            if !bought.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        NSLog("[purchase-walk] StoreKit recorded: \(bought.map(\.productIdentifier).joined(separator: ", "))")
        XCTAssertEqual(
            bought.map(\.productIdentifier), [expectedProduct],
            "the CTA did not reach StoreKit — its ledger holds "
                + "\(bought.map(\.productIdentifier).joined(separator: ", "))",
        )

        /*
         🔴 THE ASSERTION IS THE EVENT, not the screen. A paywall may dismiss, stay, or route
         somewhere on success depending on how it is authored — but `purchase_completed` is emitted
         by `EventTracker` once StoreKit has actually granted the product, and the host mirrors
         every tracked event into `host.lastEvents`. So this asserts the purchase HAPPENED
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
            /*
             🔴 `xmark`, NOT `close`. The dismiss control is `Image(systemName: "xmark")` inside a
             Button with no explicit accessibility label, and SwiftUI derives the button's label
             from the SYMBOL NAME — so a predicate looking for "close" matched nothing, the
             `swipeDown` fallback did nothing to a full-screen cover, and the test failed on a
             purchase that had completed. Measured 2026-10-22.
             */
            let close = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                            "xmark", "close", "dismiss"),
            ).firstMatch
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
        NSLog("[purchase-walk] events after the CTA tap: \(events.label)")
        XCTAssertEqual(
            outcome, .completed,
            "the CTA did not complete a purchase — events were: \(events.label)",
        )

        /*
         🔴 AND THE HOST WAS TOLD THE USER TAPPED, as a fact of its own. `onPaywallAction`
         was declared on iOS and called from nowhere, while Android emitted `CTA_TAPPED` — so the
         same published paywall reported the tap on one platform and nothing on the other. It is
         reported BEFORE the renderer's plan guards, which is what makes a tap that cannot become a
         purchase distinguishable from one the SDK never received.
         */
        XCTAssertTrue(
            events.label.contains("action:cta_tapped"),
            "the host was never told the CTA was tapped — events were: \(events.label)",
        )
    }
}
