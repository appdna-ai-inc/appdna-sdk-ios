import XCTest
@testable import AppDNASDK

/// Pure seams of the element-interaction wiring: the delegate fire-fold, the required-field
/// advance gate, and the per-block field_config override read-layer. No SwiftUI host needed.
final class ElementInteractionWiringTests: XCTestCase {

    // A fake delegate that returns a fixed ElementInteractionResult, proving the fold applies patches/overrides
    // and reports advance. Only onElementInteraction is implemented; the rest come from the protocol extension.
    private final class FakeDelegate: AppDNAOnboardingDelegate {
        let result: ElementInteractionResult?
        private(set) var received: (blockId: String, action: String, value: String?)?
        init(_ result: ElementInteractionResult?) { self.result = result }
        func onElementInteraction(
            flowId: String, stepId: String, blockId: String,
            action: String, value: String?, inputValues: [String: Any]
        ) async -> ElementInteractionResult? {
            received = (blockId, action, value)
            return result
        }
    }

    private func block(json: String) -> ContentBlock {
        try! JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    // MARK: - 1. Fire-seam

    func testFireSeamAppliesInputPatchesAndOverridesWithoutAdvance() async {
        // Case A — inputValue patch + field_config override, advance = false.
        let delegate = FakeDelegate(ElementInteractionResult(
            fieldConfigPatches: ["cal": ["highlight_color": "#00FF00"]],
            inputValuePatches: ["otp": "1234"],
            advance: false
        ))
        let (inputValues, overrides, advance) = await fireElementInteraction(
            delegate: delegate,
            flowId: "f", stepId: "s", blockId: "otp",
            action: "otp_entered", value: "1234",
            inputValues: ["existing": "keep"],
            overrides: ["cal": ["days_in_month": 30]]
        )
        // Delegate saw the interaction.
        XCTAssertEqual(delegate.received?.action, "otp_entered")
        // inputValues patched + untouched key preserved.
        XCTAssertEqual(inputValues["otp"] as? String, "1234")
        XCTAssertEqual(inputValues["existing"] as? String, "keep")
        // Overrides KEY-LEVEL merged — new key added, prior key retained (not blind-replaced).
        XCTAssertEqual(overrides["cal"]?["highlight_color"] as? String, "#00FF00")
        XCTAssertEqual(overrides["cal"]?["days_in_month"] as? Int, 30)
        XCTAssertFalse(advance)
    }

    func testFireSeamReportsAdvance() async {
        // Case B — advance = true.
        let delegate = FakeDelegate(ElementInteractionResult(advance: true))
        let (_, _, advance) = await fireElementInteraction(
            delegate: delegate,
            flowId: "f", stepId: "s", blockId: "confirm",
            action: "confirmed", value: nil,
            inputValues: [:], overrides: [:]
        )
        XCTAssertTrue(advance)
    }

    func testFireSeamWithNoDelegateIsNoOp() async {
        let (inputValues, overrides, advance) = await fireElementInteraction(
            delegate: nil,
            flowId: "f", stepId: "s", blockId: "b",
            action: "day_selected", value: "5",
            inputValues: ["k": "v"], overrides: ["x": ["a": 1]]
        )
        XCTAssertEqual(inputValues["k"] as? String, "v")
        XCTAssertEqual(overrides["x"]?["a"] as? Int, 1)
        XCTAssertFalse(advance)
    }

    // MARK: - 2. Advance gate

    func testRequiredFieldGateBlocksWhenEmptyAndPassesWhenFilled() {
        let required = block(json: #"{"id":"q1","type":"input_text","field_required":true}"#)

        // Empty → advance BLOCKED (an interaction-driven advance can't bypass validation).
        let empty = RequiredFieldGate.evaluate(blocks: [required], inputValues: [:])
        XCTAssertFalse(empty.canAdvance)
        XCTAssertEqual(empty.firstMissing, "q1")

        // Filled → advance allowed.
        let filled = RequiredFieldGate.evaluate(blocks: [required], inputValues: ["q1": "Alex"])
        XCTAssertTrue(filled.canAdvance)
        XCTAssertNil(filled.firstMissing)
    }

    func testRequiredFieldGateNoRequiredBlocksPasses() {
        let optional = block(json: #"{"id":"q1","type":"input_text"}"#)
        XCTAssertTrue(RequiredFieldGate.evaluate(blocks: [optional], inputValues: [:]).canAdvance)
        XCTAssertTrue(RequiredFieldGate.evaluate(blocks: [], inputValues: [:]).canAdvance)
    }

    // MARK: - 3. Override merge (read-layer)

    func testResolvedFieldConfigCarriesOverride() {
        let cal = block(json: #"{"id":"cal","type":"calendar_month","field_config":{"today":5}}"#)
        let resolved = resolvedFieldConfig(cal, ["cal": ["highlight_color": "#00FF00"]])
        // Override present…
        XCTAssertEqual(resolved.field_config?["highlight_color"]?.value as? String, "#00FF00")
        // …and the pre-existing key survives the merge.
        XCTAssertEqual(resolved.field_config?["today"]?.value as? Int, 5)
    }

    func testResolvedFieldConfigEmptyOverridesIsNoOp() {
        let cal = block(json: #"{"id":"cal","type":"calendar_month","field_config":{"today":5}}"#)
        let resolved = resolvedFieldConfig(cal, [:])
        XCTAssertEqual(resolved.field_config?["today"]?.value as? Int, 5)
        XCTAssertNil(resolved.field_config?["highlight_color"])
    }
}
