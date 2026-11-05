import XCTest
@testable import AppDNASDK

/// Runs INSIDE the host app, so `Bundle.main` is the host's real Info.plist: the custom-scheme CTA a
/// message or push carries (`appdnasample://…`) passes the SDK's URL policy, the check every CTA and
/// deep-link open goes through (`URLSafety.sanitized`). THE CONTROL: an undeclared custom scheme is refused.
final class HostURLSchemeHostedTests: XCTestCase {
    func testTheSampleSchemeIsAnAllowedDeepLinkBackIntoTheHost() {
        XCTAssertTrue(URLSafety.hostSchemes.contains("appdnasample"), "the host declares no appdnasample scheme: \(URLSafety.hostSchemes)")
        XCTAssertNotNil(URLSafety.sanitized("appdnasample://demo/offer"), "a sample-scheme CTA is refused")
        XCTAssertNil(URLSafety.sanitized("notdeclaredscheme://demo/offer"), "control: an undeclared scheme is refused")
    }
}
