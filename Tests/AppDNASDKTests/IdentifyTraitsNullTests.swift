import XCTest
@testable import AppDNASDK

/// A JSON null in an identify trait is kept, however the host spells it.
///
/// `NSNull` is what a channel or a decoded JSON object carries, and the shared fixture
/// `identify_trait_null_values` covers it. A Swift host can also put an optional straight into
/// `[String: Any]` (`["referrer": referrer as Any]`); boxed in `Any`, a `nil` is neither `NSNull` nor
/// a JSON value, so it has to be recognised as the null it stands for, and a set optional as its value.
final class IdentifyTraitsNullTests: XCTestCase {

    func testAnOptionalNilIsKeptAsNullAndASetOptionalAsItsValue() {
        let referrer: String? = nil
        let city: String? = nil
        let seats: Int? = 3
        let traits: [String: Any] = [
            "plan": "pro",
            "referrer": referrer as Any,
            "seats": seats as Any,
            "home": ["formatted_address": "1 Example Street", "city": city as Any, "latitude": 1.5] as [String: Any],
            "tags": ["a", referrer as Any] as [Any],
            "explicit": NSNull(),
        ]

        let out = IdentifyTraits.sanitize(traits, log: false)

        XCTAssertEqual(Set(out.keys), ["plan", "referrer", "seats", "home", "tags", "explicit"])
        XCTAssertTrue(out["referrer"] is NSNull)
        XCTAssertTrue(out["explicit"] is NSNull)
        XCTAssertEqual(out["seats"] as? Int, 3)
        let home = out["home"] as? [String: Any]
        XCTAssertTrue(home?["city"] is NSNull, "an unset location key is kept as null")
        XCTAssertEqual((out["tags"] as? [Any])?.count, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(out), "what is kept can be written as JSON")
    }
}
