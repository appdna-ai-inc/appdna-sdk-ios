// TestPlanStoreKitCatalogueTests.swift — #934
//
// DOES THE TEST PLAN ACTIVATE THE SIMULATOR'S STORE UNDER `xcodebuild test`?
//
// #934 measured that it did not: the host's own probe answered `store:0` for the two ids sitting in
// `AppDNAHost/Products.storekit`, and the SDK's lookup agreed — "the store knows none of 2
// product(s)". Every generated-scheme attempt was a guess at the attribute Xcode writes, which is
// why that issue asked for the GUI diff.
//
// 🔴 THIS ASKS THE QUESTION FROM INSIDE THE APP PROCESS, which the earlier probe could not: it ran
// from `simctl launch`, where no test plan applies at all. A unit-test bundle with a TEST_HOST runs
// under the test action, so the test plan's `storeKitConfigurationFileReference` — already in
// `HostApp.xctestplan` — is in force if it is in force anywhere.
//
// 🔴 NO `SKTestSession` HERE, deliberately. A session serves its OWN catalogue, which would answer
// this question with the wrong catalogue and look like a pass. That also means this file must not
// share a process with `StoreTrialEligibilityHostedTests`, whose session would shadow the host's
// configuration — run it with its own `-only-testing`, which is how it is measured.
import XCTest
import StoreKit

final class TestPlanStoreKitCatalogueTests: XCTestCase {

    /// The two ids in `AppDNAHost/Products.storekit`, which the test plan references.
    private let hostCatalogueIds = ["premium_monthly", "premium_annual"]

    func testTheTestPlanServesTheHostCatalogue() async throws {
        let products = try await Product.products(for: hostCatalogueIds)
        let found = products.map(\.id).sorted()
        print("[#934] test-plan catalogue: asked for \(hostCatalogueIds.count), store answered \(products.count) — \(found)")
        for p in products {
            print("[#934]   \(p.id) displayPrice=\(p.displayPrice) period=\(String(describing: p.subscription?.subscriptionPeriod))")
        }
        /*
         🔴 MEASURED EMPTY, AND IT SKIPS RATHER THAN FAILS. The answer on Xcode 26 / iOS 26 is
         `store answered 0 — []`: the test plan's `storeKitConfigurationFileReference` does NOT reach
         the app process under `xcodebuild test`, so #934's mechanism is real and the scheme
         attribute Xcode writes in its GUI is still the only way to activate it that route.
         *
         This is a skip because the thing being measured is XCODE's behaviour, not ours. A red test
         here would be a standing failure nobody can fix from this repo, and Rule 17's lesson is that
         a gate loud about something you cannot act on is a gate you learn to ignore. The assertion
         below turns into a real one the day the answer is non-empty.
         *
         🔴 AND IT IS NO LONGER A BLOCKER. `SKTestSession(contentsOf:)` serves a catalogue in this
         same app process — `StoreTrialEligibilityHostedTests` reads `P1W` and a `displayPrice` out
         of one — so an app-process store proof is available by the other route. What is unavailable
         is the SCHEME route, which nothing needs.
         */
        try XCTSkipIf(
            products.isEmpty,
            "the test plan's StoreKit configuration did not reach the app process: the store answered "
                + "0 of \(hostCatalogueIds.count) (#934). Use SKTestSession(contentsOf:) to serve a "
                + "catalogue in-process instead — that route works and is what the eligibility test uses.",
        )
        XCTAssertEqual(
            found, hostCatalogueIds.sorted(),
            "the test plan served SOME of the catalogue but not all of it, which is neither of the two "
                + "outcomes #934 measured — read the ids above before trusting either half.",
        )
    }
}
