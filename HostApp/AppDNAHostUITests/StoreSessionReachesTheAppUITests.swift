// StoreSessionReachesTheAppUITests.swift
//
// DOES AN `SKTestSession` HELD BY THE UI-TEST PROCESS SERVE THE APP UNDER TEST?
//
// The scheme-level StoreKit configuration depends on the scheme attribute Xcode writes in its GUI, because every generated-scheme
// attempt has been a guess at the placement — and a measurement with the guess applied still gives
// `store answered 0` (`TestPlanStoreKitCatalogueTests`). So the scheme route is unproven by us.
//
// 🔴 BUT THE SCHEME IS NOT THE ONLY WAY TO PUT A CATALOGUE IN FRONT OF AN APP. `SKTestSession`
// configures the SIMULATOR's StoreKit environment, and creating one TERMINATES running app
// processes to apply — which is the behaviour of something device-wide rather than process-local
// (measured: "SKTestSession kills an app process"). If that is so, a UI test can hold the
// session and the app it launches afterwards should see the products.
//
// That is the question this test answers, and the answer decides whether a CTA-tap purchase walk is possible: a CTA-tap purchase walk
// needs a catalogue in the app under test, and a UI test drives the app from OUTSIDE its process.
//
// It is written to SKIP rather than fail when the answer is no, because the answer is Apple's
// behaviour and not a defect in this repo — but the probe's label is logged either way, so the
// measurement is in the log whichever way it goes.
import XCTest
import StoreKitTest

final class StoreSessionReachesTheAppUITests: XCTestCase {

    func testAUITestsStoreSessionIsVisibleToTheAppItLaunches() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("SKTestSession needs iOS 17")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "AppDNATestProducts", withExtension: "storekit")
            ?? Bundle.main.url(forResource: "AppDNATestProducts", withExtension: "storekit") else {
            throw XCTSkip("AppDNATestProducts.storekit is not in the UI-test bundle")
        }

        // The session is created BEFORE the app launches, so the app starts into an environment
        // that already has a store — the order a purchase walk would need.
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        /*
         The ids in `AppDNATestProducts.storekit`, NOT the host's own `Products.storekit`: the
         question is whether THIS session's catalogue reaches the app, so asking for the other
         file's ids would answer a different question and could pass for the wrong reason.
         */
        app.launchArguments += ["-appdnaProbeStore", "ai.appdna.test.monthly_trial"]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the host never rendered its store probe")

        let sawProducts = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:1"),
            object: probe,
        )
        let outcome = XCTWaiter().wait(for: [sawProducts], timeout: 25)
        NSLog("[storekit-session] UI-test SKTestSession → app probe said: \(probe.label)")

        try XCTSkipIf(
            outcome != .completed,
            "an SKTestSession held by the UI-TEST process does NOT serve the app under test "
                + "(probe said \(probe.label)). The CTA purchase walk therefore still needs the "
                + "scheme's StoreKit configuration. This is Apple's behaviour, not a "
                + "defect here, so it skips with the measurement rather than failing.",
        )

        // If we get here the route WORKS, and the purchase walk needs no scheme-level StoreKit setup.
        XCTAssertTrue(probe.label.hasPrefix("store:1"), "expected one product, got \(probe.label)")
    }
}
