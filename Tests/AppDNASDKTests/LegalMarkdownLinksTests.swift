import XCTest
@testable import AppDNASDK

/**
 SPEC-485 (#649) — the paywall legal `[label](url)` parser.

 This is the function both iOS legal renderers now call. It used to be a `private func` on
 `PaywallRenderer`, unreachable from `LegalSectionView` in the Screens/Sections wrapper, which
 therefore drew a plain `Text` and showed the brackets literally.

 Unit-tested rather than snapshotted because there is no paywall visual-snapshot harness, and the
 wiring — that BOTH renderers call this and tint the result — is pinned by
 `scripts/__tests__/legal-link-parity.test.ts`. What is worth executing is the parsing itself.
 */
final class LegalMarkdownLinksTests: XCTestCase {

    /// The plain-text projection, so assertions read as what a user sees.
    private func plain(_ attr: AttributedString) -> String {
        String(attr.characters)
    }

    private func links(_ attr: AttributedString) -> [URL] {
        attr.runs.compactMap { $0.link }
    }

    func testStripsTheMarkdownAndKeepsTheLabel() throws {
        let out = legalMarkdownLinks("See our [Terms](https://appdna.ai/terms) before subscribing.")
        XCTAssertEqual(plain(out), "See our Terms before subscribing.")
        XCTAssertEqual(links(out).map(\.absoluteString), ["https://appdna.ai/terms"])
    }

    func testParsesSeveralLinksInOneLine() throws {
        let out = legalMarkdownLinks("[Terms](https://a.co/t) and [Privacy](https://a.co/p) apply.")
        XCTAssertEqual(plain(out), "Terms and Privacy apply.")
        XCTAssertEqual(links(out).map(\.absoluteString), ["https://a.co/t", "https://a.co/p"])
    }

    func testTextWithNoLinksIsUnchanged() throws {
        let text = "Subscription auto-renews unless cancelled 24 hours before the period ends."
        XCTAssertEqual(plain(legalMarkdownLinks(text)), text)
        XCTAssertTrue(links(legalMarkdownLinks(text)).isEmpty)
    }

    /// The case that matters for a rollback: unbalanced or half-typed syntax must not eat the line.
    func testMalformedSyntaxLeavesTheTextIntact() throws {
        for text in [
            "See our [Terms(https://a.co)",     // missing ]
            "See our Terms](https://a.co)",     // missing [
            "See our [Terms]",                  // no url part
            "See our [](https://a.co)",         // empty label
        ] {
            XCTAssertEqual(plain(legalMarkdownLinks(text)), text, "mangled: \(text)")
        }
    }

    func testAnInvalidUrlStillRendersTheLabel() throws {
        // A half-typed URL is the state the console's Link button leaves behind on purpose
        // (`[Terms](https://)`), so it must not drop the label the author can already see.
        let out = legalMarkdownLinks("See our [Terms](https://)")
        XCTAssertEqual(plain(out), "See our Terms")
    }

    func testTextAroundTheLinkIsPreserved() throws {
        let out = legalMarkdownLinks("Billed monthly. [Cancel anytime](https://a.co/c). Taxes may apply.")
        XCTAssertEqual(plain(out), "Billed monthly. Cancel anytime. Taxes may apply.")
    }

    func testEmptyStringIsSafe() throws {
        XCTAssertEqual(plain(legalMarkdownLinks("")), "")
    }
}
