// PaywallPlanEdgeTapUITests.swift — #1081
//
// DOES A PLAN ROW TAKE A TAP ANYWHERE ON ITSELF, OR ONLY IN THE MIDDLE?
//
// 🔴 Why this exists when `PaywallPlanSelectionWalkUITests` already taps a plan. That walk has now
// run **38 times with no recurrence**, and reading the whole selection-to-purchase path eliminated
// both state-based explanations for #1081: the path is id-based end to end, so an index can never
// choose what is bought; and `isPurchasing` is reset on every exit from `handlePurchase`, so the CTA
// cannot be left stuck disabled.
//
// What that leaves is a tap that did not land on the row — hit-testing or a competing gesture
// recognizer rather than state. And **the existing walk is the instrument least able to find that**,
// because `XCUIElement.tap()` taps the element's CENTRE every time. It samples the one point most
// likely to work, which is exactly why 38 runs say so little. A human thumb lands near an edge, on
// a corner, or on the gap between two rows.
//
// So this taps each row at nine normalised positions and asks the row itself whether the tap took.
// A failure here is #1081, reproduced on demand rather than waited for; all nine passing is
// evidence that a centre-biased explanation is the wrong family, which is worth knowing too.
//
// This repo has already shipped one defect of precisely this shape: a keyboard-dismiss tap handler
// that swallowed every tap inside an onboarding step, on both platforms, while each control
// rendered perfectly.
import XCTest
import StoreKitTest

final class PaywallPlanEdgeTapUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    /// The two-plan fixture's store prices, which is how the rows are told apart.
    private static let monthlyPrice = "4.49"
    private static let annualPrice = "34.99"

    /// Where on the row to tap, as a fraction of its own frame.
    ///
    /// The insets are 0.04 rather than 0.0 because a normalised 0.0 sits exactly on the boundary and
    /// can round into the neighbouring view — that would measure the test's arithmetic rather than
    /// the row's hit area. 0.04 of a ~64pt row is ~2.5pt inside the edge: unambiguously the row, and
    /// unambiguously not the middle.
    private static let spots: [(name: String, dx: CGFloat, dy: CGFloat)] = [
        ("centre",       0.50, 0.50),
        ("left edge",    0.04, 0.50),
        ("right edge",   0.96, 0.50),
        ("top edge",     0.50, 0.04),
        ("bottom edge",  0.50, 0.96),
        ("top-left",     0.04, 0.04),
        ("top-right",    0.96, 0.04),
        ("bottom-left",  0.04, 0.96),
        ("bottom-right", 0.96, 0.96),
    ]

    @available(iOS 17.0, *)
    func testAPlanRowTakesATapAtEveryPointOnItself() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        /*
         🔴 `Bundle(for: Self.self)` AND THE NAME `Products`, both load-bearing. A UI-test bundle
         sees neither the host app's resources nor the package's, so the `.storekit` is a `resources`
         entry on the UI-TEST target and has to be looked up in that bundle. The first version of
         this file used `SKTestSession(configurationFileNamed: "AppDNATestProducts")`, which reads
         the MAIN bundle for a file that is not in it: the session came up with an empty catalogue
         and the run skipped with `probe said store:0`, which reads exactly like a simulator with no
         StoreKit configuration. Copied from `PaywallPurchaseWalkUITests`, which is the pattern that
         works.
        */
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle — add it to the target's "
                + "`resources` in HostApp/project.yml")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchArguments = [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        // The harness check first: an empty catalogue makes every row draw its authored price, and
        // then nothing about selection can be proved from the screen (#1018).
        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawBoth = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:2"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawBoth], timeout: 25) != .completed,
            "the session served fewer than both products (probe said \(probe.label))",
        )

        // Tap-and-retry, because `showPaywall` presents whatever config has already landed and a
        // tap that arrives first does nothing and says nothing.
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the host has no paywall button")
        var annual: XCUIElement?
        for attempt in 0..<12 where annual == nil {
            if open.isHittable { open.tap() }
            annual = row(app, Self.annualPrice, timeout: 5)
            if annual == nil { NSLog("[#1081] paywall not up yet, attempt \(attempt + 1)") }
        }
        let annualRow = try XCTUnwrap(annual, "no plan row drew at the annual price (\(Self.annualPrice))")
        let monthlyRow = try XCTUnwrap(
            row(app, Self.monthlyPrice, timeout: 10),
            "no plan row drew at the monthly price (\(Self.monthlyPrice))",
        )

        /*
         🔴 THE INSTRUMENT'S OWN CONTROL, because "the tap did not take" passes for free on a
         harness that cannot read selection at all — #923's render test read an empty accessibility
         tree and its absence assertion sailed through. The fixture's default is the monthly plan, so
         before any tap exactly one row reports itself selected and it must be that one.
        */
        /*
         🔴 THE FRAMES ARE LOGGED BECAUSE A COORDINATE TAP IS ONLY AS GOOD AS THE FRAME IT IS
         RELATIVE TO. `app.buttons.containing(…)` matches a button by its DESCENDANTS, so it can
         resolve an enclosing container rather than the row — and then a "centre" tap lands between
         two rows and the 0.04 insets land outside both. That is indistinguishable from a row that
         refuses taps, which is exactly the confusion this walk exists to avoid, so the geometry is
         recorded before any conclusion is drawn from a reading.
        */
        NSLog("[#1081] geometry: monthly frame=\(monthlyRow.frame) hittable=\(monthlyRow.isHittable) "
            + "| annual frame=\(annualRow.frame) hittable=\(annualRow.isHittable) "
            + "| window=\(app.windows.firstMatch.frame) "
            + "| rows matching the annual price=\(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", Self.annualPrice)).count)")
        NSLog("[#1081] control, before any tap: monthly selected=\(monthlyRow.isSelected) "
            + "annual selected=\(annualRow.isSelected)")
        XCTAssertTrue(
            monthlyRow.isSelected,
            "the DEFAULT row does not report itself selected, so this walk cannot tell a selected "
                + "row from an unselected one and every reading below would be meaningless",
        )

        /*
         🔴 SCROLL FIRST, AND THIS IS THE WHOLE REASON THE FIRST VERSION OF THIS WALK WAS WRONG.

         `XCUIElement.tap()` scrolls an element into view before tapping it. `coordinate(withNormalized
         Offset:).tap()` does NOT — it taps an absolute screen point, computed from the element's
         frame wherever that frame happens to be. Measured on this fixture:

             monthly frame=(20.0, 975.7, 362.0, 74.3) hittable=false
             annual  frame=(20.0, 1062.0, 362.0, 74.3) hittable=false
             window=(0.0, 0.0, 402.0, 874.0)

         Both rows sit BELOW an 874-point window, so every one of the nine offsets — 0.5 included —
         addressed a point off the bottom of the screen and nothing was tapped. All nine read
         `selected=false`, which is indistinguishable from a row that refuses taps, and the only
         reason that was knowable is that `PaywallPlanSelectionWalkUITests` passed in the same run
         twenty seconds later using plain `.tap()`.

         Accessibility traits read fine on an off-screen element, which is why the control assertion
         above still passed while every tap missed — a combination worth remembering.
        */
        try scrollIntoView(app, annualRow, label: "the annual row")
        try scrollIntoView(app, monthlyRow, label: "the monthly row")
        NSLog("[#1081] after scrolling: monthly frame=\(monthlyRow.frame) hittable=\(monthlyRow.isHittable) "
            + "| annual frame=\(annualRow.frame) hittable=\(annualRow.isHittable)")

        var failures: [String] = []
        for spot in Self.spots {
            // Reset to a known state: monthly selected, annual not. Tapped at its own centre, which
            // the 38 clean runs establish as the reliable point.
            if !monthlyRow.isSelected {
                monthlyRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = waitUntil(timeout: 3) { monthlyRow.isSelected }
            }
            guard monthlyRow.isSelected, !annualRow.isSelected else {
                failures.append("\(spot.name): could not reset to monthly-selected before the tap")
                continue
            }

            annualRow.coordinate(withNormalizedOffset: CGVector(dx: spot.dx, dy: spot.dy)).tap()
            let took = waitUntil(timeout: 3) { annualRow.isSelected }
            NSLog("[#1081] tapped the annual row at \(spot.name) (dx=\(spot.dx), dy=\(spot.dy)) "
                + "-> selected=\(annualRow.isSelected)")
            if !took {
                failures.append("\(spot.name) (dx=\(spot.dx), dy=\(spot.dy))")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "a tap on the annual plan row did not take at \(failures.count) of "
                + "\(Self.spots.count) points on the row itself — this is #1081 reproduced, and the "
                + "positions name where the row stops being hittable: \(failures.joined(separator: "; "))",
        )

        // Leave the app as the other walks expect to find it.
        let close = app.buttons["paywall.close"]
        if close.exists { close.tap() } else { app.swipeDown() }
    }

    // MARK: - helpers

    /// Every plan layout arm renders its row as `Button { selectPlan(plan.id) }`, so the row is a
    /// button carrying the price it draws.
    private func row(_ app: XCUIApplication, _ price: String, timeout: TimeInterval) -> XCUIElement? {
        let button = app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] %@", price))
            .firstMatch
        return button.waitForExistence(timeout: timeout) ? button : nil
    }

    /// Swipe until `element` is actually on screen, because a coordinate tap will not do it.
    ///
    /// Bounded, and it fails rather than giving up quietly: an element that never becomes hittable
    /// would otherwise send every tap below to an off-screen point and read as nine refusals.
    private func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement, label: String) throws {
        guard !element.isHittable else { return }
        for _ in 0..<8 {
            app.swipeUp()
            if element.isHittable { return }
        }
        // Still not hittable: say so with the geometry, so the reading cannot be mistaken for the
        // defect this walk is looking for.
        throw XCTSkip("\(label) never became hittable — frame=\(element.frame) "
            + "window=\(app.windows.firstMatch.frame). Every coordinate tap would address an "
            + "off-screen point, so this walk can prove nothing about where a row takes a tap.")
    }

    /// Polls rather than sleeping, so a slow simulator costs time instead of a false negative.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return condition()
    }
}
