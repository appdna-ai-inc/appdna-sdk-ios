// MapInteractivePlanTests.swift
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class MapInteractivePlanTests: XCTestCase {

    private func block(_ cfg: String) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"id":"m","type":"map","field_config":{\#(cfg)}}"#.utf8))
    }

    private let twoStops = #""map_stops":[{"lat":10,"lng":20},{"lat":11,"lng":21}]"#
    private let sample = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"

    func testPolylineWinsAndFitIncludesStops() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_route_polyline":"\#(sample)",\#(twoStops)"#))
        XCTAssertEqual(plan.routeSource, .polyline)
        XCTAssertEqual(plan.routePoints.count, 3)
        XCTAssertEqual(plan.markers.count, 2)
        guard case .fit(let points) = plan.camera else { return XCTFail("expected fit") }
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first, plan.routePoints.first, "route points come first")
    }

    func testStopsOnlyDrawsStraightSegments() throws {
        let plan = MapInteractivePlan.compute(block: try block(twoStops))
        XCTAssertEqual(plan.routeSource, .stops)
        XCTAssertEqual(plan.routePoints, plan.markers)
        guard case .fit(let points) = plan.camera else { return XCTFail("expected fit") }
        XCTAssertEqual(points.count, 2, "a stop is not counted twice")
    }

    func testMalformedPolylineFallsBackToStops() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_route_polyline":"_p~iF",\#(twoStops)"#))
        XCTAssertEqual(plan.routeSource, .stops)
    }

    func testRouteHiddenDrawsNothingButStillFits() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""route_show":false,\#(twoStops)"#))
        XCTAssertEqual(plan.routeSource, .none)
        XCTAssertTrue(plan.routePoints.isEmpty)
        guard case .fit = plan.camera else { return XCTFail("markers still framed") }
    }

    func testFitOffUsesAuthoredCentreAndZoom() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_fit_to_stops":false,"map_center_lat":36.3,"map_center_lng":174.8,"map_zoom":"9",\#(twoStops)"#))
        XCTAssertEqual(plan.camera, .center(lat: 36.3, lng: 174.8, zoom: 9))
    }

    func testFitOffWithoutCentreUsesSeattleAndDefaultZoom() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_fit_to_stops":false,\#(twoStops)"#))
        XCTAssertEqual(plan.camera, .center(lat: 47.6205, lng: -122.3493, zoom: 12))
    }

    func testSinglePointIsZoom15EvenWithAuthoredZoom() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_zoom":9,"map_stops":[{"lat":10,"lng":20}]"#))
        XCTAssertEqual(plan.routeSource, .none)
        XCTAssertEqual(plan.camera, .center(lat: 10, lng: 20, zoom: 15))
    }

    func testNoPointsUsesAuthoredCentre() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_center_lat":1,"map_center_lng":2"#))
        XCTAssertEqual(plan.camera, .center(lat: 1, lng: 2, zoom: 12))
    }

    func testPlaceModeUnchanged() throws {
        let plan = MapInteractivePlan.compute(block: try block(#""map_mode":"place","place_lat":5,"place_lng":6,"map_zoom":14,"map_route_polyline":"\#(sample)""#))
        XCTAssertEqual(plan.routeSource, .none)
        XCTAssertEqual(plan.camera, .center(lat: 5, lng: 6, zoom: 14))
    }

    func testRawResolvedVariableIsTheRoute() throws {
        // A raw-resolved block uses `map_route_variable` as-is (it may contain `{{`, ASCII 63–126).
        let encoded = encodePolyline([(10, 20), (10.0012, 20.0012), (11, 21)])
        let b = try block(#""map_route_variable":"\#(encoded)""#)
        let raw = MapInteractivePlan.compute(block: b, rawResolved: true)
        XCTAssertEqual(raw.routeSource, .polyline)
    }

    func testBoundsAreNaiveMinMax() {
        let b = MapInteractivePlan.bounds(of: [.init(lat: 1, lng: 5), .init(lat: -2, lng: 7), .init(lat: 3, lng: -1)])
        XCTAssertEqual(b?.south, -2); XCTAssertEqual(b?.north, 3)
        XCTAssertEqual(b?.west, -1); XCTAssertEqual(b?.east, 7)
    }
}
