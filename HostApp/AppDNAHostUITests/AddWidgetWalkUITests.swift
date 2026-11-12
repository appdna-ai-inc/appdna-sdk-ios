// AddWidgetWalkUITests.swift — the "Add widget" button, walked on the simulator.
//
// The flow is synthetic and bundled (`AppDNAHost/WalkFlows/widget-walk.json`), seeded into the SDK's
// config cache by `-appdnaSeedOnboarding`, so no server or credential is needed: everything from the
// decode on is production code. One step carries an `add_widget` button (and an id-less one inside a
// Multi-buttons group), each with an iOS how-to; the step's rules route each `widget_status` to its
// own step ("Widget status: added" / "not_added" / "unavailable"), so the landing screen says which
// status the SDK wrote.
//
// What is OPERATED (CLAUDE.md Rules 23/24): the button, the how-to's Close, a swipe on the how-to,
// its Done; the Home Screen's widget gallery through SpringBoard — long press, edit, add widget,
// search, add — and the return to the app; the no-widget build. Every screen is attached.
import XCTest

final class AddWidgetWalkUITests: XCTestCase {

    static let flowId = "widget_walk_flow"
    static let noWidgetBundle = "ai.appdna.appdnaSdkExample.nowidget"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    // MARK: - Helpers

    private func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let a = XCTAttachment(screenshot: app?.screenshot() ?? XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tree(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// Launches a host build on the seeded flow and presents it.
    private func presentFlow(bundle: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = bundle.map { XCUIApplication(bundleIdentifier: $0) } ?? XCUIApplication()
        app.launchArguments += ["-appdnaSeedOnboarding", "widget-walk", "-appdnaFlow", Self.flowId, "-appdnaLogLevel", "debug", "-appdnaProbeWidgets", "1"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 30), "the host did not launch")
        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["Keep your streak in view"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the seeded flow never presented")
        return app
    }

    private func howtoShown(_ app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        text(app, containing: "Touch and hold an empty area").waitForExistence(timeout: timeout)
    }

    private func howtoGone(_ app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let e = text(app, containing: "Touch and hold an empty area")
        return XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: e)], timeout: timeout) == .completed
    }

    /// A how-to button by its label. The flow's own chrome can carry a button with the same label
    /// (its close control is "Close"), and the sheet sits on top, so the LAST hittable match is the
    /// sheet's.
    private func howtoButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let all = app.buttons.matching(identifier: label).allElementsBoundByIndex.filter { $0.isHittable }
        return all.last ?? app.buttons[label].firstMatch
    }

    private func lastEvents(_ app: XCUIApplication) -> String {
        let e = app.staticTexts["host.lastEvents"]
        return e.exists ? e.label : "(no event mirror)"
    }

    // MARK: - Close, swipe, Done without adding

    /// Close and a swipe each return to the step without advancing; Done with nothing added lands on
    /// the `not_added` branch.
    func testCloseAndSwipeStayAndDoneWithoutAddingIsNotAdded() throws {
        // `not_added` means "the user had none of the app's widgets and none appeared": start clean.
        XCTAssertEqual(removeAllHostWidgets(tag: "00-clean"), 0, "no widget of the host may be left over")
        let app = presentFlow()
        shot("01-step", app)

        app.buttons["Add the widget"].tap()
        XCTAssertTrue(howtoShown(app), "the how-to did not open")
        XCTAssertTrue(howtoButton(app, "Done").exists && howtoButton(app, "Close").exists)
        shot("02-howto", app)

        howtoButton(app, "Close").tap()
        XCTAssertTrue(howtoGone(app), "Close did not close the how-to")
        XCTAssertTrue(app.staticTexts["Keep your streak in view"].exists, "Close must stay on the step")
        shot("03-after-close-stays", app)

        app.buttons["Add the widget"].tap()
        XCTAssertTrue(howtoShown(app), "a second attempt did not open the how-to")
        let head = text(app, containing: "Touch and hold an empty area")
        let start = head.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 700)))
        XCTAssertTrue(howtoGone(app), "a swipe did not close the how-to")
        XCTAssertTrue(app.staticTexts["Keep your streak in view"].exists, "a swipe must stay on the step")
        shot("04-after-swipe-stays", app)

        app.buttons["Add the widget"].tap()
        XCTAssertTrue(howtoShown(app))
        howtoButton(app, "Done").tap()
        XCTAssertTrue(app.staticTexts["Widget status: not_added"].waitForExistence(timeout: 8),
                      "Done without adding must land on not_added; events: \(lastEvents(app))")
        shot("05-done-not-added", app)
        NSLog("AppDNA-E2E widget walk events: \(lastEvents(app))")
    }

    /// The id-less Multi-buttons child opens the same how-to and ends the same way.
    func testMultiButtonsChildOpensTheHowto() throws {
        let app = presentFlow()
        app.buttons["Widget from group"].tap()
        XCTAssertTrue(howtoShown(app), "the Multi-buttons child did not open the how-to")
        shot("10-group-child-howto", app)
        howtoButton(app, "Done").tap()
        XCTAssertTrue(app.staticTexts["Widget status: not_added"].waitForExistence(timeout: 8))
        shot("11-group-child-not-added", app)
    }

    /// A build with no WidgetKit extension advances at once to the `unavailable` branch.
    func testNoWidgetBuildIsUnavailable() throws {
        let app = presentFlow(bundle: Self.noWidgetBundle)
        shot("20-nowidget-step", app)
        app.buttons["Add the widget"].tap()
        XCTAssertTrue(app.staticTexts["Widget status: unavailable"].waitForExistence(timeout: 8),
                      "no extension must land on unavailable")
        XCTAssertFalse(howtoShown(app, timeout: 1), "no how-to without a widget")
        shot("21-nowidget-unavailable", app)
    }

    // MARK: - Add the widget through the Home Screen

    /// THE STATUSES, through SpringBoard, from a CLEAN Home Screen, `WIDGET_WALK_ROUNDS` times
    /// (default 2). Each round:
    ///   a. Done with no widget of the app placed            → `not_added`;
    ///   b. add a SMALL widget, return                        → `added` on return (timed);
    ///   c. add a second SMALL widget, return, Done           → `unknown` (WidgetKit cannot see a
    ///      second widget of a size already placed);
    ///   d. with the debug seam that skips the read on return, add a MEDIUM widget, return, Done
    ///      → `added` by the Done re-read (the CTA re-query branch);
    ///   e. remove every widget the round added, and prove none is left.
    func testTheStatusesThroughTheGallery() throws {
        let rounds = Int(ProcessInfo.processInfo.environment["WIDGET_WALK_ROUNDS"] ?? "") ?? 2
        var log: [String] = []
        for r in 1...rounds {
            XCTAssertEqual(removeAllHostWidgets(tag: "40-r\(r)-clean"), 0, "round \(r) starts clean")

            // a. nothing placed, Done → not_added
            var app = presentFlow()
            app.buttons["Add the widget"].tap()
            XCTAssertTrue(howtoShown(app))
            howtoButton(app, "Done").tap()
            let a = app.staticTexts["Widget status: not_added"].waitForExistence(timeout: 8)
            shot("41-r\(r)-a-done-nothing-placed", app)
            log.append("r\(r) a: \(a ? "not_added" : "MISSED")")
            app.terminate()

            // b. first SMALL widget, return → added on return
            app = presentFlow()
            app.buttons["Add the widget"].tap()
            XCTAssertTrue(howtoShown(app))
            try addWidgetFromGallery(tag: "42-r\(r)-b", medium: false)
            var back = Date()
            app.activate()
            let b = app.staticTexts["Widget status: added"].waitForExistence(timeout: 15)
            log.append("r\(r) b: \(b ? "added on return after \(String(format: "%.2f", Date().timeIntervalSince(back)))s" : "MISSED")")
            shot("43-r\(r)-b-added-on-return", app)
            app.terminate()

            // c. second SMALL widget, return, Done → unknown
            app = presentFlow()
            app.buttons["Add the widget"].tap()
            XCTAssertTrue(howtoShown(app))
            try addWidgetFromGallery(tag: "44-r\(r)-c", medium: false)
            app.activate()
            let stayed = howtoShown(app, timeout: 5)
            shot("45-r\(r)-c-back-howto-still-up", app)
            howtoButton(app, "Done").tap()
            let c = app.staticTexts["Widget status: unknown"].waitForExistence(timeout: 8)
            log.append("r\(r) c: \(stayed ? "how-to stayed up" : "how-to gone"); Done → \(c ? "unknown" : "MISSED")")
            shot("46-r\(r)-c-done-unknown", app)
            app.terminate()

            // d. MEDIUM widget with the read on return skipped, Done → added (the Done re-read)
            app = presentFlow(extra: ["-AppDNADebugWidgetSkipReturnRead", "YES"])
            app.buttons["Add the widget"].tap()
            XCTAssertTrue(howtoShown(app))
            try addWidgetFromGallery(tag: "47-r\(r)-d", medium: true)
            back = Date()
            app.activate()
            let held = howtoShown(app, timeout: 5)
            shot("48-r\(r)-d-back-howto-still-up", app)
            howtoButton(app, "Done").tap()
            let d = app.staticTexts["Widget status: added"].waitForExistence(timeout: 8)
            log.append("r\(r) d: \(held ? "how-to stayed up (seam)" : "how-to gone"); Done → \(d ? "added" : "MISSED")")
            shot("49-r\(r)-d-done-added", app)
            app.terminate()

            // e. remove what the round added; none may be left
            let removed = removeAllHostWidgets(tag: "50-r\(r)-cleanup")
            let left = removeAllHostWidgets(tag: "51-r\(r)-verify")
            log.append("r\(r) e: removed \(removed), left \(left)")
            XCTAssertTrue(a && b && c && d, "round \(r): \(log)")
            XCTAssertEqual(left, 0, "round \(r) leaves no widget behind")
        }
        let att = XCTAttachment(string: log.joined(separator: "\n"))
        att.name = "statuses"
        att.lifetime = .keepAlways
        add(att)
        NSLog("AppDNA-E2E widget statuses: \(log.joined(separator: " | "))")
    }

    // MARK: - Cleaning the Home Screen

    /// The host's widgets on the visible Home Screen page: elements labelled for the host app that are
    /// widget-sized (an app icon is about 60 pt; a small widget about 160).
    private func visibleHostWidgets() -> [XCUIElement] {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'AppDNA Host' OR label CONTAINS 'Sample'"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.width > 120 && $0.frame.height > 120 && $0.isHittable }
    }

    /// Removes every widget of the host from every Home Screen page (long press → Remove Widget →
    /// Remove). Returns how many it removed; called again it returns 0 when none is left.
    @discardableResult
    private func removeAllHostWidgets(tag: String) -> Int {
        XCUIDevice.shared.press(.home)
        _ = springboard.wait(for: .runningForeground, timeout: 10)
        sleepRunLoop(1)
        XCUIDevice.shared.press(.home) // the first page
        sleepRunLoop(1)
        var removed = 0
        for page in 0..<4 {
            var guardCount = 0
            while let w = visibleHostWidgets().first, guardCount < 12 {
                guardCount += 1
                w.press(forDuration: 1.4)
                let remove = springboard.buttons["Remove Widget"]
                guard remove.waitForExistence(timeout: 3) else {
                    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
                    break
                }
                remove.tap()
                let confirm = springboard.alerts.buttons["Remove"]
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
                removed += 1
                sleepRunLoop(1)
            }
            if page < 3 {
                springboard.swipeLeft()
                sleepRunLoop(1)
            }
        }
        XCUIDevice.shared.press(.home)
        sleepRunLoop(1)
        shot("\(tag)-home-removed-\(removed)")
        return removed
    }

    /// Drives SpringBoard's widget gallery. Fails saying exactly which step it could not reach.
    private func addWidgetFromGallery(tag: String, medium: Bool) throws {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        sleepRunLoop(1.5)
        shot("\(tag)-1-home")

        // Enter jiggle mode: long press an icon and pick "Edit Home Screen", else long press empty space.
        _ = springboard.icons.firstMatch.waitForExistence(timeout: 5)
        if let icon = springboard.icons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            icon.press(forDuration: 1.6)
            let edit = springboard.buttons["Edit Home Screen"]
            if edit.waitForExistence(timeout: 3) { edit.tap() }
        }
        if !galleryEntry().exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).press(forDuration: 2.0)
        }
        sleepRunLoop(1)
        shot("\(tag)-2-jiggle")

        // iOS 18+: "Edit" → "Add Widget"; iOS 17: "+" / "Add Widget" at once.
        if !springboard.buttons["Add Widget"].exists, springboard.buttons["Edit"].waitForExistence(timeout: 3) {
            springboard.buttons["Edit"].tap()
        }
        let addEntry = galleryEntry()
        guard addEntry.waitForExistence(timeout: 5) else {
            tree("\(tag)-2-springboard-tree", springboard)
            XCTFail("\(tag): stopped at JIGGLE MODE — no Add Widget / + control in SpringBoard")
            return
        }
        addEntry.tap()
        sleepRunLoop(1.5)
        shot("\(tag)-3-gallery")

        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else {
            tree("\(tag)-3-gallery-tree", springboard)
            XCTFail("\(tag): stopped at the GALLERY — no search field")
            return
        }
        search.tap()
        search.typeText("AppDNA Host")
        sleepRunLoop(1.5)
        shot("\(tag)-4-search")

        // The gallery's app list is a list of cells, one per app with widgets; the host's is labelled
        // with its display name. (The search field's own text matches a label predicate too, so the
        // CELL is asked for by name.)
        var hostEntry = springboard.cells["AppDNA Host"]
        if !hostEntry.waitForExistence(timeout: 3), springboard.buttons["Clear text"].exists {
            // The gallery can reopen with the previous search still typed and no match listed.
            springboard.buttons["Clear text"].tap()
            search.typeText("AppDNA")
            hostEntry = springboard.cells["AppDNA Host"]
        }
        guard hostEntry.waitForExistence(timeout: 5) else {
            tree("\(tag)-4-search-tree", springboard)
            XCTFail("\(tag): stopped at SEARCH — the host app is not listed in the widget gallery")
            return
        }
        hostEntry.tap()
        sleepRunLoop(1.5)
        if medium {
            // The host's page shows one size at a time; the medium one is the next page.
            let preview = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'AppDNA Host'")).firstMatch
            if preview.waitForExistence(timeout: 3) { preview.swipeLeft() }
            sleepRunLoop(1.5)
            let mediumPreview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Medium'")).firstMatch
            XCTAssertTrue(mediumPreview.waitForExistence(timeout: 3), "\(tag): the medium size is not showing")
        }
        shot("\(tag)-5-host-widgets")

        // The host's page labels its button " Add Widget" — a glyph, then the words — so it is found by
        // what the label contains, the bottom-most one being the sheet's.
        let addMatches = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'"))
        _ = addMatches.firstMatch.waitForExistence(timeout: 5)
        let add = addMatches.allElementsBoundByIndex.filter { $0.isHittable }.max { $0.frame.minY < $1.frame.minY }
            ?? addMatches.firstMatch
        guard add.exists else {
            tree("\(tag)-5-host-widgets-tree", springboard)
            XCTFail("\(tag): stopped at the HOST'S WIDGETS — no Add Widget button")
            return
        }
        add.tap()
        sleepRunLoop(1.5)
        shot("\(tag)-6-placed")

        // Leave jiggle mode.
        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() } else { XCUIDevice.shared.press(.home) }
        sleepRunLoop(1)
        shot("\(tag)-7-home-with-widget")
    }

    private func galleryEntry() -> XCUIElement {
        let b = springboard.buttons
        if b["Add Widget"].exists { return b["Add Widget"] }
        if b["Add"].exists { return b["Add"] }
        return b["Add Widget"]
    }

    private func sleepRunLoop(_ s: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(s))
    }
}
