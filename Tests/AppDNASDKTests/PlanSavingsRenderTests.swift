// PlanSavingsRenderTests.swift
//
// DOES THE SAVINGS BADGE AGREE WITH THE PRICES DRAWN BESIDE IT? Rendered, and compared.
//
// The shared fixture `billing/plan_savings_percent` pins the arithmetic. This file pins the claim a
// user sees: live StoreKit → `StorePriceLookup.facts` → the presenter's own `applyingStoreFacts` →
// `PaywallRenderer` → the pixels it drew.
//
// The catalogue serves the annual plan at 79.99 and the monthly at 9.99; the paywall AUTHORS 39.99
// and 6.99, which give 52%. At the store's prices the saving is 1 − 79.99 / (9.99 × 12) = 33.27%.
//
//     A   badge "Save {{savings_percent}}", the store's answer APPLIED
//     B   badge "Save 33%" typed literally, the store's answer applied
//     C   badge "Save 52%" typed literally, the store's answer applied — the defect as it shipped
//
// A == B says the figure drawn is the one the drawn prices give, to the pixel. A != C is the
// negative control: the harness can SEE a wrong figure, so A == B is not a blank render agreeing
// with itself.
import XCTest
import SwiftUI
import UIKit
import StoreKit
import StoreKitTest
@testable import AppDNASDK

@MainActor
final class PlanSavingsRenderTests: XCTestCase {

    private var session: SKTestSession!
    private let size = CGSize(width: 393, height: 852)
    private let annual = "ai.appdna.test.annual"
    private let monthly = "ai.appdna.test.monthly"

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

    private func config(badge: String) throws -> PaywallConfig {
        let json = """
        {
          "id": "render_plan_savings",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Go Premium" } },
              { "type": "plans", "config": { "plans": [
                  { "product_id": "\(annual)", "label": "Premium Annual", "price_display": "$39.99",
                    "is_default": true, "badge": "\(badge)" },
                  { "product_id": "\(monthly)", "label": "Premium Monthly", "price_display": "$6.99",
                    "is_default": false }
              ] } },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    private func facts() -> [String: StorePriceLookup.StoreFacts] {
        var result: [String: StorePriceLookup.StoreFacts] = [:]
        let done = expectation(description: "store facts")
        StorePriceLookup.facts(for: [annual, monthly], timeout: 10) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 15)
        return result
    }

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

    /// The store hands back a NUMBER beside the localized string, or there is nothing to compute on.
    func testTheStoreLookupCarriesTheNumericPrice() throws {
        let f = facts()
        XCTAssertEqual(try XCTUnwrap(f[annual]?.amount), 79.99, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f[monthly]?.amount), 9.99, accuracy: 0.0001)
        XCTAssertEqual(f[annual]?.periodIso, "P1Y")
    }

    func testTheBadgeDrawnAgreesWithTheStorePricesDrawn() throws {
        let f = facts()
        XCTAssertNotNil(f[annual]?.price, "the catalogue must serve \(annual)")
        XCTAssertNotNil(f[monthly]?.price, "the catalogue must serve \(monthly)")

        let token = try config(badge: "Save {{savings_percent}}").applyingStoreFacts(f)
        let annualPlan = token.sections.first(where: { $0.type == "plans" })?.data?.plans?.first
        XCTAssertEqual(annualPlan?.badge, "Save 33%", "79.99 a year against 9.99 a month is a 33% saving")

        let computed = try renderPNG(token)
        let literalRight = try renderPNG(try config(badge: "Save 33%").applyingStoreFacts(f))
        let literalStale = try renderPNG(try config(badge: "Save 52%").applyingStoreFacts(f))

        XCTAssertEqual(computed, literalRight, "the badge must draw the figure the drawn prices give, to the pixel")
        XCTAssertNotEqual(computed, literalStale,
                          "negative control: the authored-price figure must look DIFFERENT, or this harness sees nothing")
    }

    /// The store knows nothing: the authored prices are drawn, and the badge follows them.
    func testAFailedLookupFillsTheBadgeFromTheAuthoredPrices() throws {
        let drawn = try config(badge: "Save {{savings_percent}}").applyingStoreFacts([:])
        let annualPlan = drawn.sections.first(where: { $0.type == "plans" })?.data?.plans?.first
        XCTAssertEqual(annualPlan?.badge, "Save 52%")
        XCTAssertEqual(try renderPNG(drawn), try renderPNG(try config(badge: "Save 52%").applyingStoreFacts([:])))
    }
}
