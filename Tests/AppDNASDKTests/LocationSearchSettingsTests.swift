import XCTest
@testable import AppDNASDK

/// The Console's four location settings, resolved once for every surface.
///
/// 🔴 WHAT WENT WRONG. There are four location surfaces, not two: a form-step field and an
/// `input_location` content block, on each platform. The form-step field read all four settings;
/// the content block read none. On iOS it searched Apple's place index from the FIRST keystroke
/// while the Console seeds `location_min_chars: 3` on every block, so an authored threshold did
/// nothing. An author set Type = "City" and got street addresses, silently, on both platforms.
///
/// `LocationSearchSettingsTest.kt` is the Kotlin twin and asserts the same semantics case for case.
final class LocationSearchSettingsTests: XCTestCase {

    private func block(_ pairs: [String: Any]) -> [String: AnyCodable] {
        pairs.mapValues { AnyCodable($0) }
    }

    // MARK: - from a content block's free-form field_config

    func testAuthoredSettingsAreCarriedThrough() {
        let s = LocationSearchSettings.from(
            blockConfig: block([
                "location_type": "city",
                "location_bias_country": "PL",
                "location_language": "pl",
                "location_min_chars": 5,
            ]),
            defaultMinChars: 3
        )
        XCTAssertEqual(s.type, "city")
        XCTAssertEqual(s.biasCountry, "PL")
        XCTAssertEqual(s.language, "pl")
        XCTAssertEqual(s.minChars, 5)
    }

    func testUnauthoredTypeStaysNilRatherThanBecomingAddress() {
        /*
         * 🔴 THE ONE THAT WOULD HAVE BEEN A SILENT BEHAVIOUR CHANGE. With no `type` in the request
         * the proxy applies its own default (`GeocodingService.autocomplete`: places, localities and
         * addresses at Mapbox through `mapboxTypeFilter`, no type filter at Google through
         * `googlePrimaryTypes`). Defaulting to "address" here would have turned every unauthored iOS
         * field from that default into an address-only search. Each surface applies its own
         * historical default at its call site instead.
         */
        let s = LocationSearchSettings.from(blockConfig: [:], defaultMinChars: 3)
        XCTAssertNil(s.type)
        XCTAssertNil(s.biasCountry)
        XCTAssertNil(s.language)
    }

    func testBlankCountsAsUnauthored() {
        // The Console writes "" for a cleared text input, and "" must not be sent as a country bias
        // — the proxy would filter on nothing and return nothing.
        let s = LocationSearchSettings.from(
            blockConfig: block(["location_type": "", "location_bias_country": "   ", "location_language": ""]),
            defaultMinChars: 3
        )
        XCTAssertNil(s.type)
        XCTAssertNil(s.biasCountry)
        XCTAssertNil(s.language)
    }

    func testMinCharsFallsBackToTheSurfacesOwnDefault() {
        // 2 in a form-step field, 3 in a content block — each surface's long-standing threshold, and
        // 3 is what the Console seeds on a new block. Preserved rather than unified, so no published
        // flow changes.
        XCTAssertEqual(LocationSearchSettings.from(blockConfig: [:], defaultMinChars: 3).minChars, 3)
        XCTAssertEqual(LocationSearchSettings.from(blockConfig: [:], defaultMinChars: 2).minChars, 2)
    }

    func testMinCharsNeverDropsBelowOne() {
        // 0 would search an empty field: a request the proxy rejects and a dropdown nobody asked for.
        XCTAssertEqual(
            LocationSearchSettings.from(blockConfig: block(["location_min_chars": 0]), defaultMinChars: 3).minChars, 1)
        XCTAssertEqual(
            LocationSearchSettings.from(blockConfig: block(["location_min_chars": -4]), defaultMinChars: 3).minChars, 1)
    }

    func testMinCharsAcceptsTheNumberShapesAJSONDecodeProduces() {
        // Firestore and a JSON round-trip both hand back a Double where the Console wrote an Int —
        // and the old inline read was `as? Int`, which returns nil for one of them.
        XCTAssertEqual(
            LocationSearchSettings.from(blockConfig: block(["location_min_chars": 4.0]), defaultMinChars: 3).minChars, 4)
        XCTAssertEqual(
            LocationSearchSettings.from(blockConfig: block(["location_min_chars": NSNumber(value: 4)]), defaultMinChars: 3).minChars, 4)
        // A non-number is not a threshold: fall back rather than search from 1.
        XCTAssertEqual(
            LocationSearchSettings.from(blockConfig: block(["location_min_chars": "four"]), defaultMinChars: 3).minChars, 3)
    }

    func testNilConfigResolvesToTheSurfacesDefaults() {
        let s = LocationSearchSettings.from(blockConfig: nil, defaultMinChars: 3)
        XCTAssertNil(s.type)
        XCTAssertEqual(s.minChars, 3)
    }

    // MARK: - from a form-step field's typed FormFieldConfig

    func testTypedOverloadResolvesIdenticallyToTheMapOne() {
        /*
         * The two surfaces take their config from different shapes — a content block carries a
         * free-form map, a form field a typed `FormFieldConfig` — and must still land on the same
         * answer. This is the assertion that keeps the two overloads from drifting, which is the same
         * failure as the two search calls that caused this issue.
         */
        let fromMap = LocationSearchSettings.from(
            blockConfig: block([
                "location_type": "region",
                "location_bias_country": "DE",
                "location_language": "de",
                "location_min_chars": 4,
            ]),
            defaultMinChars: 2
        )
        let json = """
        {"location_type":"region","location_bias_country":"DE","location_language":"de","location_min_chars":4}
        """
        let typed = try! JSONDecoder().decode(FormFieldConfig.self, from: Data(json.utf8))
        let fromTyped = LocationSearchSettings.from(fieldConfig: typed, defaultMinChars: 2)
        XCTAssertEqual(fromMap, fromTyped)
    }

    func testTypedOverloadTreatsBlanksAndNilsTheSameWay() {
        let json = """
        {"location_type":"","location_language":"  "}
        """
        let typed = try! JSONDecoder().decode(FormFieldConfig.self, from: Data(json.utf8))
        let s = LocationSearchSettings.from(fieldConfig: typed, defaultMinChars: 2)
        XCTAssertNil(s.type)
        XCTAssertNil(s.biasCountry)
        XCTAssertNil(s.language)
        XCTAssertEqual(s.minChars, 2)
    }

    func testATypeTheProxyDoesNotAcceptResolvesToUnsetNotForwarded() {
        /*
         * 🔴 THE REGRESSION THE LOCATION-TYPE CHANGE WOULD HAVE SHIPPED. The proxy validates `type` against
         * `z.enum(['city','address','region','country'])` and answers anything else with a
         * ValidationError — which both SDKs read as "no suggestions". So forwarding a bad value
         * turns the whole autocomplete OFF rather than degrading it.
         *
         * `coordinates` is the real one: content-block `field_config` is `.passthrough()` and so
         * UNVALIDATED, and the Console's content-block Location Type select offered it. Those
         * blocks were harmless only while this surface sent no `type` at all.
         */
        for bad in ["coordinates", "Address", "anything"] {
            XCTAssertNil(
                LocationSearchSettings.from(blockConfig: block(["location_type": bad]), defaultMinChars: 3).type,
                "\(bad) must not be forwarded to the proxy")
        }
        // ...and the four it DOES accept still pass through, including `region`, which the
        // content-block picker was missing while offering `coordinates`.
        for good in ["city", "address", "region", "country"] {
            XCTAssertEqual(
                LocationSearchSettings.from(blockConfig: block(["location_type": good]), defaultMinChars: 3).type,
                good)
        }
    }
}
