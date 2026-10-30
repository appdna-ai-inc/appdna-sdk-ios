import XCTest
@testable import AppDNASDK

/**
 The URL rule, exercised rather than read.

 🔴 The cases are the point, not the regex. `URL(string: "not a url")` returns a NON-NIL relative
 URL rather than nil, so a check written the obvious way accepts everything — which is why the rule
 is a deliberate pattern and why these cases exist to pin what it means.

 The same list runs against the Kotlin twin in `FormFieldFormatsTest.kt`, and
 `scripts/__tests__/default-user-copy-parity.test.ts` asserts the two patterns are identical
 character for character.
 */
final class FormFieldFormatsTests: XCTestCase {

    private let accepted = [
        "example.com",
        "https://example.com",
        "http://example.com",
        "HTTP://Example.COM/a?b=1#c",
        "sub.example.co.uk:8080/path",
        "  example.com  ",
        "a-b.example.com",
    ]

    private let rejected = [
        "not a url",
        "example",
        "http://",
        "https://example",
        "a b.com",
        "",
        "   ",
        "example..com",
    ]

    func testAcceptsTheShapesTheRuleDescribes() {
        for value in accepted {
            XCTAssertTrue(FormFieldFormats.looksLikeURL(value), "\(value) should be accepted")
        }
    }

    func testRejectsWhatIsNotAURL() {
        for value in rejected {
            XCTAssertFalse(FormFieldFormats.looksLikeURL(value), "\(value) should be rejected")
        }
    }

    /// The control that says Foundation alone would NOT have done this job.
    func testFoundationAloneWouldHaveAcceptedEverything() {
        XCTAssertNotNil(
            URL(string: "not a url".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
            "if this ever becomes nil, the pattern may no longer be the only strict check",
        )
        XCTAssertFalse(FormFieldFormats.looksLikeURL("not a url"))
    }

    /// The scheme is optional ON PURPOSE — pinned so nobody tightens it without meaning to.
    func testABareHostIsAURL() {
        XCTAssertTrue(FormFieldFormats.looksLikeURL("appdna.ai"))
    }
}
