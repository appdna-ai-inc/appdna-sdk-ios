// StorePriceRenderTests.swift — #923
//
// DOES THE PRICE ON THE SCREEN COME FROM THE STORE? Rendered, and read back.
//
// 🔴 Why this file exists. The shared fixture pins the substitution, and
// `StorePriceLookupSessionTests` pins the lookup against a live StoreKit — but neither of them
// DRAWS anything, and #923 is a claim about what a user sees. The obvious instrument, a UI test
// tapping the host app, cannot answer it on this bridge: a simulator launched through a scheme
// serves no StoreKit catalogue, measured at `store:0` with a direct `Product.products(for:)`
// probe, and every documented way of attaching one was tried and ruled out (#934).
//
// `SKTestSession` DOES work in this target. And `SurfaceSnapshotTests` already renders a real
// `PaywallRenderer` in a real key window. Putting the two together gives the missing link:
//
//     live StoreKit  →  StorePriceLookup  →  the presenter's own substitution  →  PaywallRenderer
//                                                                                 →  what it DREW
//
// What is read back is the ACCESSIBILITY TREE — what the view publishes as its text. That is the
// same surface VoiceOver reads and a UI test queries, so a price that appears there is a price
// that was drawn.
//
// 🔴 EVERY ASSERTION HAS ITS NEGATIVE CONTROL IN THE SAME TEST. "The authored price is absent"
// proves nothing unless the same harness can SEE an authored price when one is shown — otherwise
// an empty tree passes. So each case renders both ways and compares.
import XCTest
import SwiftUI
import UIKit
import StoreKit
import StoreKitTest
@testable import AppDNASDK

@MainActor
final class StorePriceRenderTests: XCTestCase {

    private var session: SKTestSession!
    private let size = CGSize(width: 393, height: 852)

    /// The catalogue's monthly subscription, and what it costs there.
    private let productId = "ai.appdna.test.monthly"
    private let storeAmount = "9.99"
    private let authored = "AUTHORED-11.11"

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

    // MARK: - The paywall under test

    /// One plans section, one plan, naming a product the catalogue holds and a price it does not.
    private func config(useStorePrice: Bool?, price: String? = nil) throws -> PaywallConfig {
        let optOut = useStorePrice.map { ", \"use_store_price\": \($0)" } ?? ""
        let authored = price ?? self.authored
        let json = """
        {
          "id": "render_store_price",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Go Premium" } },
              { "type": "plans", "config": { "plans": [
                  { "product_id": "\(productId)", "label": "Monthly",
                    "price_display": "\(authored)", "is_default": true\(optOut) }
              ] } },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// The production path, called by name — not a re-implementation of it.
    ///
    /// 🔴 The first version of this helper copied what `PaywallManager.present` did at the time
    /// (map the ROOT plans array) and so reproduced its bug instead of catching it. A test that
    /// re-implements the thing under test can only ever agree with it; calling
    /// `PaywallConfig.applyingStorePrices` means the renderer here sees exactly what a device sees.
    private func applyingStorePrices(to config: PaywallConfig, _ prices: [String: String]) -> PaywallConfig {
        config.applyingStorePrices(prices)
    }

    private func lookup(_ ids: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let done = expectation(description: "store price lookup")
        StorePriceLookup.prices(for: ids, timeout: 10) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 15)
        return result
    }

    // MARK: - Rendering, and comparing what was drawn

    /*
     🔴 PIXELS, NOT THE ACCESSIBILITY TREE — and the first version of this file is why.

     Reading `accessibilityLabel` off the hosted view came back EMPTY (`Drew: []`): SwiftUI builds
     that tree lazily and a hostless test with no VoiceOver never triggers it. The negative control
     written beside the real assertion is what caught it — "the authored price is absent" passed
     for the worst possible reason, a view the harness could not read at all.

     So the comparison is between RENDERS, which `SurfaceSnapshotTests` already proves this target
     can produce (`layer.render(in:)` on a hosted view inside a real key window):

         A   price_display "AUTHORED-11.11", the store's answer APPLIED
         B   price_display set to the store's own string, nothing applied
         C   price_display "AUTHORED-11.11", nothing applied

     A == B says what was drawn IS the store's price, to the pixel. A != C says applying the store
     changed the screen. Together they are the claim, and a blank render cannot satisfy both —
     it would make A == C and fail the second.
    */
    private func renderPNG(_ config: PaywallConfig) throws -> Data {
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)

        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        return try XCTUnwrap(image.pngData())
    }

    // MARK: - The claim

    func testThePriceDrawnIsTheStoresAndNotTheAuthoredOne() throws {
        let prices = lookup([productId])
        let storePrice = try XCTUnwrap(prices[productId], "the catalogue must serve \(productId)")
        XCTAssertTrue(storePrice.contains(storeAmount), "the store's price should be \(storeAmount), got \(storePrice)")

        let applied = try renderPNG(applyingStorePrices(to: try config(useStorePrice: nil), prices))
        let authoredOnly = try renderPNG(try config(useStorePrice: nil))
        let storeStringAuthored = try renderPNG(try config(useStorePrice: nil, price: storePrice))

        XCTAssertNotEqual(
            applied, authoredOnly,
            "applying the store's answer must CHANGE the screen — if these two renders are "
            + "identical the paywall is still drawing \(authored)"
        )
        XCTAssertEqual(
            applied, storeStringAuthored,
            "what was drawn must be pixel-identical to a paywall that simply authors \(storePrice) "
            + "— that is what 'the price on the screen came from the store' means"
        )
    }

    /// The author's opt-out, drawn: `use_store_price: false` keeps the typed price on screen even
    /// though the store answered.
    func testAnOptedOutPlanDrawsTheAuthoredPrice() throws {
        let prices = lookup([productId])
        XCTAssertNotNil(prices[productId], "the catalogue must serve \(productId)")

        let optedOut = try renderPNG(applyingStorePrices(to: try config(useStorePrice: false), prices))
        let authoredOnly = try renderPNG(try config(useStorePrice: nil))
        let storeStringAuthored = try renderPNG(try config(useStorePrice: nil, price: prices[productId]!))

        XCTAssertEqual(optedOut, authoredOnly, "an opted-out plan must draw exactly what the author typed")
        XCTAssertNotEqual(optedOut, storeStringAuthored, "an opted-out plan must NOT draw the store's price")
    }

    /// The fallback, drawn: the store knows nothing, so the authored price is what a user reads.
    func testAFailedLookupDrawsTheAuthoredPrice() throws {
        let fellBack = try renderPNG(applyingStorePrices(to: try config(useStorePrice: nil), [:]))
        let authoredOnly = try renderPNG(try config(useStorePrice: nil))
        XCTAssertEqual(fellBack, authoredOnly, "with no store answer the paywall must draw the authored price")
    }
}
