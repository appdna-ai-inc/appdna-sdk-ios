// SharedFixtureDrivers+Pickers.swift
//
// iOS driver for the picker fixture kinds. Dispatched from `SharedFixtureTests.drive`'s default
// branch. Every value asserted is produced by a REAL SDK symbol:
//
//   resolve_measurement_palette  REAL: `measurementPalette(_:highlight:dark:)`, the rule
//                                `MeasurementWheelBlockView` draws every colour from.
//   resolve_measurement_linear   REAL: `measurementLinearValue`, `measurementLinearFraction` and
//                                `measurementLinearSizes`, which the `linear` slider calls.
//   resolve_date_picker_style    REAL: `DatePickerStyle.standalone` / `.formField`.
//   resolve_date_range           REAL: `DateRangeSelection.tapping` / `.answer`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    @MainActor
    func drivePickerFixtures(_ f: Fixture, _ h: Harness) -> Bool {
        switch f.action.kind {
        case "resolve_measurement_palette": runMeasurementPalette(f, h)
        case "resolve_measurement_linear": runMeasurementLinear(f, h)
        case "resolve_date_picker_style": runDatePickerStyle(f, h)
        case "resolve_date_range": runDateRange(f, h)
        default: return false
        }
        return true
    }

    private func pickerCases(_ f: Fixture) -> [[String: Any]]? {
        guard let cases = f.action.raw["cases"]?.arrayValue, !cases.isEmpty else {
            XCTFail("[\(f.id)] \(f.action.kind) needs action.cases")
            return nil
        }
        return cases.map { ($0.foundation as? [String: Any]) ?? [:] }
    }

    private func runMeasurementPalette(_ f: Fixture, _ h: Harness) {
        guard let cases = pickerCases(f) else { return }
        h.state["results"] = cases.map { c -> Any in
            let cfg = (c["field_config"] as? [String: Any]) ?? [:]
            let highlight = c["highlight_color"] as? String
            let dark = (c["dark"] as? Bool) ?? false
            return measurementPalette(cfg, highlight: highlight, dark: dark).roles
        }
    }

    private func runMeasurementLinear(_ f: Fixture, _ h: Harness) {
        guard let cases = pickerCases(f) else { return }
        func num(_ v: Any?) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? 0 }
        h.state["results"] = cases.map { c -> Any in
            let u = (c["unit"] as? [String: Any]) ?? [:]
            let unit = MeasurementUnit(id: "u", label: "u", min: num(u["min"]), max: num(u["max"]), step: num(u["step"]),
                                       decimals: Int(num(u["decimals"])), factor: 1, offset: 0)
            switch c["op"] as? String {
            case "value_at": return measurementLinearValue(num(c["fraction"]), unit)
            case "fraction_of": return measurementLinearFraction(num(c["value"]), unit)
            case "sizes":
                let s = measurementLinearSizes((c["field_config"] as? [String: Any]) ?? [:])
                return ["height": s.height, "track_width": s.trackWidth, "thumb_size": s.thumbSize]
            default:
                XCTFail("[\(f.id)] unknown op \(String(describing: c["op"]))")
                return NSNull()
            }
        }
    }

    /// REAL: `DatePickerStyle.standalone` / `.formField`, which the Date Picker and the Date field draw from.
    private func runDatePickerStyle(_ f: Fixture, _ h: Harness) {
        guard let cases = pickerCases(f) else { return }
        h.state["results"] = cases.map { c -> Any in
            if (c["surface"] as? String) == "form" {
                return DatePickerStyle.formField(presentation: c["presentation"] as? String, variant: c["variant"] as? String,
                                                 hasDate: (c["has_date"] as? Bool) ?? true)
            }
            return DatePickerStyle.standalone(mode: c["mode"] as? String, variant: c["variant"] as? String,
                                              selection: c["selection"] as? String)
        }
    }

    /// REAL: `DateRangeSelection.tapping` and `.answer`, which the range calendar calls on every tap.
    private func runDateRange(_ f: Fixture, _ h: Harness) {
        guard let cases = pickerCases(f) else { return }
        h.state["results"] = cases.map { c -> Any in
            var sel = DateRangeSelection(start: nil, end: nil)
            for t in (c["taps"] as? [String]) ?? [] { sel = sel.tapping(t) }
            return sel.answer(fieldId: (c["field_id"] as? String) ?? "f").mapValues { $0 ?? NSNull() }
        }
    }
}
