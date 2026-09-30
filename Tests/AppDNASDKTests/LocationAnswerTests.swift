// LocationAnswerTests.swift
//
// SPEC-497 §13h — the stored answer of the `input_location` content block's MapKit path, which the
// shared fixtures cannot reach (they drive the server-suggestion path). A missing city / state /
// country is left out, and a failed time-zone lookup stores no zone at all.
//
// NEGATIVE CONTROL: the old `finalize` stored `"city": ""`, `"state": ""` and `"timezone": "UTC"` for
// these inputs, and never `timezone_offset` / `raw_query`.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class LocationAnswerTests: XCTestCase {

    func testAPlaceWithoutCityOrStateAndAFailedTimeZoneLookupStoresNeither() {
        let stored = FormInputLocationPlaceholderBlock.storedAnswer(
            formattedAddress: "Somewhere, Nowhere",
            city: nil, state: "", country: "Nowhere", countryCode: "NW",
            latitude: 1.5, longitude: -2.5,
            timeZone: nil,
            postalCode: "", rawQuery: "some"
        )
        XCTAssertEqual(Set(stored.keys), [
            "formatted_address", "address", "country", "country_code", "latitude", "longitude", "raw_query",
        ])
        XCTAssertNil(stored["timezone"], "a failed lookup is not UTC")
        XCTAssertNil(stored["city"])
        XCTAssertEqual(stored["raw_query"] as? String, "some")
    }

    func testAResolvedTimeZoneStoresItsIdentifierAndCurrentOffsetInMinutes() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let stored = FormInputLocationPlaceholderBlock.storedAnswer(
            formattedAddress: "A", city: "A", state: nil, country: nil, countryCode: nil,
            latitude: 0, longitude: 0, timeZone: tz, postalCode: nil, rawQuery: nil
        )
        XCTAssertEqual(stored["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(stored["timezone_offset"] as? Int, 330)
        XCTAssertEqual(stored["latitude"] as? Double, 0, "a real 0.0 is a coordinate")
        XCTAssertNil(stored["raw_query"])
    }

    func testANonFiniteCoordinateAndAnOffsetWithoutAZoneAreLeftOut() {
        let stored = LocationAnswer.selection(
            formattedAddress: "A", latitude: .nan, longitude: .infinity, timezone: " ", timezoneOffsetMinutes: 0
        )
        XCTAssertEqual(Set(stored.keys), ["formatted_address", "address"])
    }

    func testSuggestionsAreReadTolerantly() {
        // A wrong-typed field is absent; the suggestion is kept (JSONDecoder used to drop it).
        let parsed = LocationAnswer.decodeSuggestions([["formatted_address": "A", "latitude": "x", "longitude": 2]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed.first?.latitude)
        XCTAssertEqual(parsed.first?.longitude, 2)
    }
}
