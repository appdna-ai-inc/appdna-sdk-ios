// PlanOrderRenderTests.swift — #1097
//
// DOES THE AUTHORED RANK DECIDE THE ORDER THE PLANS DRAW IN? Rendered, and compared.
//
// 🔴 Why this file exists. `PaywallPlanOrder.sorted` is named for "the order a paywall's plans
// draw in", and the shared fixture `resolve_plan_order` pins it — by calling it DIRECTLY. That
// proves the sorter sorts and cannot see whether anything calls it, which is how #1097 happened:
// the sort was wired into `selectedPlan` and `onAppear`, both of which look a plan up BY ID where
// order is irrelevant by construction, and not into `case "plans":`, the one site that draws.
// Deleting the call at every site left the fixture green.
//
// So the claim has to be measured where it is made — on the rows. The technique is the one
// `StorePriceRenderTests` established for #923, for the reason recorded there: reading
// `accessibilityLabel` off a hosted view in this target comes back EMPTY, because SwiftUI builds
// that tree lazily and a hostless test never triggers it. Renders are compared instead.
//
//     A   plans authored [alpha, bravo], ranked so BRAVO is first
//     B   plans authored [bravo, alpha], no rank at all
//     C   plans authored [alpha, bravo], no rank at all
//
// A == B says the rank decided what was drawn: the screen is identical to one that simply authored
// the plans in that order. A != C says honouring the rank CHANGED the screen, and is also the
// harness's own negative control — a blank or orderless render would make A == C and fail it.
// Neither assertion is worth anything alone, which is the lesson of #923's empty tree.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PlanOrderRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    /// A plan, as a published document carries one. `rank` nil omits `sort_order` entirely, which
    /// is the common shape and the one `sorted` must leave alone.
    private struct Plan {
        let id: String
        let label: String
        let price: String
        var rank: Int?
    }

    /*
     🔴 ALPHA IS ALWAYS `is_default`, AND THAT IS LOAD-BEARING — the first version of this file
     omitted it and its negative control passed for the wrong reason.

     `onAppear` resolves the default selection from the SORTED array (`plans.first(where: isDefault)
     ?? plans.first`). With no plan marked default, "first" is a different plan depending on whether
     the rank was applied — so two renders differed by which row was HIGHLIGHTED, and
     `XCTAssertNotEqual` passed while the row ORDER was still wrong. Pinning the default to the same
     plan in every render makes order the only variable left, which is the claim.
    */
    private let alpha = Plan(id: "plan_alpha", label: "Alpha", price: "$1.11")
    private let bravo = Plan(id: "plan_bravo", label: "Bravo", price: "$2.22")

    /// One plans section holding `plans` in the order given, drawn as a vertical stack so the
    /// rows' order is the picture.
    private func config(_ plans: [Plan]) throws -> PaywallConfig {
        let rows = plans.map { p -> String in
            let rank = p.rank.map { ", \"sort_order\": \($0)" } ?? ""
            // Alpha is the default in EVERY render, so the highlight cannot move between them and
            // the only thing left that can differ is the order the rows draw in.
            let isDefault = p.id == alpha.id
            return """
            { "product_id": "\(p.id)", "label": "\(p.label)", "price_display": "\(p.price)", \
            "is_default": \(isDefault)\(rank) }
            """
        }.joined(separator: ",\n")
        let json = """
        {
          "id": "render_plan_order",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Choose a plan" } },
              { "type": "plans", "config": { "plan_display_style": "vertical_stack", "plans": [
                  \(rows)
              ] } },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// A real `PaywallRenderer` in a real key window, rendered to pixels — the same harness
    /// `SurfaceSnapshotTests` and `StorePriceRenderTests` use.
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

    /// An authored rank that contradicts the array's own order must decide what is drawn.
    func testTheAuthoredRankDecidesTheOrderThePlansDrawIn() throws {
        // Authored alpha-then-bravo, ranked bravo-then-alpha.
        var a = alpha; a.rank = 1
        var b = bravo; b.rank = 0
        let ranked = try renderPNG(try config([a, b]))

        // The same screen, authored in that order with no rank to apply.
        let preSorted = try renderPNG(try config([bravo, alpha]))

        // The same plans, no rank, in the array's own order.
        let asAuthored = try renderPNG(try config([alpha, bravo]))

        XCTAssertNotEqual(
            ranked, asAuthored,
            "honouring `sort_order` must CHANGE the screen — if these two renders are identical "
            + "the rank was dropped and the plans drew in serialisation order (#1097). This is "
            + "also this harness's negative control: a render that cannot show order at all makes "
            + "these equal."
        )
        XCTAssertEqual(
            ranked, preSorted,
            "what was drawn must be pixel-identical to a paywall that simply authors the plans in "
            + "the ranked order — that is what 'the rank decided the drawing order' means"
        )
    }

    /// A paywall with a ROOT `cta` and NO `cta` section — the arm that ignored the per-plan label.
    ///
    /// `rootCtaText` is the top-level button text; `planCtaText`, when given, is the selected plan's
    /// own override. The plans section carries no CTA, so this exercises
    /// `} else if let cta = config.cta {` rather than the section arm.
    private func rootCtaConfig(rootCtaText: String, planCtaText: String?) throws -> PaywallConfig {
        let planCta = planCtaText.map { ", \"cta_text\": \"\($0)\"" } ?? ""
        let json = """
        {
          "id": "render_root_cta",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "plans", "config": { "plan_display_style": "vertical_stack", "plans": [
                  { "product_id": "plan_alpha", "label": "Alpha", "price_display": "$1.11",
                    "is_default": true\(planCta) }
              ] } }
            ]
          },
          "cta": { "text": "\(rootCtaText)" }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// 🔴 #1081 — THE ROOT CTA DRAWS THE SELECTED PLAN'S OWN LABEL, which it did not before.
    ///
    /// The section arm resolved `selectedPlanCtaText ?? topLevelText ?? sectionText`; this arm read
    /// `cta.text ?? "Continue"`, so the same authored `plans[].cta_text` worked or did nothing
    /// depending on whether the layout happened to contain a `cta` section. Android never had the
    /// split — it synthesises a `__root_cta__` section so both cases share one chain.
    ///
    /// It matters for #1081: a tap that drifts far enough for the scroll view to claim it leaves the
    /// selection alone, and the CTA then buys the plan chosen BEFORE it with nothing on screen naming
    /// what is about to be bought. A CTA reading "Start Annual" is what makes that visible first.
    func testTheRootCTADrawsTheSelectedPlansOwnLabel() throws {
        let planOverride = try renderPNG(try rootCtaConfig(rootCtaText: "GENERIC", planCtaText: "Start Alpha"))
        let authoredAtRoot = try renderPNG(try rootCtaConfig(rootCtaText: "Start Alpha", planCtaText: nil))
        let genericOnly = try renderPNG(try rootCtaConfig(rootCtaText: "GENERIC", planCtaText: nil))

        XCTAssertNotEqual(
            planOverride, genericOnly,
            "a plan's own `cta_text` must CHANGE the root CTA — if these two renders are identical "
                + "the per-plan label was dropped, which is what #1081's fix is about. This is also "
                + "the harness's negative control: a render that cannot show the label at all makes "
                + "these equal."
        )
        XCTAssertEqual(
            planOverride, authoredAtRoot,
            "what the root CTA drew must be pixel-identical to a paywall that simply authors that "
                + "text at the top level — that is what 'the per-plan label reached the button' means"
        )
    }

    /// The common shape, pinned so the fix cannot reorder anything that does not ask to be
    /// reordered: no plan carries a rank, so the array's own order is the drawing order.
    func testPlansWithNoAuthoredRankDrawInTheArrayOrder() throws {
        let forwards = try renderPNG(try config([alpha, bravo]))
        let backwards = try renderPNG(try config([bravo, alpha]))
        XCTAssertNotEqual(
            forwards, backwards,
            "with no `sort_order` anywhere, the array's order IS the drawing order — these two "
            + "must differ, or the renderer is imposing an order of its own"
        )
    }
}
