import XCTest

/// The host declares the synthetic `appdnasample` scheme and routes `onOpenURL` to
/// `AppDNA.deepLinks.handleURL`: a URL the OS opens reaches the SDK's deep-link delegate, which the
/// host mirrors into `host.lastEvents`. THE CONTROL: a URL the host never received is not there.
final class DeepLinkSchemeUITests: XCTestCase {
    func testASampleSchemeURLReachesTheDeepLinkHandler() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 15))
        /*
         `XCUIApplication.open` hands the URL to the app through XCTest without asking LaunchServices,
         so it reaches `onOpenURL` even when the build declares no scheme at all. The OS only
         routes `appdnasample://` from a CTA, a push or Safari when `CFBundleURLTypes` declares it, and
         `URLSafety.hostSchemes` reads the same key — so the declaration is asserted directly.
         */
        let schemes = app.staticTexts["host.urlSchemes"]
        XCTAssertTrue(schemes.waitForExistence(timeout: 5))
        XCTAssertTrue(schemes.label.contains("appdnasample"),
                      "the host must declare the appdnasample scheme in CFBundleURLTypes; got '\(schemes.label)'")

        let events = app.staticTexts["host.lastEvents"]
        XCTAssertFalse((events.label).contains("deeplink:appdnasample://demo/offer"), "control: not there before the open")

        // `XCUIApplication.open(_:)` exists from iOS 16.4; the host deploys to 16.0.
        guard #available(iOS 16.4, *) else { throw XCTSkip("XCUIApplication.open needs iOS 16.4") }
        app.open(URL(string: "appdnasample://demo/offer?src=walk")!)
        let reached = NSPredicate(format: "label CONTAINS %@", "deeplink:appdnasample://demo/offer")
        expectation(for: reached, evaluatedWith: events)
        waitForExpectations(timeout: 15)
    }
}
