// QaBatchWalkUITests.swift — the overnight QA batch, walked on a device.
//
// #1000 a transparent button label      #1004 an authored ✕ (size, colour, background, inset)
// #1003 Google's own mark on sign-in    #1006 a shared background reaching the screen edges
// #1007 a border colour with no width   #1014 a tap anywhere advancing a splash
// #997  a particle effect on a trigger that is not `on_appear`
//
// 🔴 EVERY SCREEN, AND THE ELEMENTS ON IT (CLAUDE.md Rules 23/24). Each of these is a render
// change, so a screenshot of the first step proves nothing about the fourth. The walk advances
// through all four, attaches a frame per screen, and OPERATES what the change is about: step one
// is left by tapping the middle of the screen — the feature — rather than by a button, and the
// close control is asserted where an author moved it to.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class QaBatchWalkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.flowId.isEmpty ? nil : TestCredentials.flowId }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTheQaBatchWalksOnADevice() throws {
        guard let apiKey, let flowId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaFlow", flowId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["1 · Tap anywhere to advance"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the flow never presented — config did not arrive")
        shot(app, "01-tap-anywhere")

        /*
         * #1014 — LEAVE THE SCREEN BY TAPPING IT. There is no button on this step, which is the
         * whole point: before this, the only way off a screen like this was the corner ✕. The tap
         * lands in the middle of the window, on nothing in particular.
         */
        /*
         * 🔴 #1014 IS HALF WORKING, AND THIS IS THE HALF THAT DOES — measured, not assumed.
         *
         * A tap in EMPTY SPACE below the step's content advances it (this assertion, which passed
         * on the first run of this walk). A tap ON the step's own text does NOT: three runs, three
         * gesture shapes, nothing. The step's content lives inside a scroll view, which claims the
         * touch sequence, so the gesture only sees taps that miss the content.
         *
         * That difference is the whole remaining defect — on a splash whose content is a
         * full-bleed image, the image IS the screen and the feature would do nothing. It is
         * recorded on #1014 rather than papered over here, and the walk taps where it works so the
         * screens AFTER this one can be proven.
         */
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(
            app.staticTexts["2 · A faded label and a hairline border"].waitForExistence(timeout: 10),
            "a tap in the empty area of a tap-anywhere step did not advance it",
        )
        shot(app, "02-button-styling")

        // #1000 / #1007 — both buttons are on screen; the frame is the evidence for how they draw.
        XCTAssertTrue(app.buttons["Half-transparent label"].exists, "the faded-label button is missing")
        XCTAssertTrue(app.buttons["Border colour, no width"].exists, "the border-colour button is missing")

        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["3 · Shared background, edge to edge"].waitForExistence(timeout: 10),
            "the multi-buttons step never arrived",
        )
        shot(app, "03-multi-buttons")
        for label in ["One", "Two", "Three"] {
            XCTAssertTrue(app.buttons[label].exists, "multi-buttons child \"\(label)\" is missing")
        }

        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["4 · Google's own mark"].waitForExistence(timeout: 10),
            "the social-login step never arrived",
        )
        shot(app, "04-social-login")
        XCTAssertTrue(app.buttons["Continue with Google"].exists, "the Google button is missing")

        /*
         * #1004 — the ✕ is authored 28pt from the edge instead of 8, so this asserts WHERE it is,
         * not just that it exists: "pushed as far as possible into the top-right corner, which
         * makes it hard to tap" was half the report.
         */
        let close = app.buttons.matching(identifier: "appdna.dismiss").firstMatch
        if close.exists {
            let frame = close.frame
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(
                window.maxX - frame.maxX, 8,
                "the close control is still jammed against the edge",
            )
        }

        // #997 — the particle effect fires on `on_flow_complete`, which is the last tap.
        app.buttons["Finish"].firstMatch.tap()
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 2)
        shot(app, "05-after-finish-particles")
    }
}
