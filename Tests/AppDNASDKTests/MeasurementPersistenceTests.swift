import XCTest
@testable import AppDNASDK

/// Pure persistence + delegate-payload contract for wheel-picker
/// measurement mode. Mirrors `InteractionResultTests` (asserts the executed
/// guarantee, not the render). The base scalar MUST be unit-stable across a
/// unit toggle; the sibling keys are self-consistent (`_unit` annotates the BASE).
final class MeasurementPersistenceTests: XCTestCase {

    // weight preset: kg (canonical base) ↔ lbs
    private let kg = MeasurementUnit(id: "kg", label: "kg", min: 30, max: 200, step: 0.5, decimals: 1, factor: 1, offset: 0)
    private let lbs = MeasurementUnit(id: "lbs", label: "lbs", min: 66, max: 441, step: 1, decimals: 0, factor: 2.20462, offset: 0)
    // temperature preset: °C (base) ↔ °F (offset conversion)
    private let c = MeasurementUnit(id: "c", label: "°C", min: 35, max: 42, step: 0.1, decimals: 1, factor: 1, offset: 0)
    private let f = MeasurementUnit(id: "f", label: "°F", min: 95, max: 108, step: 0.1, decimals: 1, factor: 1.8, offset: 32)

    // MARK: persistence contract

    func testPersistsBaseScalarAndSiblingKeysInBaseUnit() {
        // User picks 75.0 kg while the display unit IS the base unit.
        let snap = measurementSnapshot(fieldId: "weight", base: 75.0, baseUnit: kg, displayUnit: kg)

        XCTAssertEqual(snap.inputValues["weight"] as? Int, 75)             // snapped+clamped BASE scalar
        XCTAssertEqual(snap.inputValues["weight_unit"] as? String, "kg")   // annotates the base scalar
        XCTAssertEqual(snap.inputValues["weight_display_unit"] as? String, "kg")
        XCTAssertEqual(snap.inputValues["weight_display_value"] as? Int, 75)

        XCTAssertEqual(snap.payload["value"] as? Int, 75)
        XCTAssertEqual(snap.payload["display_value"] as? Int, 75)
        XCTAssertEqual(snap.payload["unit"] as? String, "kg")
    }

    func testToggleHoldsBaseConstantAndConvertsDisplay() {
        // Same base (75 kg) but the display unit is now lbs → base scalar is UNCHANGED,
        // display + _display_unit + payload reflect lbs.
        let snap = measurementSnapshot(fieldId: "weight", base: 75.0, baseUnit: kg, displayUnit: lbs)

        XCTAssertEqual(snap.inputValues["weight"] as? Int, 75)             // unit-stable base scalar
        XCTAssertEqual(snap.inputValues["weight_unit"] as? String, "kg")   // still the base unit
        XCTAssertEqual(snap.inputValues["weight_display_unit"] as? String, "lbs")
        // 75 kg → 165.3465 lbs → snap step=1 decimals=0 → 165
        XCTAssertEqual(snap.inputValues["weight_display_value"] as? Int, 165)

        XCTAssertEqual(snap.payload["value"] as? Int, 75)
        XCTAssertEqual(snap.payload["display_value"] as? Int, 165)
        XCTAssertEqual(snap.payload["unit"] as? String, "lbs")
    }

    func testOffsetConversionTemperature() {
        // 37.0 °C held as base; display in °F = 37*1.8+32 = 98.6 → snap step 0.1 → 98.6.
        // Base 37.0 is whole → persisted as Int (measurementScalar).
        let snap = measurementSnapshot(fieldId: "temp", base: 37.0, baseUnit: c, displayUnit: f)
        XCTAssertEqual(snap.inputValues["temp"] as? Int, 37)
        XCTAssertEqual(snap.inputValues["temp_unit"] as? String, "c")
        XCTAssertEqual(snap.inputValues["temp_display_unit"] as? String, "f")
        XCTAssertEqual(snap.inputValues["temp_display_value"] as? Double ?? .nan, 98.6, accuracy: 0.0001)
        XCTAssertEqual(snap.payload["display_value"] as? Double ?? .nan, 98.6, accuracy: 0.0001)
        XCTAssertEqual(snap.payload["unit"] as? String, "f")
    }

    // MARK: pinned snap algorithm

    func testSnapClampsToBaseRange() {
        // A lbs extreme can convert to a base slightly outside [kg.min,kg.max];
        // the clamp (final op) absorbs it → exactly the boundary.
        let over = measurementSnap(250, kg)   // above max 200
        XCTAssertEqual(over, 200)
        let under = measurementSnap(10, kg)   // below min 30
        XCTAssertEqual(under, 30)
    }

    func testSnapHalfAwayFromZeroOnNegatives() {
        let u = MeasurementUnit(id: "x", label: "x", min: -100, max: 100, step: 1, decimals: 0, factor: 1, offset: 0)
        XCTAssertEqual(measurementSnap(2.5, u), 3)     // half away → up
        XCTAssertEqual(measurementSnap(-2.5, u), -3)   // half away → down (NOT -2 like half-to-even)
    }

    func testRoundHalfAwaySignZero() {
        XCTAssertEqual(measurementRoundHalfAway(0), 0)
        XCTAssertEqual(measurementRoundHalfAway(0.5), 1)
        XCTAssertEqual(measurementRoundHalfAway(-0.5), -1)
    }
}
