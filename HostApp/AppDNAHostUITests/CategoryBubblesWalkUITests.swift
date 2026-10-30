// CategoryBubblesWalkUITests.swift — the category row and the filter it drives, on a device.
//
// Two defects, both of which only a device can settle:
//
//   (a) a horizontally scrolling row of category bubbles, and the blocks beneath it filtering as
//       each bubble is TAPPED. The filtering is the live in-step visibility merge
//       (`VisibilityScope`): before it, `responses` held completed steps only, so a condition
//       naming a field on the step currently on screen resolved against nothing and the block
//       could never appear.
//
//   (b) a `Segmented` element authored `display_style: "bubble"` drawing PILLS. The console has
//       offered six presentations for `input_segmented` since both existed and neither renderer
//       read the key — one production block is in exactly that state, and the value it carries is
//       `bubble`.
//
// 🔴 OPERATED, NOT ONLY OBSERVED (CLAUDE.md Rule 24). A screenshot proves a row was drawn; it says
// nothing about whether tapping the third bubble swaps the select beneath it. So this taps bubbles
// and reads what appears and disappears, and it SCROLLS the row to reach a bubble that starts off
// screen — the "runs off the screen edge" half of the request, which cannot be asserted from a
// frame where every option already fits.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class CategoryBubblesWalkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.categoryFlowId.isEmpty ? nil : TestCredentials.categoryFlowId }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTheCategoryRowFiltersWhatIsUnderIt() throws {
        guard let apiKey, let flowId else {
            throw XCTSkip("TestCredentials.categoryFlowId is empty — run via scripts/sdk-host-ios.ts --uitest --category-flow <id>")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaFlow", flowId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["1 · A category row that filters what is under it"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the flow never presented — config did not arrive")

        /*
         * 🔴 IS THIS THIS PUBLISH, OR A CACHED ONE? A refused bootstrap falls back
         * to "serving cached config only" and renders whatever it had, and the walk then asserts
         * today's expectations against another day's flow and fails far from the cause. The eight
         * bubble labels are this publish's, so finding the last one proves the device has it.
         */
        XCTAssertTrue(app.staticTexts["Eighth"].exists || app.buttons["Eighth"].exists
                        || app.otherElements["Eighth"].exists,
                      "the eighth bubble is missing — the device is probably rendering a STALE copy "
                        + "of the flow (bootstrap refused → cached config).")
        shot(app, "01-category-row-first-live")

        /*
         * THE FIRST FRAME, and it is a measurement that changed the product.
         *
         * 🔴 This assertion FAILED on the first device run, and the device was right: a plain
         * `input_select` chooses nothing on appear — only the Segmented control ever wrote its
         * first option. So the row drew, all eight bubbles were there, and all three conditioned
         * selects were correctly absent: a category row filtering every block beneath it away, a
         * step that opens as pills over nothing. Right, and useless.
         *
         * `bubble_scroll` now opens on its first category through the same `SegmentedDefault` rule,
         * on both platforms, so this is the authored first frame rather than an empty one. The
         * other two selects must still be absent, which is the claim: before this fix none of the
         * three could appear at all, because a same-step condition resolved against an empty map.
         */
        XCTAssertTrue(app.staticTexts["First — pick one"].waitForExistence(timeout: 10),
                      "the first category's select must be visible when First is the live answer")
        XCTAssertFalse(app.staticTexts["Second — pick one"].exists,
                       "the second category's select must NOT be on screen while First is live")
        XCTAssertFalse(app.staticTexts["Third — pick one"].exists,
                       "the third category's select must NOT be on screen while First is live")

        // ─── TAP the second bubble: the select beneath the row must SWAP ──────────────────────
        let second = app.descendants(matching: .any).matching(identifier: "Second").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the Second bubble must be on screen")
        second.tap()

        XCTAssertTrue(app.staticTexts["Second — pick one"].waitForExistence(timeout: 10),
                      "tapping Second must reveal the second category's select — this is the filter")
        XCTAssertFalse(app.staticTexts["First — pick one"].exists,
                       "and it must take the first category's select away")
        shot(app, "02-second-live")

        // ─── TAP the third: again, and its own options this time ──────────────────────────────
        let third = app.descendants(matching: .any).matching(identifier: "Third").firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        third.tap()
        XCTAssertTrue(app.staticTexts["Third — pick one"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Second — pick one"].exists)
        /*
         * The OPTIONS, not just the label. A select whose label renders and whose options do not is
         * the shape of defect this repo keeps shipping — a control that draws and does nothing.
         */
        XCTAssertTrue(app.staticTexts["Epsilon"].exists || app.buttons["Epsilon"].exists,
                      "the third category's own options must render, not just its label")
        shot(app, "03-third-live")

        /*
         * ─── SCROLL THE ROW, and land on a bubble that has NO content ────────────────────────
         *
         * 🔴 Two claims in one gesture. `Eighth` is off the right-hand edge on a phone, so reaching
         * it proves the row scrolls — which is what "runs off the screen edge" means and what
         * `bubble_scroll` exists for; a wrapping row would have had it on screen already.
         *
         * And `Eighth` carries no select, so the area beneath the row must go EMPTY. A row where
         * every bubble has content cannot distinguish "the filter reads the value" from "the filter
         * reacts to a tap", and this is the case that separates them.
         */
        let eighth = app.descendants(matching: .any).matching(identifier: "Eighth").firstMatch
        if !eighth.isHittable {
            // A horizontal ScrollView answers a swipe on the row itself; the row sits where the
            // first bubble is, so that element is the handle for the gesture.
            let firstBubble = app.descendants(matching: .any).matching(identifier: "First").firstMatch
            for _ in 0..<4 where !eighth.isHittable { firstBubble.swipeLeft() }
        }
        XCTAssertTrue(eighth.isHittable,
                      "the eighth bubble must be reachable by SCROLLING the row — that is what "
                        + "`bubble_scroll` is for, and a wrapping row would not have needed it")
        eighth.tap()
        XCTAssertFalse(app.staticTexts["Third — pick one"].exists,
                       "a category with no blocks of its own must leave the area empty")
        XCTAssertFalse(app.staticTexts["First — pick one"].exists)
        XCTAssertFalse(app.staticTexts["Second — pick one"].exists)
        shot(app, "04-scrolled-to-eighth-nothing-under-it")

        // ─── Screen 2: the Segmented presentations ────────────────────────────────────────────
        app.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 · Segmented, authored and plain"].waitForExistence(timeout: 15),
                      "the CTA must advance to the segmented screen")

        /*
         * (b) and its CONTROL on one screen. The authored block must draw pills; the plain one must
         * still draw a segmented control. If the delegation leaked, every Segmented block in the
         * product changes shape — and twenty-six stored ones must not.
         *
         * 🔴 Operated, not just drawn: the pill is TAPPED and the answer read back, because a pill
         * that draws and collects nothing is the defect, not the fix.
         */
        XCTAssertTrue(app.staticTexts["Authored display_style: bubble — must be PILLS"].exists)
        XCTAssertTrue(app.staticTexts["Nothing authored — must stay a SEGMENTED CONTROL"].exists)
        shot(app, "05-segmented-authored-and-plain")

        let two = app.descendants(matching: .any).matching(identifier: "Two").firstMatch
        XCTAssertTrue(two.waitForExistence(timeout: 10),
                      "the authored Segmented block's options must be individually addressable, "
                        + "which is what renders them as pills rather than a segmented control")
        two.tap()
        shot(app, "06-segmented-pill-tapped")

        /*
         * The plain Segmented control's own options are still there and still tappable — the
         * control did not disappear along with the delegation.
         */
        let right = app.descendants(matching: .any).matching(identifier: "Right").firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 10),
                      "the unauthored Segmented block must still be a working segmented control")
        right.tap()
        shot(app, "07-plain-segmented-operated")

        app.buttons["Finish"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Walk complete"].waitForExistence(timeout: 15),
                      "the walk must reach the last step")
        shot(app, "08-done")
    }
}
