// PaywallPlanSelectionWalkUITests.swift — #1068
//
// WHICH PRODUCT DOES THE CTA ACTUALLY BUY?
//
// #1018 proved the CTA completes a real StoreKit purchase. It could not prove which PLAN that
// purchase names, because the walk tapped the CTA with the default plan selected and never tapped
// a different one — so "selection is read at tap time" and "selection is ignored and the default
// is always bought" produce the identical run.
//
// That gap matters because the two are separate paths: `selectedPlanId` is renderer state, and the
// product id handed to StoreKit is read from it when the CTA fires. A regression that stopped
// reading it would charge every user the default plan's price, on a paywall that looked completely
// correct while doing it.
//
// 🔴 THE INSTRUMENT IS STOREKIT'S OWN LEDGER, NOT THE HOST'S EVENT MIRROR. `host.lastEvents`
// renders event NAMES only (`TrackedEventLog` keeps names, deliberately — an accessibility value
// is one string), so it can say a purchase happened and not what was bought. `SKTestSession`
// is held by THIS process and `allTransactions()` reports the product identifier StoreKit
// recorded. That is the fact in question, read from the system that owns it.
//
// 🔴 AND THE PROOF IS THE CONTRAST, NOT THE SECOND HALF OF IT. Asserting only "selecting annual
// buys annual" would pass on a paywall whose default was annual all along. So the test buys twice
// from the same fixture with ONE variable changed — a tap on the annual row — and asserts the two
// purchases name DIFFERENT products.
import XCTest
import StoreKitTest

final class PaywallPlanSelectionWalkUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    /// The store's prices, which are deliberately unlike the fixture's authored ones so a row can
    /// be identified on screen without ambiguity (`HostApp/Products.storekit`, and the authored
    /// `AUTHORED-11.11` / `AUTHORED-99.99` that `scripts/spec502/probe-1068-two-plan-walk.ts`
    /// publishes).
    private static let monthlyPrice = "4.49"
    private static let annualPrice = "34.99"

    func testSelectingAPlanDecidesWhichProductTheCTABuys() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("SKTestSession needs iOS 17") }
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

        // PASS 1 — the control: the CTA with nothing selected, which is #1018's walk.
        let boughtByDefault = try buy(app, session, apiKey: apiKey, paywallId: paywallId, tappingAnnual: false)
        NSLog("[#1068] default selection bought: \(boughtByDefault ?? "nothing")")

        session.clearTransactions()
        app.terminate()

        // PASS 2 — the same fixture, the same CTA, one variable changed.
        let boughtAfterTap = try buy(app, session, apiKey: apiKey, paywallId: paywallId, tappingAnnual: true)
        NSLog("[#1068] after tapping the annual plan bought: \(boughtAfterTap ?? "nothing")")

        XCTAssertEqual(
            boughtByDefault, "premium_monthly",
            "the fixture's default plan is the monthly one, so an untouched paywall must buy it — "
                + "StoreKit recorded \(boughtByDefault ?? "no transaction")",
        )
        XCTAssertEqual(
            boughtAfterTap, "premium_annual",
            "tapping the annual plan must change what the CTA buys — StoreKit recorded "
                + "\(boughtAfterTap ?? "no transaction")",
        )
        /*
         The contrast, stated as its own assertion so a failure reads as what it is. If both passes
         bought the same product, the renderer is not reading `selectedPlanId` at tap time and
         every user is charged the default plan's price whatever they chose.
         */
        XCTAssertNotEqual(
            boughtByDefault, boughtAfterTap,
            "both purchases named the same product, so the plan tap changed nothing",
        )
    }

    /// One pass: launch, check the store is real, open the paywall, optionally tap the annual plan,
    /// tap the CTA, and return the product identifier StoreKit recorded.
    @available(iOS 17.0, *)
    private func buy(
        _ app: XCUIApplication,
        _ session: SKTestSession,
        apiKey: String,
        paywallId: String,
        tappingAnnual: Bool,
    ) throws -> String? {
        app.launchArguments = [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        /*
         🔴 THE HARNESS CHECK FIRST, as in #1018. A paywall showing its authored price means either
         "the SDK never asked" or "this simulator has no catalogue", and the two are
         indistinguishable from the screen — so an empty store SKIPS with its measurement rather
         than failing as if plan selection were broken.
         */
        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawBoth = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:2"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawBoth], timeout: 25) != .completed,
            "the session served fewer than both products to the app (probe said \(probe.label)) — "
                + "nothing about which plan is bought can be proved from here",
        )
        NSLog("[#1068] store probe: \(probe.label)")

        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the host has no paywall button")

        /*
         🔴 TAP AND RETRY, BECAUSE ONE TAP IS A RACE. `showPaywall` presents whatever config has
         ALREADY landed — the SDK fetches it after `configure()`, and a tap that arrives first does
         nothing at all and gives no sign of it. One tap then waited thirty seconds for a paywall
         that was never asked for a second time, and failed as "no plan row was drawn", which reads
         like a fixture with one plan. `StorePriceUITests` carries the same loop for the same
         reason; this is not a flake to tolerate, it is a handshake to complete.
         *
         🔴 AND THE WAIT IS FOR THE STORE PRICE, NOT MERELY FOR THE PAYWALL. The rows are
         identified by the price they draw, and the SDK substitutes the store's price over the
         authored one once the products resolve — so a row found before that lands is a row whose
         label is about to change underneath the tap.
         */
        var found: XCUIElement?
        for attempt in 0..<12 where found == nil {
            // Only while the host is still in front: once the paywall covers it, another tap here
            // would land on the paywall's own controls.
            if open.isHittable { open.tap() }
            found = rowShowing(app, Self.annualPrice, timeout: 5)
            if found == nil { NSLog("[#1068] paywall not up yet, attempt \(attempt + 1)") }
        }
        let annualRow = try XCTUnwrap(
            found,
            "no plan row was drawn at the annual store price (\(Self.annualPrice)) after 12 "
                + "attempts — either the paywall never presented, or the fixture carries one plan; "
                + "publish it with scripts/spec502/probe-1068-two-plan-walk.ts",
        )
        XCTAssertNotNil(
            rowShowing(app, Self.monthlyPrice, timeout: 10),
            "no plan row was drawn at the monthly store price (\(Self.monthlyPrice))",
        )

        if tappingAnnual {
            NSLog("[#1068] tapping the annual plan: \(annualRow.label)")
            annualRow.tap()
        }

        let cta = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Start")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 25), "the paywall never drew its CTA")

        /*
         Wait for the purchase to be RECORDED rather than for the screen to change: a paywall may
         dismiss, stay or route somewhere on success depending on how it is authored, and none of
         those is the fact under test. `allTransactions()` is StoreKit's own ledger, read from the
         process that owns the session.
         *
         🔴 AND THE TAP IS RETRIED, BECAUSE THE FIRST PURCHASE AFTER A SESSION RESET SOMETIMES
         RECORDS NOTHING. Measured across four runs of this walk: the first CTA tap in a fresh
         `SKTestSession` produced no transaction in one of them and completed in ~1.5 seconds in
         the others — the second pass of the SAME run, with the same CTA, bought in 1.4 seconds.
         The CTA is `.disabled(isPurchasing || selectedPlanId == nil)`, so a tap that landed while
         a purchase was genuinely in flight is a no-op rather than a second purchase, and the
         `recorded.count == 1` assertion below still catches a double buy.
         *
         Every attempt is logged, so the evidence says how many taps it took rather than hiding it.
         */
        var recorded: [SKTestTransaction] = []
        for attempt in 1...3 where recorded.isEmpty {
            NSLog("[#1068] tapping the CTA (attempt \(attempt)): \(cta.label)")
            if cta.isHittable { cta.tap() }
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                recorded = session.allTransactions()
                if !recorded.isEmpty { break }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTAssertEqual(
            recorded.count, 1,
            "expected exactly one transaction from the CTA, got \(recorded.count): "
                + recorded.map(\.productIdentifier).joined(separator: ", ")
                + " — the SDK's own view of it was: \(eventsSeenByTheHost(app))",
        )
        return recorded.first?.productIdentifier
    }

    /// What the SDK TRACKED, read only when the ledger is empty — so a run that bought nothing
    /// says whether the CTA was even wired.
    ///
    /// 🔴 ON THE FAILURE PATH ONLY, because reading it costs a dismissal. `host.lastEvents` lives
    /// in the host's own view, UNDERNEATH the presented paywall, so getting at it means taking the
    /// paywall down — which is exactly the step that made #1018's walk flaky. A passing run must
    /// not pay for it. One run in seven recorded no transaction at all (#1072) and said nothing
    /// about why; `purchase_started` present or absent is the difference between "the CTA never
    /// fired" and "StoreKit did not answer".
    private func eventsSeenByTheHost(_ app: XCUIApplication) -> String {
        let hostTitle = app.staticTexts["host.title"]
        if !hostTitle.exists {
            // `xmark`, not "close": the control is `Image(systemName: "xmark")` in a Button with
            // no explicit label, and SwiftUI derives the label from the SYMBOL NAME.
            let close = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "xmark", "close"),
            ).firstMatch
            if close.exists { close.tap() } else { app.swipeDown() }
            _ = hostTitle.waitForExistence(timeout: 15)
        }
        let events = app.staticTexts["host.lastEvents"]
        return events.waitForExistence(timeout: 10) ? events.label : "(the host's event mirror was unreachable)"
    }

    /// A plan row, found by the price it draws, or nil if no BUTTON carries that price.
    ///
    /// 🔴 A BUTTON, AND ONLY A BUTTON — the first version fell back to `otherElements` and
    /// `staticTexts`, and that fallback matched the HOST'S OWN STORE PROBE. `host.storeProducts`
    /// renders `store:2 premium_annual=$34.99,premium_monthly=$4.49`, which contains every string
    /// a plan row contains, so on a run where the paywall did not present the helper returned the
    /// probe label, `XCTUnwrap` succeeded, the "tap" hit a zero-size label and the failure
    /// surfaced three assertions later as "the paywall never drew its CTA" — a message about the
    /// CTA for a paywall that was never up. Measured on the first red-control run.
    ///
    /// Every plan layout arm renders its row as `Button { selectPlan(plan.id) }`, so a missing
    /// button means a missing paywall, which is what the caller should say.
    private func rowShowing(_ app: XCUIApplication, _ price: String, timeout: TimeInterval) -> XCUIElement? {
        let button = app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] %@", price))
            .firstMatch
        return button.waitForExistence(timeout: timeout) ? button : nil
    }
}
