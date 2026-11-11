// PlanSavingsTests.swift
//
// `{{savings_percent}}` in a TRANSLATION. The renderer's `loc` interpolates every `{{…}}` through
// `TemplateEngine`, which knows no `savings_percent` and blanks it, so a translated
// "Spare {{savings_percent}}" would draw "Spare ". `applyingSavings` fills the plan-text
// localizations against the list the renderer draws, in the order it draws it.
import XCTest
@testable import AppDNASDK

final class PlanSavingsTests: XCTestCase {

    private func config(_ localizations: String) throws -> PaywallConfig {
        let json = """
        {
          "id": "plan_savings_loc",
          "localizations": \(localizations),
          "layout": { "type": "stack", "sections": [
            { "type": "plans", "config": { "plans": [
              { "product_id": "m", "label": "Monthly", "price_display": "$6.99", "sort_order": 1 },
              { "product_id": "y", "label": "Annual", "price_display": "$39.99", "sort_order": 0,
                "badge": "Save {{savings_percent}}" }
            ] } }
          ] }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    func testATranslatedBadgeIsFilledAgainstTheDrawnOrder() throws {
        // Drawn order is sort_order: annual (index 0), monthly (index 1).
        let out = try config(#"{"de": {"plan.0.badge": "Spare {{savings_percent}}", "plan.1.badge": "Spare {{savings_percent}}", "cta.text": "Weiter"}}"#)
            .applyingSavings()
        XCTAssertEqual(out.localizations?["de"]?["plan.0.badge"], "Spare 52%")
        // The monthly plan saves nothing: its translation is dropped rather than drawn as "Spare ".
        XCTAssertNil(out.localizations?["de"]?["plan.1.badge"])
        XCTAssertEqual(out.localizations?["de"]?["cta.text"], "Weiter")
        let plans = out.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
        XCTAssertEqual(plans.map(\.badge), [nil, "Save 52%"])
    }

    func testTextWithoutTheTokenIsLeftExactlyAsWritten() throws {
        let out = try config(#"{"de": {"plan.0.badge": "Bester Wert"}}"#).applyingSavings()
        XCTAssertEqual(out.localizations?["de"]?["plan.0.badge"], "Bester Wert")
    }
}
