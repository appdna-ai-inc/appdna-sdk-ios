import XCTest
@testable import AppDNASDK

/// A null is not text. Wherever a template token resolves to one (a null trait identify kept, a JSON null
/// in hook data) it is unresolved: the `| fallback` applies, else the token renders as nothing. It never
/// prints `<null>`. The shared fixture `user_trait_null_takes_fallback` covers `TemplateEngine` with the
/// stored `NSNull`; these cover the forms a fixture cannot carry, and the content-block resolver.
final class TemplateNullValueTests: XCTestCase {

    private func context(_ traits: [String: Any]) -> TemplateContext {
        TemplateContext(
            userTraits: traits, remoteConfig: { _ in nil }, onboardingResponses: [:],
            computedData: [:], sessionData: [:], deviceInfo: [:]
        )
    }

    func testTemplateEngineTreatsAnOptionalNilTraitAsUnset() {
        let name: String? = nil
        let out = TemplateEngine.shared.interpolate("Hi {{user.name | there}}", context: context(["name": name as Any]))
        XCTAssertEqual(out, "Hi there")
    }

    func testTemplateEngineUnwrapsASetOptionalTrait() {
        let name: String? = "Ana"
        let out = TemplateEngine.shared.interpolate("Hi {{user.name | there}}", context: context(["name": name as Any]))
        XCTAssertEqual(out, "Hi Ana")
    }

    func testContentBlockResolverTakesTheFallbackForANull() {
        let out = resolveTemplateString(
            "Hi {{user.name | there}} [{{hook_data.badge | none}}]",
            hookData: ["badge": NSNull()], responses: [:], userTraits: ["name": NSNull()]
        )
        XCTAssertEqual(out, "Hi there [none]")
    }
}
