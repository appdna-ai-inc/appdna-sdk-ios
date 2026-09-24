import XCTest
@testable import AppDNASDK

/// The render rules behind #609 and #660, on the iOS side.
///
/// These are the iOS half of `WineTrailsRenderGatesTest.kt`. Both files assert the same rules
/// against the same inputs on purpose: every bug in this group was a layout or suppression rule
/// that lived inside a view, where the only way to check it was to look at a screen — and a
/// screenshot is not run in CI.
final class WineTrailsRenderGatesTests: XCTestCase {

    // MARK: - #609 — Multi-buttons row planning

    func testThreeButtonsAtTwoPerRowIsTheTwoThenOneLayout() {
        // The layout that was actually asked for.
        XCTAssertEqual(multiButtonRowPlan(childCount: 3, perRow: 2), [2, 1])
    }

    func testFullRowsHaveNoRemainderRow() {
        XCTAssertEqual(multiButtonRowPlan(childCount: 4, perRow: 2), [2, 2])
        XCTAssertEqual(multiButtonRowPlan(childCount: 3, perRow: 3), [3])
        XCTAssertEqual(multiButtonRowPlan(childCount: 3, perRow: 1), [1, 1, 1])
    }

    func testPerRowIsClampedToTheOneToThreeTheElementPromises() {
        // A 0 would divide by zero; anything above 3 is not a layout this element offers.
        XCTAssertEqual(multiButtonRowPlan(childCount: 2, perRow: 0), [1, 1])
        XCTAssertEqual(multiButtonRowPlan(childCount: 4, perRow: 9), [3, 1])
    }

    func testNoButtonsMeansNoRows() {
        XCTAssertEqual(multiButtonRowPlan(childCount: 0, perRow: 2), [])
    }

    // MARK: - #609 — the per-child button border that nothing read

    /*
     * Reported after the element itself passed: "Border color doesn't apply — the border never
     * renders in that color, on device or in preview". True on ALL THREE surfaces: every one stroked
     * a hardcoded 1.5pt ring in the BACKGROUND colour, and only for `variant: outline`, so a filled
     * button with border width 40 and a yellow border drew nothing at all. Same table as Android's.
     */

    func testAnAuthoredWidthDrawsARingOnAFilledButton() {
        // The exact case from the issue screenshot: a filled button at width 40 drew nothing.
        XCTAssertEqual(authoredButtonBorderWidth(40, variant: "primary"), 40)
        XCTAssertEqual(authoredButtonBorderWidth(3, variant: nil), 3)
    }

    func testAnUnauthoredButtonKeepsExactlyTheBorderItHadBefore() {
        // Non-outline had no ring and must not grow one, or every published flow shifts.
        XCTAssertEqual(authoredButtonBorderWidth(nil, variant: "primary"), 0)
        XCTAssertEqual(authoredButtonBorderWidth(nil, variant: "text"), 0)
        // Outline rings itself at 1.5 — the long-standing default, kept.
        XCTAssertEqual(authoredButtonBorderWidth(nil, variant: "outline"), 1.5)
    }

    func testAnAuthoredZeroRemovesTheRingIncludingFromAnOutlineButton() {
        // "No border" has to be expressible, otherwise outline can never lose its ring.
        XCTAssertEqual(authoredButtonBorderWidth(0, variant: "outline"), 0)
        // A negative is nonsense rather than an inverted ring; clamp it here.
        XCTAssertEqual(authoredButtonBorderWidth(-5, variant: "primary"), 0)
    }

    func testABlankColourCountsAsUnsetSoTheRingFallsBackToTheButtonColour() {
        // The console ColorPicker writes "" for transparent; stroking "nothing" would hide the edge.
        XCTAssertNil(authoredButtonBorderColorHex(""))
        XCTAssertNil(authoredButtonBorderColorHex("   "))
        XCTAssertNil(authoredButtonBorderColorHex(nil))
        XCTAssertEqual(authoredButtonBorderColorHex("#f9ff00"), "#f9ff00")
    }

    func testAShortLastRowReservesHalfTheMissingColumnsOnEachSide() {
        // 3 buttons at 2 per row: the lone last button is ONE column wide with half a column either
        // side, so it lines up under the two above it. Same table as Android's.
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 1, perRow: 2, stretchLastRow: false), 0.5)
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 1, perRow: 3, stretchLastRow: false), 1.0)
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 2, perRow: 3, stretchLastRow: false), 0.5)
    }

    func testAFullRowReservesNothing() {
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 2, perRow: 2, stretchLastRow: false), 0)
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 3, perRow: 3, stretchLastRow: false), 0)
    }

    func testStretchReservesNothingWhichIsWhatMakesItStretch() {
        // The regression this pins: with no filler the child grows to the whole row, so "center"
        // and "stretch" rendered the SAME pixels — two settings, one image.
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 1, perRow: 2, stretchLastRow: true), 0)
        XCTAssertEqual(multiButtonFillerWeight(rowSize: 2, perRow: 3, stretchLastRow: true), 0)
    }

    func testRowPlanAlwaysAccountsForEveryChild() {
        // The property that matters at a call site: no button is ever dropped or drawn twice.
        for count in 0...12 {
            for perRow in 0...5 {
                XCTAssertEqual(
                    multiButtonRowPlan(childCount: count, perRow: perRow).reduce(0, +),
                    count,
                    "row plan lost or duplicated a button for count=\(count) perRow=\(perRow)"
                )
            }
        }
    }

    // MARK: - #663 — a percentage width is a fraction of the CONTAINER

    func testAPercentageResolvesAgainstTheMeasuredContainer() {
        // 75% of a 400pt container is 300pt — not 75% of the phone, which is what it used to be.
        XCTAssertEqual(relativeWidth(0.75, container: 400), 300)
        XCTAssertEqual(relativeWidth(0.5, container: 320), 160)
    }

    func testAnUnmeasuredContainerFallsBackInsteadOfCollapsing() {
        // 0 means nobody measured. Returning 0 would render an invisible block, so the old
        // screen-minus-assumed-padding approximation stays as the floor — no worse than before.
        XCTAssertGreaterThan(relativeWidth(0.75, container: 0), 0)
    }

    func testTheSameAuthoredPercentageIsTheSameWidthInTheSameContainer() {
        // The cross-platform point of #663: the answer depends on the container, NOT the device.
        // Two different phones laying out the same 400pt container must agree.
        XCTAssertEqual(relativeWidth(0.75, container: 400), relativeWidth(0.75, container: 400))
    }

    // MARK: - #654 / #659 — horizontal_align on a width-constrained block, on iOS too

    func testAConstrainedBlockWithAnAlignmentNeedsTheOuterBox() {
        // iOS had the SAME defect as Android: the inner position modifier resolves inside the
        // sizing frame, so a block authored `right` and one authored `center` rendered in the
        // identical position. Two goldens proved it.
        XCTAssertTrue(needsOuterAlignmentBox(elementWidth: "75%", horizontalAlign: "center"))
        XCTAssertTrue(needsOuterAlignmentBox(elementWidth: "300px", horizontalAlign: "right"))
        XCTAssertTrue(needsOuterAlignmentBox(elementWidth: "50%", horizontalAlign: "left"))
    }

    func testAnUnconstrainedWidthNeverNeedsIt() {
        XCTAssertFalse(needsOuterAlignmentBox(elementWidth: nil, horizontalAlign: "center"))
        XCTAssertFalse(needsOuterAlignmentBox(elementWidth: "auto", horizontalAlign: "center"))
        XCTAssertFalse(needsOuterAlignmentBox(elementWidth: "fill", horizontalAlign: "center"))
    }

    func testNoAuthoredAlignmentMeansNoWrapper() {
        XCTAssertFalse(needsOuterAlignmentBox(elementWidth: "75%", horizontalAlign: nil))
        XCTAssertFalse(needsOuterAlignmentBox(elementWidth: "300px", horizontalAlign: ""))
    }

    // MARK: - #660 — a summary stat whose token never resolved

    func testAResolvedStatPassesThroughUntouched() {
        let stat: [String: Any] = ["label": "Region", "value": "Central Otago"]
        let out = sanitizeSummaryStat(stat)
        XCTAssertEqual(out?["label"] as? String, "Region")
        XCTAssertEqual(out?["value"] as? String, "Central Otago")
    }

    func testAnUnresolvedValueKeepsTheCardWhenTheLabelStillSaysSomething() {
        // The #660 regression: SPEC-446 dropped the whole card, so a booking summary lost rows
        // wholesale when one key was missing from the host payload.
        let stat: [String: Any] = ["label": "Region", "value": "{{hook_data.region.name}}"]
        let out = sanitizeSummaryStat(stat)
        XCTAssertNotNil(out, "a card with a real label must survive an unresolved value — this is #660")
        XCTAssertEqual(out?["value"] as? String, unresolvedStatPlaceholder)
        XCTAssertEqual(out?["label"] as? String, "Region")
    }

    func testAnUnresolvedLabelLosesTheCaptionAndKeepsTheValue() {
        let stat: [String: Any] = ["label": "{{hook_data.caption}}", "value": "NZ$25"]
        let out = sanitizeSummaryStat(stat)
        XCTAssertEqual(out?["value"] as? String, "NZ$25")
        XCTAssertNil(out?["label"], "an unresolved label must not print braces on screen")
    }

    func testACardThatWouldSayNothingIsStillDropped() {
        // Both halves unresolved, or a lone unresolved value: nothing to render, so drop it.
        XCTAssertNil(sanitizeSummaryStat(["label": "{{a}}", "value": "{{b}}"]))
        XCTAssertNil(sanitizeSummaryStat(["value": "{{b}}"]))
        XCTAssertNil(sanitizeSummaryStat(["label": "   ", "value": "{{b}}"]))
    }
}
