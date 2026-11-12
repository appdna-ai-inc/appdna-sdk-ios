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
    private func presentFlow(bundle: String? = nil) -> XCUIApplication {
        let app = bundle.map { XCUIApplication(bundleIdentifier: $0) } ?? XCUIApplication()
        app.launchArguments += ["-appdnaSeedOnboarding", "widget-walk", "-appdnaFlow", Self.flowId, "-appdnaLogLevel", "debug"]
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

    /// Through SpringBoard: home, long press, edit, add widget, search the host, add; then back to the
    /// app. The how-to closes itself and the step lands on `added`. Repeated `WIDGET_WALK_RUNS` times
    /// (default 5), timing the return → landing.
    func testAddingTheWidgetFromTheGalleryIsDetectedOnReturn() throws {
        let runs = Int(ProcessInfo.processInfo.environment["WIDGET_WALK_RUNS"] ?? "") ?? 5
        var timings: [String] = []
        for run in 1...runs {
            let app = presentFlow()
            app.buttons["Add the widget"].tap()
            XCTAssertTrue(howtoShown(app), "run \(run): the how-to did not open")
            shot("30-run\(run)-howto", app)

            try addWidgetFromGallery(run: run)

            let back = Date()
            app.activate()
            let landed = app.staticTexts["Widget status: added"].waitForExistence(timeout: 15)
            let seconds = Date().timeIntervalSince(back)
            shot("39-run\(run)-after-return", app)
            let state = landed ? "added" : (app.staticTexts["Keep your streak in view"].exists ? "still-on-step" : "other")
            timings.append("run \(run): \(state) after \(String(format: "%.2f", seconds))s")
            NSLog("AppDNA-E2E widget freshness run \(run): \(state) \(String(format: "%.2f", seconds))s events=\(lastEvents(app))")
            if !landed {
                // Is the how-to still up (detection missed), and does Done's re-read see it?
                let stillHowto = howtoShown(app, timeout: 1)
                if stillHowto {
                    howtoButton(app, "Done").tap()
                    let viaDone = app.staticTexts["Widget status: added"].waitForExistence(timeout: 8)
                    timings.append("run \(run): Done re-read → \(viaDone ? "added" : "not added")")
                    shot("39-run\(run)-after-done", app)
                }
            }
            app.terminate()
        }
        let a = XCTAttachment(string: timings.joined(separator: "\n"))
        a.name = "freshness"
        a.lifetime = .keepAlways
        add(a)
        NSLog("AppDNA-E2E widget freshness: \(timings.joined(separator: " | "))")
        XCTAssertTrue(timings.contains { $0.contains(": added after") }, "no run detected the widget on return: \(timings)")
    }

    /// Drives SpringBoard's widget gallery. Fails saying exactly which step it could not reach.
    private func addWidgetFromGallery(run: Int) throws {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        sleepRunLoop(1.5)
        shot("31-run\(run)-home")

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
        shot("32-run\(run)-jiggle")

        // iOS 18+: "Edit" → "Add Widget"; iOS 17: "+" / "Add Widget" at once.
        if !springboard.buttons["Add Widget"].exists, springboard.buttons["Edit"].waitForExistence(timeout: 3) {
            springboard.buttons["Edit"].tap()
        }
        let addEntry = galleryEntry()
        guard addEntry.waitForExistence(timeout: 5) else {
            tree("32-run\(run)-springboard-tree", springboard)
            XCTFail("run \(run): stopped at JIGGLE MODE — no Add Widget / + control in SpringBoard")
            return
        }
        addEntry.tap()
        sleepRunLoop(1.5)
        shot("33-run\(run)-gallery")

        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else {
            tree("33-run\(run)-gallery-tree", springboard)
            XCTFail("run \(run): stopped at the GALLERY — no search field")
            return
        }
        search.tap()
        search.typeText("AppDNA Host")
        sleepRunLoop(1.5)
        shot("34-run\(run)-search")

        // The gallery's app list is a list of cells, one per app with widgets; the host's is labelled
        // with its display name. (The search field's own text matches a label predicate too, so the
        // CELL is asked for by name.)
        let hostEntry = springboard.cells["AppDNA Host"]
        guard hostEntry.waitForExistence(timeout: 5) else {
            tree("34-run\(run)-search-tree", springboard)
            XCTFail("run \(run): stopped at SEARCH — the host app is not listed in the widget gallery")
            return
        }
        hostEntry.tap()
        sleepRunLoop(1.5)
        shot("35-run\(run)-host-widgets")

        let add = springboard.buttons["Add Widget"]
        guard add.waitForExistence(timeout: 5) else {
            tree("35-run\(run)-host-widgets-tree", springboard)
            XCTFail("run \(run): stopped at the HOST'S WIDGETS — no Add Widget button")
            return
        }
        add.tap()
        sleepRunLoop(1.5)
        shot("36-run\(run)-placed")

        // Leave jiggle mode.
        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() } else { XCUIDevice.shared.press(.home) }
        sleepRunLoop(1)
        shot("37-run\(run)-home-with-widget")
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
