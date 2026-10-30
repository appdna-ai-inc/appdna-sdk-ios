// PaywallFeatureTapWalkUITests.swift
//
// A FEATURE ROW IS TAPPABLE, AND THE PAYWALL STILL SCROLLS.
//
// `feature_selected` had no emitter on either platform because feature rows were decorative. The
// owner asked for all four remaining `PaywallAction` cases, so the rows gained a tap — which is
// new UI on the surface that takes the money.
//
// 🔴 THE SECOND ASSERTION IS THE ONE THAT MATTERS. A tap handler added to a row inside a scroll
// view is exactly how this repo has already broken a screen: the keyboard-dismiss handler ate
// every gesture in an onboarding step, on both platforms, and the step looked fine in a
// screenshot. A row that reports its tap and a paywall nobody can scroll is a worse paywall than
// the one we started with.
//
// So this walks it: tap a row, read the action off the host's mirror, then SCROLL and prove the
// page moved.
import XCTest

final class PaywallFeatureTapWalkUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    func testAFeatureRowReportsItsTapAndThePaywallStillScrolls() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        // Tap-and-retry: `showPaywall` presents whatever config has already landed.
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let anyFeature = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Unlimited"),
        ).firstMatch
        for attempt in 0..<12 where !anyFeature.exists {
            if open.isHittable { open.tap() }
            if !anyFeature.waitForExistence(timeout: 5) { NSLog("[#1076] paywall not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(anyFeature.exists, "the paywall never drew its feature list")

        /*
         🔴 SCROLL FIRST, BEFORE ANY TAP. If the tap handler were swallowing gestures, tapping
         first and scrolling second would not tell them apart — the page would already be at a
         different offset. Measuring the scroll on an untouched screen makes it a clean control.
         */
        let before = anyFeature.frame.origin.y
        app.swipeUp()
        let afterScroll = anyFeature.frame.origin.y
        XCTAssertNotEqual(
            before, afterScroll,
            "the paywall did not scroll — a tappable feature row must not consume the scroll "
                + "gesture, which is exactly how this repo has broken a screen before",
        )
        NSLog("[#1076] scrolled: feature row moved from \(before) to \(afterScroll)")

        // Back to the top so the row is comfortably hittable, then tap it.
        app.swipeDown()
        XCTAssertTrue(anyFeature.waitForExistence(timeout: 5))
        NSLog("[#1076] tapping the feature row: \(anyFeature.label)")
        anyFeature.tap()

        /*
         The action reaches the host through `AppDNAPaywallDelegate.onPaywallAction`, which
         `TrackedEventLog` folds into the same zero-opacity label the other walks read — and which
         lives UNDER the paywall, so the paywall has to come down first.
         */
        let close = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "xmark", "close"),
        ).firstMatch
        if close.exists { close.tap() } else { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20), "could not get back to the host")

        let events = app.staticTexts["host.lastEvents"]
        XCTAssertTrue(events.waitForExistence(timeout: 15))
        let seen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "action:feature_selected"),
            object: events,
        )
        let outcome = XCTWaiter().wait(for: [seen], timeout: 20)
        NSLog("[#1076] events after the feature tap: \(events.label)")
        XCTAssertEqual(
            outcome, .completed,
            "the feature row reported nothing — events were: \(events.label)",
        )
    }
}
