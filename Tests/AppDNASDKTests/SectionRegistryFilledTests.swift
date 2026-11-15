import XCTest
@testable import AppDNASDK

/// The shared section registry is filled without anyone asking: nothing in the SDK used to call
/// `registerBuiltInSections()` / `registerModuleSections()` outside the tests, so every server-driven screen drew its
/// background and no sections.
/// No test registers the MODULE sections, so `paywall_plans` on `shared` can only be there because `shared` filled
/// itself — whatever order the suite runs in. RED CONTROL: `static let shared = SectionRegistry()` fails it.
final class SectionRegistryFilledTests: XCTestCase {
    func testTheSharedRegistryHoldsTheBuiltInAndModuleSections() {
        for type in ["paywall_plans", "paywall_cta", "cta_footer", "hero", "content_blocks"] {
            XCTAssertTrue(SectionRegistry.shared.hasRenderer(for: type), "\(type) has no renderer on the shared registry")
        }
    }

    func testAFreshRegistryIsEmptyUntilFilled() {
        // The harness can tell the two apart: a bare registry knows nothing.
        XCTAssertFalse(SectionRegistry().hasRenderer(for: "paywall_plans"))
        XCTAssertTrue(SectionRegistry.makeFilled().hasRenderer(for: "paywall_plans"))
    }
}
