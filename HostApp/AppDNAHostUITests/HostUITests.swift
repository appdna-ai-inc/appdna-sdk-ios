// HostUITests.swift — #908
//
// 🔴 THE SIMULATOR DOES HAVE A TAP. It has no tap verb exposed to a shell on another machine —
// no `simctl` verb, no `idb`, `osascript` blocked — which is what every "iOS unproven" note on
// this branch has been about. A UI test runs INSIDE the simulator and taps, swipes, types and
// scrolls like a finger, so iOS can be operated after all (Rule 24); it just needs an application
// target to attach to, which is what #908 builds.
//
// These tests are deliberately about the HOST, not about a surface: a surface needs a backend and
// a key, which the public mirror must not carry. `scripts/sdk-host-ios.ts` supplies those at run
// time for a real walk.
import XCTest

final class HostUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launched(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extra
        app.launch()
        return app
    }

    func testTheHostShowsTheFourSurfaceButtons() {
        let app = launched()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 10))
        for id in ["onboarding", "paywall", "survey", "screen"] {
            XCTAssertTrue(
                app.buttons["host.\(id)"].exists,
                "the host must offer every surface the Android sample does, or a walk has no counterpart",
            )
        }
    }

    /// The claim this whole target exists to make: a tap is DISPATCHED and the app responds to it.
    /// Without a key the paywall cannot load, so what is asserted is that the tap was received and
    /// the host stayed alive — which is the capability, not the content.
    func testAButtonCanActuallyBeTapped() {
        let app = launched()
        let paywall = app.buttons["host.paywall"]
        XCTAssertTrue(paywall.waitForExistence(timeout: 10))
        XCTAssertTrue(paywall.isHittable, "a button a test cannot hit is a button a walk cannot operate")
        paywall.tap()
        XCTAssertEqual(app.state, .runningForeground, "the host must survive the tap")
        XCTAssertTrue(app.buttons["host.paywall"].waitForExistence(timeout: 5))
    }

    func testAutoPresentIsAcceptedAsALaunchArgument() {
        let app = launched(["-appdnaAutoPresent", "paywall", "-appdnaAutoPresentDelay", "1"])
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
