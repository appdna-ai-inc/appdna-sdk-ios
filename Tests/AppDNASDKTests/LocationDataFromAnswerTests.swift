// LocationDataFromAnswerTests.swift
//
// SPEC-497 §13h (D2) — `getLocationData` never crashes and builds its result from any stored answer.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class LocationDataFromAnswerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionDataStore.shared.clearAll()
    }

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func store(_ value: Any) -> LocationData? {
        SessionDataStore.shared.setOnboardingResponses(["step_location": ["loc": value]])
        return AppDNA.getLocationData(fieldId: "loc")
    }

    func testTypedStringReturnsPartialObjectAndDoesNotCrash() throws {
        let loc = try XCTUnwrap(store("Auckland"))
        XCTAssertEqual(loc.formatted_address, "Auckland")
        XCTAssertEqual(loc.raw_query, "Auckland")
        XCTAssertNil(loc.latitude)
        XCTAssertNil(loc.longitude)
        XCTAssertNil(loc.city)
    }

    func testEmptyStringNullNumberAndAbsentReturnNil() {
        XCTAssertNil(store(""))
        XCTAssertNil(store(NSNull()))
        XCTAssertNil(store(42))
        XCTAssertNil(AppDNA.getLocationData(fieldId: "never_answered"))
    }

    func testFullDict() throws {
        let loc = try XCTUnwrap(store([
            "formatted_address": "A, B", "city": "A", "state": "S", "state_code": "SC", "country": "B",
            "country_code": "BC", "latitude": 1.5, "longitude": -2.5, "timezone": "Etc/UTC", "postal_code": "123",
        ] as [String: Any]))
        XCTAssertEqual(loc.formatted_address, "A, B")
        XCTAssertEqual(loc.city, "A")
        XCTAssertEqual(loc.country_code, "BC")
        XCTAssertEqual(loc.latitude, 1.5)
        XCTAssertEqual(loc.longitude, -2.5)
        XCTAssertEqual(loc.postal_code, "123")
        XCTAssertNil(loc.raw_query)
        XCTAssertNil(loc.timezone_offset)
    }

    func testPartialDictWithNonNumericLatitude() throws {
        let loc = try XCTUnwrap(store(["formatted_address": "A", "city": "A", "latitude": "x", "longitude": 3] as [String: Any]))
        XCTAssertNil(loc.latitude)
        XCTAssertEqual(loc.longitude, 3)
        XCTAssertNil(loc.state)
    }

    func testLegacyAddressDict() throws {
        let loc = try XCTUnwrap(store(["address": "Somewhere", "latitude": 1.0, "longitude": 2.0] as [String: Any]))
        XCTAssertEqual(loc.formatted_address, "Somewhere")
        XCTAssertEqual(loc.latitude, 1.0)
    }

    func testNaNCoordinateIsNull() throws {
        // JSON cannot carry NaN, so this goes straight to the builder `getLocationData` uses.
        let loc = try XCTUnwrap(LocationData.fromStoredAnswer(["formatted_address": "A", "latitude": Double.nan, "longitude": Double.infinity] as [String: Any]))
        XCTAssertNil(loc.latitude)
        XCTAssertNil(loc.longitude)
    }

    func testANaNAnswerIsNotPersistedAndDoesNotCrash() {
        SessionDataStore.shared.setOnboardingResponses(["s": ["loc": ["latitude": Double.nan] as [String: Any]]])
        XCTAssertNotNil(AppDNA.getLocationData(fieldId: "loc"))
    }
}
