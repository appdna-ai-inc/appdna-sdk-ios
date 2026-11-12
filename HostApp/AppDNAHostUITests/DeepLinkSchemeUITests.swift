import XCTest

/// The host declares the synthetic `appdnasample` scheme and routes `onOpenURL` to
/// `AppDNA.deepLinks.handleURL`: a URL the OS opens reaches the SDK's deep-link delegate, which the
/// host mirrors into `host.lastEvents`. THE CONTROL: a URL the host never received is not there.
final class DeepLinkSchemeUITests: XCTestCase {
    func testASampleSchemeURLReachesTheDeepLinkHandler() throws {
        // `XCUIApplication.open(_:)` is iOS 16.4+, and the host (like the SDK) targets iOS 16.0: the
        // call is gated so the UI-test target compiles at the host's own deployment target.
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("XCUIApplication.open(_:) needs iOS 16.4; this simulator is older")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 15))
        let events = app.staticTexts["host.lastEvents"]
        XCTAssertFalse((events.label).contains("deeplink:appdnasample://demo/offer"), "control: not there before the open")

        app.open(URL(string: "appdnasample://demo/offer?src=walk")!)
        let reached = NSPredicate(format: "label CONTAINS %@", "deeplink:appdnasample://demo/offer")
        expectation(for: reached, evaluatedWith: events)
        waitForExpectations(timeout: 15)
    }
}
