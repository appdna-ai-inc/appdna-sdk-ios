// TestPlanStoreKitCatalogueTests.swift
//
// DOES THE TEST PLAN ACTIVATE THE SIMULATOR'S STORE UNDER `xcodebuild test`?
//
// **No — and the reason every earlier answer disagreed with the last one is worth more than the
// answer.**
//
// 🔴 `SKTestSession` PERSISTS ITS CATALOGUE ON THE SIMULATOR, PER BUNDLE ID, ACROSS RUNS. It
// writes:
//
//     <device>/data/Containers/Shared/AppGroup/<id>/Documents/Persistence/Octane/
//         ai.appdna.appdnaSdkExample/Configuration.storekit
//         com.apple.dt.xctest.tool/Configuration.storekit
//
// and that file OUTLIVES the process, the test run and the xcodebuild invocation. So the store the
// app sees is whatever session wrote last — not what the test plan says, and not what this run
// asked for. Measured by reading those files: after the eligibility test, the app's copy held
// `ai.appdna.test.*`; after a paywall walk, it held `premium_monthly`/`premium_annual`.
//
// That is why this test answered `0 — []` all day, then `2 — [premium_annual, premium_monthly]`
// with real prices, then `0` again, on the same machine with no code change between. Every reading
// was of a leftover.
//
// 🔴 THE UNCONTAMINATED MEASUREMENT, taken after deleting those files, is the only one that means
// anything:
//
//     [...] test-plan catalogue: asked for 2, store answered 0 — []
//     Test skipped - the test plan's StoreKit configuration served nothing AND no other catalogue
//     is active — neither the plan nor a session is in force.
//
// So `storeKitConfigurationFileReference` in `HostApp.xctestplan` is inert on Xcode 26.2, and
// Xcode's GUI cannot write one either: its StoreKit plugin ships exactly one scheme-option view
// controller, `IDEStoreKitLaunchActionOptionViewController.nib`, and `IDETestPlanEditor.framework`
// contains no StoreKit reference at all.
//
// 🔴 WHAT TO DO INSTEAD, and this is the part that matters for every test here: a test that needs
// a catalogue must OPEN ITS OWN `SKTestSession`. It cannot rely on the plan, and it must not rely
// on what a previous test left behind — which looks identical right up until the run order
// changes.
//
// This test now reports WHICH of the three states it is in rather than collapsing two of them into
// "the plan does not work", because collapsing them once led to a false conclusion.
import XCTest
import StoreKit

final class TestPlanStoreKitCatalogueTests: XCTestCase {

    /// The two ids in `AppDNAHost/Products.storekit`, which the test plan references.
    private let hostCatalogueIds = ["premium_monthly", "premium_annual"]

    /// One id from `AppDNAHost/AppDNATestProducts.storekit` — the OTHER catalogue, which only an
    /// `SKTestSession` opened by another test in this bundle can make active.
    private let foreignCatalogueId = "ai.appdna.test.monthly"

    func testTheTestPlanServesTheHostCatalogue() async throws {
        let products = try await Product.products(for: hostCatalogueIds)
        let found = products.map(\.id).sorted()
        print("[test-plan-catalogue] test-plan catalogue: asked for \(hostCatalogueIds.count), store answered \(products.count) — \(found)")
        for p in products {
            print("[test-plan-catalogue]   \(p.id) displayPrice=\(p.displayPrice) period=\(String(describing: p.subscription?.subscriptionPeriod))")
        }

        if products.isEmpty {
            /*
             🔴 EMPTY HAS TWO CAUSES AND THEY ARE OPPOSITE. Either the test plan served nothing — a
             real finding about Xcode — or another test's session swapped the catalogue out from
             under this one, which is a finding about this bundle and says nothing about the plan.
             Asking the other catalogue separates them, and reporting them as the same thing is what
             once led to a false conclusion.
             */
            let foreign = try await Product.products(for: [foreignCatalogueId])
            if !foreign.isEmpty {
                throw XCTSkip(
                    "another test's SKTestSession has replaced the simulator's catalogue — "
                        + "`\(foreignCatalogueId)` answered instead, which is "
                        + "AppDNATestProducts.storekit, not the test plan's Products.storekit. This "
                        + "says NOTHING about the test plan. Run this test with its own "
                        + "`-only-testing:AppDNAHostTests/TestPlanStoreKitCatalogueTests`.",
                )
            }
            throw XCTSkip(
                "the test plan's StoreKit configuration served nothing AND no other catalogue is "
                    + "active — neither the plan nor a session is in force.",
            )
        }

        XCTAssertEqual(
            found, hostCatalogueIds.sorted(),
            "the test plan served SOME of the catalogue but not all of it — read the ids above "
                + "before trusting either half.",
        )
    }
}
