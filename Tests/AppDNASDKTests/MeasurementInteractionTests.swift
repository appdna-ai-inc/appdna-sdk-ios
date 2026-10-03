import XCTest
@testable import AppDNASDK

/// The measurement wheel's `onElementInteraction` fire.
///
/// THE BUG: `MeasurementWheelBlockView.writeSnapshot()` computed the delegate payload and then threw
/// it away (`_ = snap.payload`, "deferred"). No host on any device has EVER received a measurement
/// interaction, while Android fired one on every commit (`MeasurementWheel.kt:367`). These tests pin
/// the payload the commit now hands to the delegate, and prove it survives the fire-seam.
final class MeasurementInteractionTests: XCTestCase {

    /// Captures what the host delegate actually sees.
    private final class SpyDelegate: AppDNAOnboardingDelegate {
        private(set) var blockId: String?
        private(set) var action: String?
        private(set) var value: String?
        private(set) var inputValues: [String: Any] = [:]

        func onElementInteraction(
            flowId: String, stepId: String, blockId: String,
            action: String, value: String?, inputValues: [String: Any]
        ) async -> ElementInteractionResult? {
            self.blockId = blockId
            self.action = action
            self.value = value
            self.inputValues = inputValues
            return nil
        }
    }

    private let wheelJSON = """
    {
      "id": "weight_block",
      "type": "wheel_picker",
      "field_id": "weight",
      "field_config": {
        "measurement_type": "weight",
        "measurement_style": "ruler",
        "measurement_default": 70,
        "units": [
          { "id": "kg", "label": "kg", "min": 30, "max": 200, "step": 1, "decimals": 0, "factor": 1, "offset": 0 },
          { "id": "lb", "label": "lb", "min": 66, "max": 440, "step": 1, "decimals": 0, "factor": 2.20462, "offset": 0 }
        ]
      }
    }
    """

    private func measurementConfig() throws -> (ContentBlock, MeasurementConfig) {
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(wheelJSON.utf8))
        let config = try XCTUnwrap(parseMeasurementConfig(block), "measurement mode must resolve")
        return (block, config)
    }

    // MARK: - The interaction value

    /// `onInteract` is `(blockId, action, value: String?)` on BOTH platforms, so the base scalar
    /// crosses as a string. Android sends `snap.payload["value"]?.toString()` — an Int stays integral
    /// ("70", never "70.0"), or numeric `answer_equals` routing would stop matching on iOS only.
    func testInteractionValueIsTheBaseScalarStringified() throws {
        let (_, config) = try measurementConfig()
        let snapshot = measurementSnapshot(
            fieldId: "weight",
            base: 70,
            baseUnit: config.units[0],
            displayUnit: config.units[1]
        )
        XCTAssertEqual(measurementInteractionValue(snapshot), "70")
        XCTAssertEqual(measurementInteractionAction, "value_changed")
    }

    func testInteractionValueKeepsFractionalPrecision() throws {
        let (_, config) = try measurementConfig()
        // A half-step unit: decimals=1, step=0.5 — the base is genuinely fractional.
        let unit = MeasurementUnit(
            id: "kg", label: "kg", min: 30, max: 200, step: 0.5, decimals: 1, factor: 1, offset: 0
        )
        let snapshot = measurementSnapshot(
            fieldId: "weight", base: 70.5, baseUnit: unit, displayUnit: config.units[0]
        )
        XCTAssertEqual(measurementInteractionValue(snapshot), "70.5")
    }

    // MARK: - The fire-seam

    /// The delegate must receive `{value, display_value, unit}`: `value` as the interaction value,
    /// and `display_value` / `unit` through the freshly-written `inputValues` the seam passes along.
    /// Before the fix the delegate was never called at all.
    func testCommitFiresTheDelegateWithValueDisplayValueAndUnit() async throws {
        let (block, config) = try measurementConfig()
        let spy = SpyDelegate()

        // Reproduce exactly what the view does on a commit: write the snapshot, then fire.
        let snapshot = measurementSnapshot(
            fieldId: "weight",
            base: 70,
            baseUnit: config.units[0],   // kg (base)
            displayUnit: config.units[1] // lb (the unit the user toggled to)
        )
        let (inputValues, _, advance) = await fireElementInteraction(
            delegate: spy,
            flowId: "flow_1",
            stepId: "s1",
            blockId: block.id,
            action: measurementInteractionAction,
            value: measurementInteractionValue(snapshot),
            inputValues: snapshot.inputValues,
            overrides: [:]
        )

        XCTAssertEqual(spy.blockId, "weight_block")
        XCTAssertEqual(spy.action, "value_changed")
        XCTAssertEqual(spy.value, "70", "value = the canonical BASE scalar")

        // display_value + unit reach the delegate through inputValues.
        XCTAssertEqual(spy.inputValues["weight"] as? Int, 70)
        XCTAssertEqual(spy.inputValues["weight_unit"] as? String, "kg")
        XCTAssertEqual(spy.inputValues["weight_display_unit"] as? String, "lb")
        XCTAssertEqual(spy.inputValues["weight_display_value"] as? Int, 154) // 70 kg → 154 lb

        // A nil result leaves state untouched and does not advance.
        XCTAssertEqual(inputValues["weight"] as? Int, 70)
        XCTAssertFalse(advance)
    }

    /// The snapshot payload itself still carries all three facts — this is the contract the wrapper
    /// channels (RN/Flutter) will serialize.
    func testSnapshotPayloadCarriesValueDisplayValueAndUnit() throws {
        let (_, config) = try measurementConfig()
        let snapshot = measurementSnapshot(
            fieldId: "weight", base: 70, baseUnit: config.units[0], displayUnit: config.units[1]
        )
        XCTAssertEqual(snapshot.payload["value"] as? Int, 70)
        XCTAssertEqual(snapshot.payload["display_value"] as? Int, 154)
        XCTAssertEqual(snapshot.payload["unit"] as? String, "lb")
    }
}
