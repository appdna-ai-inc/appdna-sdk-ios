// TabGroupsRenderTests.swift
//
// Does `plan_display_style: "tab_groups"` draw something OTHER than the default stack?
//
// 🔴 THAT COMPARISON *IS* THE DEFECT. The console has offered this style in its picker since it
// shipped and neither renderer had a case for it, so `tab_groups` fell through
// `switch displayStyle`'s `default` and rendered the vertical stack — no error, no warning, no
// blank screen, just the wrong layout. So "it renders" is not the claim; "it renders DIFFERENTLY
// FROM THE DEFAULT" is, and before this change the two were pixel-identical.
//
// 🔴 PIXELS, NOT THE ACCESSIBILITY TREE. `StorePriceRenderTests` already paid for that lesson in
// this target: reading `accessibilityLabel` off a hosted view comes back EMPTY, because SwiftUI
// builds that tree lazily and a hostless test with no VoiceOver never triggers it — an absence
// assertion passed against a view the harness could not read at all. Renders are compared instead,
// which `SurfaceSnapshotTests` proves this target can produce.
//
// The plans live under `layout.sections[].config.plans`, where a real paywall keeps them —
// a fixture that put them at the root would pass against code that reaches no real paywall.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

final class TabGroupsRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    override func setUpWithError() throws {
        try super.setUpWithError()
        /*
         🔴 A WARM-UP RENDER, because the FIRST render in a process differs from every later one —
         font and layer caches are cold. Without it an equality assertion passes alone and fails
         inside the full class, which is the worst possible failure mode: green in isolation, red
         in CI, and nothing in the diff to explain it.
        */
        _ = try? renderPNG(try config(style: "vertical_stack", defaultPlanIndex: 0))
    }

    /// A paywall whose plans section carries `style`, with `defaultPlanIndex` pre-selected.
    private func config(style: String, defaultPlanIndex: Int) throws -> PaywallConfig {
        let plans: [[String: Any]] = (0..<2).map { i in
            [
                "id": i == 0 ? "plan_annual" : "plan_monthly",
                "product_id": i == 0 ? "app.premium.annual" : "app.premium.monthly",
                "label": i == 0 ? "Annual" : "Monthly",
                "price_display": i == 0 ? "$49.99" : "$5.99",
                "is_default": i == defaultPlanIndex,
                "sort_order": i,
            ]
        }
        let doc: [String: Any] = [
            "id": "pw_tab_groups",
            "name": "Tab groups",
            "placement": "onboarding",
            "version": 1,
            "layout": [
                "type": "stack",
                "sections": [[
                    "id": "sec_plans",
                    "type": "plans",
                    "config": ["plan_display_style": style, "plans": plans],
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        return try JSONDecoder().decode(PaywallConfig.self, from: data)
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

    // MARK: - The claim

    func testTabGroupsDrawsSomethingOtherThanTheDefaultStack() throws {
        let tabs = try renderPNG(try config(style: "tab_groups", defaultPlanIndex: 0))
        let stack = try renderPNG(try config(style: "vertical_stack", defaultPlanIndex: 0))
        XCTAssertNotEqual(
            tabs, stack,
            "`tab_groups` rendered pixel-identically to `vertical_stack`, which is exactly what the defect "
            + "was: the value fell through the switch's default arm and the author's chosen layout "
            + "never happened"
        )
    }

    /**
     The selection is honoured — but 🔴 THIS ONE DOES NOT DISCRIMINATE, and the red control proved it.

     With the `tab_groups` arm disabled, `testTabGroupsDrawsSomethingOtherThanTheDefaultStack` failed
     with byte-identical renders while THIS test still passed: the vertical stack also draws the
     selected plan differently from an unselected one, so flipping `is_default` changes the render in
     either layout. Kept because "the panel follows the selection" is still worth pinning, and
     labelled so nobody reads it as evidence that the tab bar works.

     What proves the tab bar specifically: the inequality above on iOS, and on Android
     `TabGroupsRenderTest` — which asserts the unselected plan's card is ABSENT and that a
     `performClick` on a tab swaps the body, both of which go red against the stack.
    */
    func testTheSELECTEDTabDecidesWhichPlanIsShownBeneath() throws {
        let annualSelected = try renderPNG(try config(style: "tab_groups", defaultPlanIndex: 0))
        let monthlySelected = try renderPNG(try config(style: "tab_groups", defaultPlanIndex: 1))
        XCTAssertNotEqual(
            annualSelected, monthlySelected,
            "the panel beneath the tabs did not follow the selection — a tab bar whose body never "
            + "changes is the familiar shape: a control that draws and does nothing"
        )
    }

    /**
     THE CONTROL, and the two assertions above mean nothing without it.

     Both are inequalities, and a harness that renders NOISE — a different timestamp, an animation
     mid-flight, an uninitialised buffer — satisfies an inequality every time. This renders the
     SAME config twice and requires the bytes to match, so an inequality above is a real difference
     in what was drawn rather than non-determinism in how it was captured.
    */
    func testTwoRendersOfTheSameConfigAreIdentical_control() throws {
        let a = try renderPNG(try config(style: "tab_groups", defaultPlanIndex: 0))
        let b = try renderPNG(try config(style: "tab_groups", defaultPlanIndex: 0))
        XCTAssertEqual(a, b, "the harness is not deterministic, so neither inequality above is evidence")
    }
}
