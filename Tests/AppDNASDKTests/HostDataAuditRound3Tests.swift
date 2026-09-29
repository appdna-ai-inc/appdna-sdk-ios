import XCTest
import SwiftUI
@testable import AppDNASDK

/// SPEC-496 P1 implementation-audit ROUND 3 regressions (iOS):
///   - a carousel inside an option sheet had its pages' `sheet_step_paths` applied TWICE (the outer
///     renderer's recursive apply, then the nested page renderer's) → a user-typed `{{…}}` re-scanned;
///   - a consent-coloured CTA on a carousel page gated on `[page]` only, not the step's layered list.
/// (The §B0 option-index remap after the hide rule is pinned by the shared fixture
/// `template_engine/sheet_option_step_paths_after_hide`, run by the resolve_block driver.)
@MainActor
final class HostDataAuditRound3Tests: XCTestCase {

    private func block(_ json: String) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    // MARK: - Sheet step paths are applied once — a second call is a no-op

    func testApplySheetStepPathsStripsAppliedPathsSoASecondCallIsANoOp() throws {
        let carousel = try block("""
        { "id": "car", "type": "carousel", "children": [
          { "id": "p1", "type": "text", "text": "Hi {{step.name}}",
            "field_config": { "sheet_step_paths": [{ "path": "text", "kind": "token" }] } }
        ] }
        """)
        // The user typed a literal token into the sheet's field.
        let inputs: [String: Any] = ["name": "{{step.secret}}", "secret": "LEAK"]
        let once = OnboardingStepPipeline.applySheetStepPaths(carousel, stepInputs: inputs)
        let page = try XCTUnwrap(once.children?.first)
        XCTAssertNil(page.field_config?["sheet_step_paths"], "applied paths are stripped from the output")
        XCTAssertFalse((page.text ?? "").contains("LEAK"), "the substituted value is never re-scanned")

        // The nested carousel page renderer calls applySheetStepPaths again on the page it was handed.
        let twice = OnboardingStepPipeline.applySheetStepPaths(page, stepInputs: inputs)
        XCTAssertEqual(twice.text, page.text, "§A1 no re-scan — the second application changes nothing")
        XCTAssertFalse((twice.text ?? "").contains("LEAK"))

        // The SOURCE block keeps its paths, so the next render re-applies against the live inputs.
        XCTAssertNotNil(carousel.children?.first?.field_config?["sheet_step_paths"])
        let rerender = OnboardingStepPipeline.applySheetStepPaths(carousel, stepInputs: ["name": "Ana"])
        XCTAssertEqual(rerender.children?.first?.text, "Hi Ana")
    }

    // MARK: - Consent CTA on a carousel page gates on the step's layered list

    func testCarouselPagesCarryTheStepGateListAndRawIds() throws {
        let cta = try block("""
        { "id": "cta", "type": "button", "text": "Go",
          "field_config": { "cta_enabled_bg_color": "#00FF00", "cta_disabled_bg_color": "#FF0000" } }
        """)
        let carousel = try block("""
        { "id": "car", "type": "carousel", "children": [
          { "id": "cta", "type": "button", "text": "Go",
            "field_config": { "cta_enabled_bg_color": "#00FF00", "cta_disabled_bg_color": "#FF0000" } }
        ] }
        """)
        let consent = try block(#"{ "id": "consent", "type": "input_text", "field_id": "consent", "field_required": true }"#)
        let step = [carousel, consent]

        let view = CarouselBlockView(block: carousel, onAction: { _, _ in },
                                     toggleValues: .constant([:]), inputValues: .constant([:]),
                                     gateBlocks: step, rawResolvedIds: ["car", "cta", "consent"])
        XCTAssertEqual(view.gateBlocks?.map(\.id), ["car", "consent"], "the page renderer receives the step's list")
        XCTAssertEqual(view.rawResolvedIds, ["car", "cta", "consent"])

        // What the page's CTA colour reads: the step list (unsatisfied) — NOT `[page]` (vacuously satisfied).
        XCTAssertTrue(RequiredFieldGate.evaluate(blocks: [cta], inputValues: [:], rawResolvedIds: []).canAdvance,
                      "evaluating only [page] ignores the required consent elsewhere on the step")
        XCTAssertFalse(RequiredFieldGate.evaluate(blocks: view.gateBlocks ?? [cta], inputValues: [:],
                                                  rawResolvedIds: view.rawResolvedIds).canAdvance)
    }

    /// Audit round 4 — Screens/SDUI pass no gate list, so a carousel page keeps gating on itself (§A1: Screens
    /// unchanged in P1). The renderer forwards `gateBlocks` as-is; it must not substitute the section's blocks.
    func testCarouselInScreensKeepsPageOnlyGate() throws {
        let carousel = try block(#"{ "id": "car", "type": "carousel", "children": [ { "id": "t", "type": "text", "text": "x" } ] }"#)
        let view = CarouselBlockView(block: carousel, onAction: { _, _ in },
                                     toggleValues: .constant([:]), inputValues: .constant([:]))
        XCTAssertNil(view.gateBlocks, "no step list in Screens → the page renderer falls back to [page]")
        XCTAssertTrue(view.rawResolvedIds.isEmpty)
    }
}
