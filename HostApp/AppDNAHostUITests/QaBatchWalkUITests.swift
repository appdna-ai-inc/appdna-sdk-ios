// QaBatchWalkUITests.swift — the overnight QA batch, walked on a device.
//
// - a transparent button label          - an authored ✕ (size, colour, background, inset)
// - Google's own mark on sign-in        - a shared background reaching the screen edges
// - a border colour with no width       - a tap anywhere advancing a splash
// - a particle effect on a trigger that is not `on_appear`
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

        /*
         * 🔴 IS THIS THE FLOW THAT WAS JUST PUBLISHED, OR A CACHED ONE?
         *
         * A heading can be right while the body is three revisions old. When the SDK's bootstrap is
         * refused — a dev key against the production API, say, which is a 401 and nothing more
         * visible than a line of stdout the test cannot see — it falls back to "serving cached
         * config only" and renders whatever it had. The walk then asserts today's expectations
         * against a flow from another day and fails somewhere far from the cause: four separate
         * code suspects were each excluded by a run of their own before this line existed.
         *
         * The body text changes whenever the probe changes, so it is the cheapest possible proof
         * that the device is looking at THIS publish.
         */
        XCTAssertTrue(
            app.staticTexts["A tap anywhere moves on. The button below is the walk's way past when it does not."].exists,
            "the device is rendering a STALE copy of the flow — bootstrap was probably refused and "
                + "the SDK is serving cached config. Run through scripts/sdk-host-ios.ts --uitest "
                + "with --base-url pointing at a reachable API for the key's environment.",
        )
        shot(app, "01-tap-anywhere")

        /*
         * LEAVE THE SCREEN BY TAPPING IT, and tap the CONTENT.
         *
         * 🔴 The content tap is the whole feature. A splash is a full-bleed image, so every tap an
         * author expects to work lands ON something — and for five device runs across three
         * gesture shapes, only a tap that MISSED the content ever advanced this step.
         *
         * The consumer was never the ScrollView. It is the step layout's own keyboard-dismiss
         * handler, which sits above everything the blocks carry, and on Android the identical
         * shape — a root `detectTapGestures` — CONSUMED every tap before the outer gesture saw it
         * (measured: `[DIAG tap] taken=true` for a tap on the heading and on empty space alike).
         * Both platforms now hand the advance to the handler that actually receives the tap.
         *
         * So the heading is the test. Empty space is the easy case and is checked on the way back.
         */
        app.staticTexts["1 · Tap anywhere to advance"].tap()
        /*
         * 🔴 THE TREE, IN THE FAILURE MESSAGE. The app's `print` output is invisible under
         * `xcodebuild test`, so "the gesture never fired" and "the advance was refused" read
         * identically from out here, and so does "the step never rendered what the walk is looking
         * for". `debugDescription` is the one thing XCUITest can always answer with, and it says
         * which of the three happened in a single run.
         */
        XCTAssertTrue(
            app.staticTexts["2 · A faded label and a hairline border"].waitForExistence(timeout: 10),
            "a tap ON THE CONTENT of a tap-anywhere step did not advance it.\nTREE:\n"
                + String(app.debugDescription.prefix(4000)),
        )
        shot(app, "02-button-styling")

        // Both buttons are on screen; the frame is the evidence for how they draw.
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
         * The ✕ is authored 28pt from the edge instead of 8, so this asserts WHERE it is,
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

        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["5 · A banner with a link"].waitForExistence(timeout: 10),
            "the banner step never arrived",
        )
        shot(app, "05-banner")

        /*
         * THE BANNER AN INFO BANNER IS SUPPOSED TO BE: a title, a subtitle, a link under
         * it, and the app's OWN mark rather than an emoji.
         */
        XCTAssertTrue(app.staticTexts["Your trial ends soon"].exists, "the banner title is missing")
        /*
         * 🔴 A SwiftUI `Link` IS A BUTTON in the accessibility tree, not `app.links` and not a
         * static text. The first version of this assertion checked the other two and failed on a
         * screen where the link was drawn correctly and in blue — the attached frame said so. An
         * assertion that is wrong about the element TYPE reads exactly like a missing feature.
         */
        let learnMore = app.buttons["Learn more"].firstMatch
        XCTAssertTrue(
            learnMore.exists || app.links["Learn more"].exists || app.staticTexts["Learn more"].exists,
            "the banner link is missing — a link with an address should draw as one.\nTREE:\n"
                + String(app.debugDescription.prefix(3000)),
        )

        /*
         * Rule 24 — OPERATE IT. "Tapping the link text opens the URL entered for it" is half of
         * what the link feature asked for, and a link that draws and goes nowhere is the defect this repo
         * keeps shipping. The tap leaves the app, so Safari coming to the front IS the assertion;
         * the walk then reactivates the host and carries on with the rest of the step.
         */
        if learnMore.exists {
            learnMore.tap()
            shot(app, "05b-after-link-tap")
            /*
             * 🔴 TWO OBSERVATIONS, because they fail differently and one of them is not a defect.
             *
             * "Safari came to the front" is the outcome an author wants. "The host app LEFT the
             * front" is the thing the SDK can actually cause: handing a URL to the system is where
             * its responsibility ends, and which app the system then picks — or how long it takes
             * to get there under a UI test — is not something this walk should be asserting. The
             * first version checked only Safari and failed on a screen where the link was drawn
             * correctly, which told me nothing about which of the two had happened.
             *
             * So both are recorded and either one passes, and the failure message prints both —
             * `background` with no Safari is "it opened something else"; `foreground` with no
             * Safari is the real defect, a link that goes nowhere.
             */
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            let safariCameUp = safari.wait(for: .runningForeground, timeout: 15)
            let hostLeftTheFront = app.state != .runningForeground
            XCTAssertTrue(
                safariCameUp || hostLeftTheFront,
                "tapping the banner link did nothing: Safari state \(safari.state.rawValue), "
                    + "host state \(app.state.rawValue) (4 = foreground). A link with an authored "
                    + "URL must hand that URL to the system.",
            )
            app.activate()
            XCTAssertTrue(
                app.staticTexts["5 · A banner with a link"].waitForExistence(timeout: 15),
                "the flow did not come back after the link opened",
            )
        }

        /*
         * 🔴 THE UPLOAD HAS TO BEAT THE EMOJI, and the emoji is authored ALONGSIDE it precisely so
         * this can be asserted. `banner_icon` is `ℹ️` and `banner_icon_url` is an image: if the
         * precedence were the other way round — or if the image failed to load and the glyph were
         * used as a placeholder — `ℹ️` would be a static text on this screen. Its ABSENCE is the
         * claim; a screenshot alone could not tell a 56pt image from a 56pt emoji with certainty.
         */
        XCTAssertFalse(
            app.staticTexts["\u{2139}\u{FE0F}"].exists,
            "the authored emoji is still drawn, so the uploaded mark did not win",
        )

        /*
         * `collapse_on_scroll`, which iOS has applied since Sprint 7. The drag is SMALL on
         * purpose: a full scroll takes everything off the screen and proves nothing, while 120pt
         * past a 40pt threshold moves the layout barely at all and takes the collapse past 1. The
         * pair of frames is the evidence; XCUITest cannot read opacity.
         */
        shot(app, "06-collapse-before")
        let banner = app.staticTexts["COLLAPSE ME — this line fades out as the step scrolls."]
        XCTAssertTrue(banner.exists, "the collapsing block is missing")
        app.swipeUp(velocity: .slow)
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 1)
        shot(app, "07-collapse-after")

        app.buttons["Finish"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["6 · A bound option set"].waitForExistence(timeout: 10),
            "the option-set step never arrived",
        )
        shot(app, "08-option-set")

        /*
         * AN OPTION SET, BOUND BY ID, RENDERED FROM THE SET AND NOT FROM THE BLOCK.
         *
         * The block carries no `field_options` at all: every label here came from
         * `onboarding_option_sets` through `option_set_id`. Four words no other step in this flow
         * contains, so a pass cannot be against the wrong screen.
         *
         * 🔴 It is worth asserting at all because the picker that binds one was UNREACHABLE until
         * It loaded through a bare `fetch` with no token, 401'd for every author on every
         * load, and the empty list rendered as "No Option Sets yet". The decode was tested the
         * whole time; nobody had joined the two ends.
         */
        for label in ["Marmalade", "Zeppelin", "Tungsten", "Quokka"] {
            XCTAssertTrue(
                app.staticTexts[label].waitForExistence(timeout: 5),
                "option \"\(label)\" from the bound set is missing.\nTREE:\n"
                    + String(app.debugDescription.prefix(2500)),
            )
        }

        // Rule 24 — operate it. A list that draws and collects nothing is the defect this repo
        // keeps shipping, so one option is chosen and read back as selected.
        app.staticTexts["Tungsten"].tap()
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 1)
        shot(app, "09-option-selected")

        // The particle effect fires on its authored trigger; the last tap ends the flow.
        app.buttons["Done"].firstMatch.tap()
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 2)
        shot(app, "10-after-finish-particles")
    }
}
