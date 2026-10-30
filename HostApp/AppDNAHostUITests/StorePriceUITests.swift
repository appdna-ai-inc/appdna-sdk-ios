// StorePriceUITests.swift
//
// Does the paywall show what the STORE charges, or what an author typed?
//
// 🔴 THIS HAS TO BE A UI TEST, and that is not a preference. `STOREKIT_CONFIGURATION` is honoured
// by the SCHEME that launches the app — `xcodebuild test` carries it, a bare
// `xcrun simctl launch` does not. Measured: launched by simctl, the SDK asked StoreKit for the
// two product ids and got an empty answer back ("the store knows none of 2 product(s)"), which is
// indistinguishable from a device with no products configured. Launched by the scheme, the same
// code gets the configured catalogue. So a screenshot taken after a simctl launch can never prove
// this feature, and the first attempt to do so proved nothing twice.
//
// The catalogue is `HostApp/Products.storekit`, priced deliberately unlike anything a test paywall
// authors so the two can never be confused:
//
//     premium_monthly   $4.49    P1M
//     premium_annual    $34.99   P1Y
//
// The paywall under test authors `AUTHORED-11.11` / `AUTHORED-99.99` against those same product
// ids. Before the store-price substitution the screen read AUTHORED-11.11 while StoreKit held $4.49 — the defect, exactly.
//
// Needs a backend, a key and a published paywall, so it SKIPS unless `TestCredentials` is filled
// in: `packages/appdna-sdk-ios/**` is a public mirror and carries no credentials.
// `scripts/sdk-host-ios.ts --uitest --api-key … --paywall …` writes them on the Mac before building.
import XCTest

final class StorePriceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    func testThePaywallShowsTheStorePriceAndNotTheAuthoredOne() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            // The harness check below, before the feature check.
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 15))

        /*
         🔴 IS THERE A STORE AT ALL? This separates a harness fault from an SDK one, and the two
         are indistinguishable from the paywall alone: a screen showing the authored price means
         either "the SDK never asked" or "the SDK asked and this simulator has no catalogue".
         `STOREKIT_CONFIGURATION` only copies the file into the bundle; the scheme reference that
         switches the store over is what makes it live, and XcodeGen writes that for the Run action
         and not the Test one. Without this assertion, that harness gap reads as a broken feature.
        */
        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let sawProducts = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:2"),
            object: probe,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [sawProducts], timeout: 20), .completed,
            "the simulator served no StoreKit products (probe said \(probe.label)) — the scheme's "
            + "StoreKit configuration is not active for the TEST action, so nothing below can be "
            + "proved either way",
        )
        NSLog("store probe: \(probe.label)")

        // The SDK fetches its config after configure(); the paywall cannot present before it lands.
        // Tapping and retrying records how long it took, rather than hiding it in one long sleep.
        var presented = false
        for attempt in 0..<12 where !presented {
            app.buttons["host.paywall"].tap()
            presented = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "4.49")
            ).firstMatch.waitForExistence(timeout: 5)
                || app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", "AUTHORED")
                ).firstMatch.waitForExistence(timeout: 2)
            if !presented { NSLog("paywall not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(presented, "the paywall never presented — config did not arrive")

        /*
         The assertion, both ways round. Asserting only that $4.49 appears would pass on a screen
         that showed BOTH — and the failure mode this guards is a fallback that fires when it
         should not, which looks like the authored string surviving beside the real one.
         */
        let storePrice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "4.49")
        ).firstMatch
        XCTAssertTrue(
            storePrice.waitForExistence(timeout: 10),
            "the monthly plan must show StoreKit's $4.49 — Products.storekit prices it there, and "
            + "before store prices the renderer never asked the store at all",
        )

        let authored = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "AUTHORED-11.11")
        ).firstMatch
        XCTAssertFalse(
            authored.exists,
            "the authored price must be GONE, not merely accompanied — it is the fallback, and a "
            + "fallback that renders beside the real price is the same defect in a new shape",
        )

        // The annual plan goes through the same substitution, so it proves the map is per-product
        // rather than one price applied to everything.
        let annual = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "34.99")
        ).firstMatch
        XCTAssertTrue(
            annual.waitForExistence(timeout: 5),
            "the annual plan must show its OWN store price ($34.99), not the monthly one",
        )
    }
}
