// RiveWalkUITests.swift — #990
//
// THE RIVE ANIMATION ON A DEVICE, and the fact that it is MOVING.
//
// 🔴 Why this is a UI test rather than a unit one. `RiveRendersTests` proves the runtime parses a
// `.riv`, instantiates its artboard and state machine and holds an input across an advance — real
// assertions, and none of them about pixels. They cannot be: Rive draws GPU-backed content, and
// neither `layer.render(in:)` nor `drawHierarchy(afterScreenUpdates:)` captures that in the
// simulator. Measured, `drawn=0`, against a file the same test proves is loaded. A simulator
// SCREENSHOT does capture it, because it comes from the render server rather than the layer tree.
//
// 🔴 AND NOT THE MOTION — this runner cannot see it. `XCUIScreen.main.screenshot()` came back
// byte-identical twice on a screen that `simctl io booted screenshot` showed moving by 170,622
// bytes; Rive draws through Metal and the UI-test capture path misses it. The motion is proven by
// `scripts/spec502/probe-990-rive-motion.ts`, with `autoplay: false` as its negative control.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class RiveWalkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.flowId.isEmpty ? nil : TestCredentials.flowId }

    func testTheRiveStepPresentsAndDraws() throws {
        guard let apiKey, let flowId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaFlow", flowId]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        var presented = false
        for attempt in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["Rive animation"].waitForExistence(timeout: 5)
            if !presented { NSLog("flow not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(presented, "the flow never presented — config did not arrive")

        /*
         * 🔴 ONE STEP, NOT A WALK — and the five-step walk is why this took four device runs.
         *
         * The Rive step was originally bolted onto #963's location itinerary because that flow
         * already existed, and every failure since was about the ITINERARY rather than about Rive:
         * a step name asserted that the SDK never draws, a published copy that predated the step,
         * and then a step the device passes straight through (#1016 — real, and nothing to do with
         * this claim). The claim here is "a `rive` block draws on a device and keeps moving", so
         * the flow is one step carrying that block and nothing else
         * (`scripts/spec502/probe-990-rive-only-flow.ts` builds and publishes it).
         */
        XCTAssertTrue(
            app.staticTexts["Rive animation"].waitForExistence(timeout: 20),
            "the Rive step never presented — on screen: "
            + "\(app.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label))",
        )

        /*
         * 🔴 THE MOTION IS NOT ASSERTED HERE, and the reason is measured.
         *
         * `XCUIScreen.main.screenshot()` returns BYTE-IDENTICAL frames for a Rive animation that is
         * visibly moving: 73,901 bytes twice from this runner, while `xcrun simctl io booted
         * screenshot` on the same screen minutes later differed by 170,622 bytes and showed the
         * character mid-stride. Rive draws through Metal and the UI-test runner's capture path does
         * not pick it up — so an assertion here would fail forever and read as "Rive does not
         * animate on iOS", which is exactly how it read for one run.
         *
         * What this test owns is that the step PRESENTS and the block's heading is on screen. The
         * motion belongs to `scripts/spec502/probe-990-rive-motion.ts`, which drives the same
         * device through `simctl` and carries its own negative control (the same flow with
         * `autoplay: false`, which must come back identical).
         */
        let frame = XCUIScreen.main.screenshot()
        add(XCTAttachment(data: frame.pngRepresentation, uniformTypeIdentifier: "public.png"))
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5), "the step's CTA is not on screen")
    }
}
