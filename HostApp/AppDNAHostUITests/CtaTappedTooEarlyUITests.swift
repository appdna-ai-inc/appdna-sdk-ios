// CtaTappedTooEarlyUITests.swift — #1072
//
// WHAT HAPPENS WHEN THE CTA IS TAPPED THE INSTANT IT APPEARS?
//
// #1072 is a purchase that recorded nothing: one run in nine tapped the CTA, waited sixty seconds
// and StoreKit's ledger stayed empty, while every other run bought in about a second and a half.
// Twenty further purchases did not reproduce it, so chasing it by repetition was finished.
//
// 🔴 THE CANDIDATE MECHANISM IS A BUTTON THAT IS DRAWN BEFORE IT WORKS. The renderer's root-CTA
// path carries `.disabled(isPurchasing || selectedPlanId == nil)`, and `selectedPlanId` is seeded
// in `.onAppear` — which runs AFTER the first layout pass. So there is a window, at least one
// frame wide, in which the button exists, looks exactly like itself, and does nothing. A
// `XCUIElement.tap()` on a disabled SwiftUI button SUCCEEDS: XCUITest reports no error, nothing
// happens, and from the outside that is indistinguishable from a purchase that failed silently.
//
// The paywall with a `cta` SECTION has the same shape by another route: `handleCTATap` opens with
// `guard let planId = selectedPlanId else { return }`.
//
// So this reaches for the CTA as the FIRST thing, without waiting for the plan rows the other
// walks use as their readiness signal. `isEnabled` is recorded at the moment of the tap, which is
// the fact that separates "the CTA never fired" from "StoreKit did not answer".
//
// 🔴 WHAT IT MEASURED, AND WHAT IT CANNOT. First run: `isEnabled at first sight = true`, and the
// immediate tap bought `premium_monthly` in 1.7 seconds. So the hypothesis is NOT supported — but
// neither is it refuted, and the reason is the instrument: `XCUIElement.exists` becomes true when
// a SNAPSHOT is taken, and XCUITest polls for that roughly once a second. A window one frame wide
// closes long before the first poll, so this test cannot land inside it by construction. It is
// recorded here rather than quietly re-run, because a test that cannot fail for the reason it was
// written is evidence of nothing (Rule 25).
//
// What it IS worth keeping for: the contract it asserts — a CTA that is visible is a CTA that
// works, and a tap at the earliest moment a user could manage one completes a purchase — is real,
// and nothing else in the suite asserts it. A regression that drew the button inert for a second
// rather than a frame would fail here.
import XCTest
import StoreKitTest

final class CtaTappedTooEarlyUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    func testTheCTAIsNeverDrawnBeforeItWorks() throws {
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
        app.launchArguments = [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawProducts = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawProducts], timeout: 25) != .completed,
            "the session served nothing to the app (probe said \(probe.label))",
        )

        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))

        // Open it, and reach for the CTA as the FIRST thing — no wait on the plan rows, which is
        // what every other walk uses to know the screen has settled.
        let cta = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Start")).firstMatch
        for attempt in 0..<12 where !cta.exists {
            if open.isHittable { open.tap() }
            if !cta.waitForExistence(timeout: 5) { NSLog("[#1072] paywall not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(cta.exists, "the paywall never drew its CTA")

        let enabledAtFirstSight = cta.isEnabled
        NSLog("[#1072] the CTA exists; isEnabled at first sight = \(enabledAtFirstSight)")
        cta.tap()

        var recorded: [SKTestTransaction] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            recorded = session.allTransactions()
            if !recorded.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        NSLog("[#1072] after an immediate tap, StoreKit recorded: "
            + (recorded.map(\.productIdentifier).joined(separator: ", ").isEmpty
               ? "nothing" : recorded.map(\.productIdentifier).joined(separator: ", ")))

        /*
         🔴 THE ASSERTION IS ABOUT THE WINDOW, NOT ABOUT THIS RUN'S LUCK. A button a user can see
         and press must do what it says. If it is drawn disabled — even for a frame — then the tap
         that lands in that frame is swallowed with no feedback, which is the shape #1072 measured.
         */
        XCTAssertTrue(
            enabledAtFirstSight,
            "the CTA was drawn DISABLED — a tap in this window is swallowed silently, which is "
                + "#1072's shape. StoreKit recorded: "
                + (recorded.isEmpty ? "nothing" : recorded.map(\.productIdentifier).joined(separator: ", ")),
        )
        XCTAssertEqual(
            recorded.count, 1,
            "a tap on a CTA the moment it appears must buy — it recorded "
                + "\(recorded.count) transaction(s)",
        )
    }
}
