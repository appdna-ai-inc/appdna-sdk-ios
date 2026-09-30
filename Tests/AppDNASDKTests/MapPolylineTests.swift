// MapPolylineTests.swift — SPEC-497 §7.8.
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class MapPolylineTests: XCTestCase {

    func testGoogleDocumentedSample() throws {
        let points = try XCTUnwrap(MapPolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@"))
        XCTAssertEqual(points.count, 3)
        let expected = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        for (p, e) in zip(points, expected) {
            XCTAssertEqual(p.lat, e.0, accuracy: 1e-5)
            XCTAssertEqual(p.lng, e.1, accuracy: 1e-5)
        }
    }

    func testEmptyIsEmptyNotNil() {
        XCTAssertEqual(MapPolyline.decode("")?.count, 0)
    }

    func testMalformedIsNil() {
        XCTAssertNil(MapPolyline.decode("_p~iF"), "a latitude with no longitude")
        XCTAssertNil(MapPolyline.decode("_p~iF~ps|U_ulL"), "second point missing its longitude")
        XCTAssertNil(MapPolyline.decode("_"), "an unterminated chunk")
        XCTAssertNil(MapPolyline.decode("_p~iF ps|U"), "a character outside ?…~")
    }

    func testOutOfRangeIsNil() {
        // A precision-6 encoding of a real point decodes 10× too large → rejected.
        XCTAssertNil(MapPolyline.decode(encodePolyline([(385.0, -1202.0)])))
    }

    func testRoundTripWithTheEncoder() throws {
        let stops = [(48.85661, 2.35222), (45.764, 4.83566), (-33.86785, 151.20732)]
        let decoded = try XCTUnwrap(MapPolyline.decode(encodePolyline(stops)))
        XCTAssertEqual(decoded.count, stops.count)
        for (p, e) in zip(decoded, stops) {
            XCTAssertEqual(p.lat, e.0, accuracy: 1e-5)
            XCTAssertEqual(p.lng, e.1, accuracy: 1e-5)
        }
    }
}
