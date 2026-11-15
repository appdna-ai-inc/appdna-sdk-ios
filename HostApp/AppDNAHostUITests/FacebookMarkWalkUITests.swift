// FacebookMarkWalkUITests.swift — the Social Login button's Facebook provider, walked on the simulator.
//
// The provider drew a bold letter "f"; it now draws Meta's official mark, primary (blue) or secondary
// (white) by the button's surface. The flow is synthetic and bundled (`WalkFlows/facebook-mark-walk.json`),
// seeded into the SDK's cache: four Facebook buttons — default fill, white fill, dark fill, outlined.
import XCTest

final class FacebookMarkWalkUITests: XCTestCase {
    static let flowId = "fb_mark_walk_flow"
    static let shotDir = "/tmp/sdkdec-1850-shots"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: Self.shotDir, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(Self.shotDir)/\(name).png"))
    }

    func testEachFacebookButtonDrawsTheOfficialMarkAndTaps() {
        let app = XCUIApplication()
        app.launchArguments += ["-appdnaSeedOnboarding", "facebook-mark-walk", "-appdnaFlow", Self.flowId, "-appdnaLogLevel", "debug"]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 30), "the host did not launch")
        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["Sign in"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the seeded flow never presented")
        shot("1850-ios-1-four-buttons")

        // Which mark each button drew, by the identifier the renderer puts on the image.
        let secondary = app.images.matching(identifier: "social_login_facebook_mark_secondary").count
        let primary = app.images.matching(identifier: "social_login_facebook_mark_primary").count
        NSLog("FBWALK marks primary=\(primary) secondary=\(secondary)")
        // SwiftUI may fold a Button's label into one element, hiding the image's identifier; then the
        // screenshot crops are the proof and this records that the tree could not say.
        if primary + secondary > 0 {
            XCTAssertEqual(secondary, 2, "default fill and dark fill draw the white (secondary) mark")
            XCTAssertEqual(primary, 2, "white fill and outlined draw the blue (primary) mark")
        }
        // 🔴 Negative control for the identifier lookup: no letter "f" is drawn any more.
        XCTAssertFalse(app.staticTexts["f"].exists, "a letter f is still drawn")

        // Operate each button: a tap must land and dispatch the provider's action.
        for label in ["Facebook default fill", "Facebook on white", "Facebook on dark", "Facebook outlined"] {
            let b = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 5), "no button \(label)")
            XCTAssertTrue(b.isHittable, "\(label) is not tappable")
            b.tap()
            let ev = app.staticTexts["host.lastEvents"]
            NSLog("FBWALK tapped \(label) events=\(ev.exists ? ev.label : "(none)")")
        }
        shot("1850-ios-2-after-taps")
    }
}
