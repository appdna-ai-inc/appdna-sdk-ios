// StorePriceLookupSessionTests.swift — #923
//
// The link the fixture cannot reach: `StorePriceLookup` against a LIVE StoreKit.
//
// `billing/store_price_substitution` pins what the renderer does with a price once it has one, on
// both platforms. What it cannot pin is the half before that — that the SDK really asks StoreKit,
// really gets the catalogue back, and really maps product id → localized display price. Nothing
// but a live store can answer that, and the paywall's UI test cannot: a simulator launched by a
// scheme serves no catalogue on this bridge (#934), measured at `store:0` with a direct
// `Product.products(for:)` probe.
//
// `SKTestSession` can, in THIS target, over `AppDNATestProducts.storekit` — the same mechanism
// `StoreKitSessionTests` already uses for the purchase path. So the chain is:
//
//     real StoreKit  →  StorePriceLookup  →  (here)  →  StorePriceSubstitution  →  displayPrice
//                                                       ^^^^^^^^^^^^^^^^^^^^^^ the shared fixture
//
// What remains unproven is only the pixel, and that is #934's to unblock.
import XCTest
import StoreKit
import StoreKitTest
@testable import AppDNASDK

final class StorePriceLookupSessionTests: XCTestCase {

    private var session: SKTestSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let url = Bundle.module.url(forResource: "AppDNATestProducts", withExtension: "storekit") else {
            throw XCTSkip("AppDNATestProducts.storekit is not in the test bundle")
        }
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            throw XCTSkip("SKTestSession cannot run in this (hostless) test target: \(error)")
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session?.clearTransactions()
        super.tearDown()
    }

    /// Always calls back exactly once, so a test can await it without a chance of hanging.
    private func lookup(_ ids: [String], timeout: TimeInterval = 10) -> [String: String] {
        var result: [String: String] = [:]
        let done = expectation(description: "store price lookup")
        StorePriceLookup.prices(for: ids, timeout: timeout) { prices in
            result = prices
            done.fulfill()
        }
        wait(for: [done], timeout: timeout + 5)
        return result
    }

    func testItReturnsTheStoresOwnPriceForEachProduct() throws {
        let prices = lookup(["ai.appdna.test.monthly", "ai.appdna.test.lifetime"])

        XCTAssertEqual(prices.count, 2, "both products are in the catalogue — got \(prices)")
        // A SUBSCRIPTION and an IN-APP product, because the two come back through different
        // queries on Android and a lookup that asks only one way loses half a paywall's prices.
        XCTAssertEqual(prices["ai.appdna.test.monthly"]?.contains("9.99"), true, "got \(prices)")
        XCTAssertEqual(prices["ai.appdna.test.lifetime"]?.contains("4.99"), true, "got \(prices)")
    }

    /// The whole point of the feature, asserted on the value the renderer reads.
    func testTheRenderedPriceIsTheStoresAndNotTheAuthoredOne() throws {
        let prices = lookup(["ai.appdna.test.monthly"])
        let storePrice = try XCTUnwrap(prices["ai.appdna.test.monthly"])

        let shown = StorePriceSubstitution.resolve(
            authoredPrice: "AUTHORED-11.11",
            productId: "ai.appdna.test.monthly",
            useStorePrice: nil,
            storePrice: storePrice
        )
        XCTAssertEqual(shown.priceDisplay, storePrice)
        XCTAssertEqual(shown.source, "store")
        XCTAssertNotEqual(shown.priceDisplay, "AUTHORED-11.11", "the authored price must not survive")
    }

    /// The opt-out beats a store that answered — the one case where an author overrules the store.
    func testAnOptedOutPlanKeepsItsAuthoredPrice() throws {
        let prices = lookup(["ai.appdna.test.monthly"])
        let storePrice = try XCTUnwrap(prices["ai.appdna.test.monthly"])

        let shown = StorePriceSubstitution.resolve(
            authoredPrice: "was $19.99",
            productId: "ai.appdna.test.monthly",
            useStorePrice: false,
            storePrice: storePrice
        )
        XCTAssertEqual(shown.priceDisplay, "was $19.99")
        XCTAssertEqual(shown.source, "authored_opt_out")
    }

    /// A product this catalogue does not hold is absent rather than empty-stringed, which is the
    /// signal `StorePriceSubstitution` reads as "fall back".
    func testAnUnknownProductIsSimplyAbsent() throws {
        let prices = lookup(["ai.appdna.test.monthly", "no.such.product.at.all"])

        XCTAssertNotNil(prices["ai.appdna.test.monthly"])
        XCTAssertNil(prices["no.such.product.at.all"], "got \(prices)")

        let shown = StorePriceSubstitution.resolve(
            authoredPrice: "$9.99",
            productId: "no.such.product.at.all",
            useStorePrice: nil,
            storePrice: prices["no.such.product.at.all"]
        )
        XCTAssertEqual(shown.priceDisplay, "$9.99")
        XCTAssertEqual(shown.source, "authored_lookup_failed")
    }

    /// 🔴 The deadline, which is the difference between a slow network and a paywall that never
    /// appears. A timeout below any possible round trip must still CALL BACK, and must do it once.
    func testAnImpossibleDeadlineStillAnswersExactlyOnce() {
        var calls = 0
        let done = expectation(description: "answered")
        done.assertForOverFulfill = true
        StorePriceLookup.prices(for: ["ai.appdna.test.monthly"], timeout: 0.001) { prices in
            calls += 1
            XCTAssertTrue(prices.isEmpty, "a deadline that fired first must answer empty, got \(prices)")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls, 1)
    }

    func testNoProductIdsIsNotAStoreCall() {
        XCTAssertTrue(lookup([]).isEmpty)
        XCTAssertTrue(lookup(["", "   "]).isEmpty)
    }
}
