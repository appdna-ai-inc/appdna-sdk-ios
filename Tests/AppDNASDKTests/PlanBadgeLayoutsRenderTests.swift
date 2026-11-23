// PlanBadgeLayoutsRenderTests.swift
//
// `pill_selector`, `segmented_toggle` and
// `product_as_cta` draw a plan's badge. Before this change iOS drew it in none of the three, so an
// author's "Best value" reached Android users on a pill selector and nobody on the other two.
//
// 🔴 PIXELS, NOT THE ACCESSIBILITY TREE — the lesson `StorePriceRenderTests` and `TabGroupsRenderTests`
// paid for: a hostless render's accessibility tree comes back empty, so an absence assertion passes
// against a view the harness cannot read. The badge here is filled with a colour nothing else on the
// paywall uses (pure green), and the render is searched for it: present where a badge is authored, and
// on the side of the screen its plan (or its `badge_position`) puts it.
//
// The plans live under `layout.sections[].config.plans`, where a real paywall keeps them.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

final class PlanBadgeLayoutsRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)
    private static let badgeGreen = "#00FF00"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A warm-up render: the first render in a process differs from every later one (cold caches).
        _ = try? render(try config(style: "vertical_stack", badges: [nil, nil]))
    }

    private func config(style: String, badges: [String?], position: String? = nil) throws -> PaywallConfig {
        let plans: [[String: Any]] = badges.enumerated().map { i, badge in
            var p: [String: Any] = [
                "id": i == 0 ? "plan_annual" : "plan_monthly",
                "product_id": i == 0 ? "app.premium.annual" : "app.premium.monthly",
                "label": i == 0 ? "Annual" : "Monthly",
                "price_display": i == 0 ? "$49.99" : "$5.99",
                "is_default": i == 0,
                "sort_order": i,
            ]
            if let badge { p["badge"] = badge }
            return p
        }
        var sectionConfig: [String: Any] = [
            "plan_display_style": style,
            "plans": plans,
            "badge_bg_color": Self.badgeGreen,
            "badge_text_color": "#00FF00",
        ]
        if let position { sectionConfig["badge_position"] = position }
        let doc: [String: Any] = [
            "id": "pw_plan_badge_\(style)",
            "name": "Plan badge",
            "placement": "onboarding",
            "version": 1,
            "layout": [
                "type": "stack",
                "sections": [["id": "sec_plans", "type": "plans", "config": sectionConfig]],
            ],
        ]
        return try JSONDecoder().decode(PaywallConfig.self, from: try JSONSerialization.data(withJSONObject: doc))
    }

    private func render(_ config: PaywallConfig) throws -> UIImage {
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)

        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
    }

    /// The badge-green pixels in a render: how many, and the mean x of them (nil when none).
    private func green(_ image: UIImage) throws -> (count: Int, meanX: Double?) {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        var sumX = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if buf[i] < 40 && buf[i + 1] > 215 && buf[i + 2] < 40 { n += 1; sumX += x }
            }
        }
        return (n, n > 0 ? Double(sumX) / Double(n) : nil)
    }

    // MARK: - Controls

    /// NEGATIVE CONTROL: no badge authored → no badge-green anywhere. Without this, "green is present"
    /// could be the harness seeing the colour somewhere a badge is not.
    func testNoBadgeAuthoredDrawsNoBadgeGreen_control() throws {
        for style in ["pill_selector", "segmented_toggle", "product_as_cta"] {
            XCTAssertEqual(try green(try render(try config(style: style, badges: [nil, nil]))).count, 0, style)
        }
    }

    /// POSITIVE CONTROL: a card layout, which has always drawn badges, is seen by this harness. Without
    /// it, "no green" below could mean the harness cannot see a badge at all.
    func testTheHarnessSeesACardBadge_control() throws {
        XCTAssertGreaterThan(try green(try render(try config(style: "vertical_stack", badges: ["Best value", nil]))).count, 20)
    }

    /// A blank badge is not a badge: the layouts draw nothing for it, as Android does.
    func testABlankBadgeDrawsNothing() throws {
        for style in ["pill_selector", "segmented_toggle", "product_as_cta"] {
            XCTAssertEqual(try green(try render(try config(style: style, badges: ["   ", nil]))).count, 0, style)
        }
    }

    // MARK: - The claim, per layout

    /// 🔴 pill_selector: the badge is drawn in the first (badged) pill, on the left of the row.
    func testPillSelectorDrawsTheBadgeInItsPill() throws {
        let g = try green(try render(try config(style: "pill_selector", badges: ["Best value", nil])))
        XCTAssertGreaterThan(g.count, 20, "pill_selector drew no badge")
        XCTAssertLessThan(try XCTUnwrap(g.meanX), size.width / 2, "the badge is not in the first pill")
    }

    /// 🔴 segmented_toggle: the badge is centred over its own segment — the left one for plan 0, the
    /// right one for plan 1.
    func testSegmentedToggleDrawsTheBadgeOverItsSegment() throws {
        let left = try green(try render(try config(style: "segmented_toggle", badges: ["Best value", nil])))
        XCTAssertGreaterThan(left.count, 20, "segmented_toggle drew no badge")
        XCTAssertLessThan(try XCTUnwrap(left.meanX), size.width / 2)
        let right = try green(try render(try config(style: "segmented_toggle", badges: [nil, "Save 40%"])))
        XCTAssertGreaterThan(try XCTUnwrap(right.meanX), size.width / 2, "the badge is not over the second segment")
    }

    /// 🔴 product_as_cta: the badge straddles the button at `badge_position` — right by default, left
    /// for top-left — and inline draws it too.
    func testProductAsCTADrawsTheBadgeAtItsPosition() throws {
        let right = try green(try render(try config(style: "product_as_cta", badges: ["Best value", nil])))
        XCTAssertGreaterThan(right.count, 20, "product_as_cta drew no badge")
        XCTAssertGreaterThan(try XCTUnwrap(right.meanX), size.width / 2, "default top_right is not on the right")
        let left = try green(try render(try config(style: "product_as_cta", badges: ["Best value", nil], position: "top-left")))
        XCTAssertLessThan(try XCTUnwrap(left.meanX), size.width / 2, "top-left is not on the left")
        let inline = try green(try render(try config(style: "product_as_cta", badges: ["Best value", nil], position: "inline")))
        XCTAssertGreaterThan(inline.count, 20, "an inline badge was not drawn")
    }
}
