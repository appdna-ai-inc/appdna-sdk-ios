// SharedFixtureDrivers+Pickers.swift
//
// iOS driver for the picker fixture kinds. Dispatched from `SharedFixtureTests.drive`'s default
// branch. Every value asserted is produced by a REAL SDK symbol:
//
//   resolve_measurement_palette  REAL: `measurementPalette(_:highlight:dark:)`, the rule
//                                `MeasurementWheelBlockView` draws every colour from.
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
}
