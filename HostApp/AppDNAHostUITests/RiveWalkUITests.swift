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
// 🔴 ONE FRAME WOULD PROVE THE WRONG THING. A still frame cannot tell a running animation from a
// first frame drawn once and frozen — which is exactly what a broken autoplay looks like. So the
// assertion is that two screenshots taken a second apart DIFFER, the same control
// `LottieRendersTests` uses, and the one that caught `DotLottieFile` drawing an empty frame.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class RiveWalkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.flowId.isEmpty ? nil : TestCredentials.flowId }

    func testTheRiveStepDrawsAndKeepsMoving() throws {
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

        // The runtime fetches the file over the network before it can draw anything.
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 6)

        let first = XCUIScreen.main.screenshot().pngRepresentation
        _ = app.staticTexts["no-such-element"].waitForExistence(timeout: 1.5)
        let second = XCUIScreen.main.screenshot().pngRepresentation

        add(XCTAttachment(data: first, uniformTypeIdentifier: "public.png"))
        add(XCTAttachment(data: second, uniformTypeIdentifier: "public.png"))

        let differing = zip(first, second).reduce(into: 0) { n, pair in if pair.0 != pair.1 { n += 1 } }
        NSLog("[rive-walk] first=\(first.count)B second=\(second.count)B differing=\(differing)")

        XCTAssertNotEqual(
            first, second,
            "two frames of the Rive step 1.5s apart are byte-identical — the animation is a still "
            + "image, or nothing is drawing at all",
        )
    }
}
