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
//   location_answer_from_input REAL: `LocationAnswer` (the rule both location writers call; a selection
//                              first goes through `LocationAnswer.decodeSuggestions`, the form-step
//                              field's parser) → `SessionDataStore` → `AppDNA.getLocationData(fieldId:)`.
//   bridge_step_advance_reply  REAL: `StepAdvanceResult.isExplicitBridgeDecision` / `bridgeSkipTarget`,
//                              the two calls every wrapper bridge's auth gate and decoder make.
//   bridge_timeout_floor       REAL: `StepAdvanceResult.minimumBridgeTimeout(stepData:)`. Only
//                              `action.cases` — `bridge_waits` (max of configured and floor) belongs to
//                              the wrapper bridge tests; asserting it here would be a tautology.
//   parse_window_date          REAL: `MessageManager.parseWindowDate`, the in-app message window's
//                              date reader, with the device time zone set to `action.device_timezone`.
//   countdown_initial_seconds  REAL: `CountdownTimerBlockView.initialRemainingSeconds(…, now:)`, the
//                              countdown block's `target_datetime` reader, at `action.now_ms`.
//   form_date_bounds           REAL: `FormStepView.dateRange(minDate:maxDate:)`, a form step date
//                              field's `min_date` / `max_date`, in `action.device_timezone`.
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
        case "location_answer_from_input": runLocationAnswerFromInput(f, h)
        case "bridge_step_advance_reply": runBridgeStepAdvanceReply(f, h)
        case "bridge_timeout_floor":      runBridgeTimeoutFloor(f, h)
        case "parse_window_date":         runParseWindowDate(f, h)
        case "countdown_initial_seconds": runCountdownInitialSeconds(f, h)
        case "form_date_bounds":          runFormDateBounds(f, h)
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

    // MARK: parse_window_date

    private func runParseWindowDate(_ f: Fixture, _ h: Harness) {
        let a = f.action.raw
        guard let cases = a["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] parse_window_date needs action.cases")
            return
        }
        let saved = NSTimeZone.default
        if let id = a["device_timezone"]?.stringValue {
            guard let tz = TimeZone(identifier: id) else {
                XCTFail("[\(f.id)] unknown device_timezone \(id)")
                return
            }
            NSTimeZone.default = tz
        }
        defer { NSTimeZone.default = saved }
        h.state["results"] = cases.map { c -> Any in
            guard let value = c.objectValue?["value"]?.stringValue else {
                XCTFail("[\(f.id)] parse_window_date case without a string value")
                return NSNull()
            }
            return SharedFixtureTests.orNull(
                MessageManager.parseWindowDate(value).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            )
        }
    }

    // MARK: countdown_initial_seconds

    private func runCountdownInitialSeconds(_ f: Fixture, _ h: Harness) {
        let a = f.action.raw
        guard let cases = a["cases"]?.arrayValue, let nowMs = a["now_ms"]?.doubleValue else {
            XCTFail("[\(f.id)] countdown_initial_seconds needs action.cases and action.now_ms")
            return
        }
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            return CountdownTimerBlockView.initialRemainingSeconds(
                targetType: o["target_type"]?.stringValue,
                targetDatetime: o["target_datetime"]?.stringValue,
                durationSeconds: o["duration_seconds"]?.doubleValue.map { Int($0) },
                now: now
            )
        }
    }

    // MARK: form_date_bounds

    private func runFormDateBounds(_ f: Fixture, _ h: Harness) {
        let a = f.action.raw
        guard let cases = a["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] form_date_bounds needs action.cases")
            return
        }
        let saved = NSTimeZone.default
        if let id = a["device_timezone"]?.stringValue {
            guard let tz = TimeZone(identifier: id) else {
                XCTFail("[\(f.id)] unknown device_timezone \(id)")
                return
            }
            NSTimeZone.default = tz
        }
        defer { NSTimeZone.default = saved }
        func ms(_ d: Date) -> Any {
            // distantPast / distantFuture are "no bound" (the missing side of a one-sided range).
            if d == .distantPast || d == .distantFuture { return NSNull() }
            return Int64((d.timeIntervalSince1970 * 1000).rounded())
        }
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            guard let range = FormStepView.dateRange(minDate: o["min_date"]?.stringValue, maxDate: o["max_date"]?.stringValue) else {
                return [NSNull(), NSNull()]
            }
            return [ms(range.lowerBound), ms(range.upperBound)]
        }
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

    // MARK: location_answer_from_input

    private func runLocationAnswerFromInput(_ f: Fixture, _ h: Harness) {
        guard let fieldId = f.action.raw["field_id"]?.stringValue,
              let input = f.action.raw["input"]?.objectValue,
              let kind = input["kind"]?.stringValue else {
            return XCTFail("[\(f.id)] location_answer_from_input needs action.field_id and action.input.kind")
        }
        let stored: Any
        switch kind {
        case "typed":
            stored = LocationAnswer.typed(input["text"]?.stringValue ?? "")
        case "selected":
            guard let item = input["suggestion"]?.foundation as? [String: Any],
                  let suggestion = LocationAnswer.decodeSuggestions([item]).first else {
                return XCTFail("[\(f.id)] the suggestion did not parse")
            }
            stored = LocationAnswer.selection(from: suggestion, rawQuery: input["typed_query"]?.stringValue)
        default:
            return XCTFail("[\(f.id)] unknown input.kind \(kind)")
        }
        h.state["stored_answer"] = stored

        SessionDataStore.shared.clearAll()
        defer { SessionDataStore.shared.clearAll() }
        SessionDataStore.shared.setOnboardingResponses(["step_location": [fieldId: stored]])
        guard let loc = AppDNA.getLocationData(fieldId: fieldId) else {
            h.state["location_data"] = NSNull()
            return
        }
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

    // MARK: bridge_step_advance_reply

    private func runBridgeStepAdvanceReply(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            return XCTFail("[\(f.id)] bridge_step_advance_reply needs action.cases")
        }
        h.state["decisions"] = cases.map { c -> Any in
            let reply = c.objectValue?["reply"]?.foundation
            return [
                "explicit": StepAdvanceResult.isExplicitBridgeDecision(reply),
                "skip_target": SharedFixtureTests.orNull(StepAdvanceResult.bridgeSkipTarget(reply: reply)),
            ] as [String: Any]
        }
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
