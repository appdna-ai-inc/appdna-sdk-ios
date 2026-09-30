// SharedFixtureDrivers+Maps.swift
//
// SPEC-497 — iOS drivers for the maps-area fixture kinds (decode_polyline, map_interactive_plan,
// location_data_from_answer, bridge_timeout_floor).
// Dispatched from `SharedFixtureTests.drive`'s default branch. Every value asserted is produced by a
// REAL SDK symbol (see the header of SharedFixtureTests.swift):
//
//   decode_polyline            REAL: `MapPolyline.decode`, and the static tier's `encodePolyline` for
//                              the round trip.
//   map_interactive_plan       REAL: `StepConfig` decoding → `StepConfigOverride.decodeMapRoutes` →
//                              `StepConfigOverrideMerger.apply` (the merge the renderer runs) →
//                              `MapInteractivePlan.compute`, the seam `GoogleInteractiveMap` draws from.
//   location_data_from_answer  REAL: `SessionDataStore` + `AppDNA.getLocationData(fieldId:)`.
//   bridge_timeout_floor       REAL: `StepAdvanceResult.minimumBridgeTimeout(stepData:)`. Only
//                              `action.cases` — `bridge_waits` (max of configured and floor) belongs to
//                              the wrapper bridge tests; asserting it here would be a tautology.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveSpec497Maps(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "decode_polyline":           runDecodePolyline(f, h)
        case "map_interactive_plan":      runMapInteractivePlan(f, h)
        case "location_data_from_answer": runLocationDataFromAnswer(f, h)
        case "bridge_timeout_floor":      runBridgeTimeoutFloor(f, h)
        default:
            return false
        }
        return true
    }

    private static func pairs(_ points: [(lat: Double, lng: Double)]) -> [[Double]] {
        points.map { [$0.lat, $0.lng] }
    }

    private static func pairs(_ points: [MapInteractivePlan.LatLng]) -> [[Double]] {
        points.map { [$0.lat, $0.lng] }
    }

    // MARK: decode_polyline

    private func runDecodePolyline(_ f: Fixture, _ h: Harness) {
        let a = f.action.raw
        var drove = false
        if let encoded = a["encoded"]?.stringValue {
            h.state["points"] = SharedFixtureTests.orNull(MapPolyline.decode(encoded).map { Self.pairs($0) })
            drove = true
        }
        if let cases = a["cases"]?.arrayValue {
            h.state["results"] = cases.map { c -> Any in
                let encoded = c.objectValue?["encoded"]?.stringValue ?? ""
                return SharedFixtureTests.orNull(MapPolyline.decode(encoded).map { Self.pairs($0) })
            }
            drove = true
        }
        if let stops = a["stops"]?.arrayValue {
            let input = stops.compactMap { s -> (Double, Double)? in
                guard let p = s.arrayValue, p.count == 2, let la = p[0].doubleValue, let ln = p[1].doubleValue else { return nil }
                return (la, ln)
            }
            // REAL encoder (the static tier's) → REAL decoder.
            h.state["roundtrip_points"] = SharedFixtureTests.orNull(MapPolyline.decode(encodePolyline(input)).map { Self.pairs($0) })
            drove = true
        }
        if !drove { XCTFail("[\(f.id)] decode_polyline needs action.encoded, action.cases or action.stops") }
    }

    // MARK: map_interactive_plan

    private func runMapInteractivePlan(_ f: Fixture, _ h: Harness) {
        let blockId = f.action.raw["block_id"]?.stringValue ?? ""
        let sess = f.setup.session_data?.objectValue ?? [:]
        guard let cfgJSON = f.setup.config?.foundation,
              let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let stepCfg = try? JSONDecoder().decode(StepConfig.self, from: cfgData)
        else {
            return XCTFail("[\(f.id)] setup.config did not decode as a StepConfig")
        }
        let routes = StepConfigOverride.decodeMapRoutes(sess["host_map_routes"]?.foundation)
        let merged = routes == nil ? stepCfg : StepConfigOverrideMerger.apply(StepConfigOverride(mapRoutes: routes), to: stepCfg)
        guard let block = (merged.content_blocks ?? []).first(where: { $0.id == blockId }) else {
            return XCTFail("[\(f.id)] no block with id=\(blockId) after the merge")
        }

        let plan = MapInteractivePlan.compute(block: block)
        let camera: [String: Any]
        switch plan.camera {
        case .fit(let points):
            camera = ["mode": "fit", "points": Self.pairs(points)]
        case .center(let lat, let lng, let zoom):
            camera = ["mode": "center", "lat": lat, "lng": lng, "zoom": zoom]
        }
        h.state["plan"] = [
            "route": ["source": plan.routeSource.rawValue, "points": Self.pairs(plan.routePoints)],
            "markers": Self.pairs(plan.markers),
            "camera": camera,
        ] as [String: Any]
    }

    // MARK: location_data_from_answer

    private func runLocationDataFromAnswer(_ f: Fixture, _ h: Harness) {
        guard let fieldId = f.action.raw["field_id"]?.stringValue else {
            return XCTFail("[\(f.id)] location_data_from_answer needs action.field_id")
        }
        let responses = (f.setup.session_data?.objectValue?["responses"]?.foundation as? [String: Any]) ?? [:]
        SessionDataStore.shared.clearAll()
        defer { SessionDataStore.shared.clearAll() }
        SessionDataStore.shared.setOnboardingResponses(responses)

        guard let loc = AppDNA.getLocationData(fieldId: fieldId) else {
            h.state["location_data"] = NSNull()
            return
        }
        // Every key, absent ones as NSNull (never a boxed Swift nil, which canonicalises as "nil").
        let o = SharedFixtureTests.orNull
        h.state["location_data"] = [
            "formatted_address": loc.formatted_address,
            "city": o(loc.city),
            "state": o(loc.state),
            "state_code": o(loc.state_code),
            "country": o(loc.country),
            "country_code": o(loc.country_code),
            "latitude": o(loc.latitude),
            "longitude": o(loc.longitude),
            "timezone": o(loc.timezone),
            "timezone_offset": o(loc.timezone_offset),
            "postal_code": o(loc.postal_code),
            "raw_query": o(loc.raw_query),
        ] as [String: Any]
    }

    // MARK: bridge_timeout_floor

    private func runBridgeTimeoutFloor(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            return XCTFail("[\(f.id)] bridge_timeout_floor needs action.cases")
        }
        h.state["floors_ms"] = cases.map { c -> Any in
            let stepData = c.objectValue?["step_data"]?.foundation as? [String: Any]
            return SharedFixtureTests.orNull(
                StepAdvanceResult.minimumBridgeTimeout(stepData: stepData).map { Int(($0 * 1000).rounded()) }
            )
        }
    }
}
