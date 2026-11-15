// RenderWalkUITests.swift — default ink, a rating, a required segmented question and paywall icons, walked on the
// simulator in Light and then Dark phone appearance.
//
// Synthetic flow (`WalkFlows/render-walk.json`), every step in order, each screen saved to /tmp/render-walk:
//   1. a dark (#0B1220) step: an unstyled heading and a three-item timeline (titles and subtitles unstyled);
//   2. a white step: a section_background with one dark zone holding unstyled text and a timeline, a row with a
//      `transparent` fill and a row with a dark fill, each holding unstyled text;
//   3. a pale gradient step with an unstyled heading and line;
//   4. a rating block stored at `stars`: four stars tapped;
//   5. a required segmented question stored at `size` with no default: Continue is tapped first and must not leave
//      the step; then Medium is picked and Continue leaves;
//   6. the last step reads both answers back through `{{responses.*}}`; Finish, then the host's stored responses.
// Then the synthetic paywall (`WalkFlows/render-walk-paywall.json`): an icon grid of SF Symbol names, the default
// guarantee badge and a shield badge; scrolled to the bottom and closed.
// The frames are judged by eye for ink; the test asserts what can be read: each step showed, each control operated, and
// the stored answers.
import XCTest

final class RenderWalkUITests: XCTestCase {
    static let shotDir = "/tmp/render-walk"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: Self.shotDir, withIntermediateDirectories: true)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        try? png.write(to: URL(fileURLWithPath: "\(Self.shotDir)/i-\(name).png"))
    }

    private func text(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func tapButton(_ app: XCUIApplication, _ label: String) {
        let b = app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10), "no button \(label)")
        b.tap()
    }

    func testEveryScreenInLightAndDark() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("needs iOS 17 for the appearance switch") }
        var report: [String] = []
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let m = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments += ["-appdnaSeedOnboarding", "render-walk", "-appdnaFlow", "render_walk_flow", "-appdnaLogLevel", "debug"]
            app.launch()
            XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 30), "the host did not launch")
            var presented = false
            for _ in 0..<12 where !presented {
                app.buttons["host.onboarding"].tap()
                presented = text(app, "Your plan on a dark step", timeout: 5)
            }
            XCTAssertTrue(presented, "[\(m)] the seeded flow never presented")

            // 1. Dark step, timeline.
            let timeline = text(app, "Week one: start small") && text(app, "Ten minutes a day") && text(app, "Week three: make it yours")
            shot(app, "\(m)-1-dark-timeline")
            tapButton(app, "Next")

            // 2. Zones and rows.
            let zones = text(app, "Text on a dark zone") && text(app, "Timeline in the dark zone")
                && text(app, "Text in a transparent row") && text(app, "Text in a dark row")
            shot(app, "\(m)-2-zones-rows")
            tapButton(app, "Next")

            // 3. Pale gradient.
            let pale = text(app, "On a pale gradient") && text(app, "This unstyled line must be dark")
            shot(app, "\(m)-3-pale-gradient")
            tapButton(app, "Next")

            // 4. Rating: tap the fourth of five stars, then read its value back.
            XCTAssertTrue(text(app, "Rate the walk"))
            let stars = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "of 5 stars")).firstMatch
            XCTAssertTrue(stars.waitForExistence(timeout: 5), "[\(m)] no rating element")
            stars.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
            sleep(1)
            let ratingValue = (stars.value as? String) ?? ""
            shot(app, "\(m)-4-rating-four")
            tapButton(app, "Next")

            // 5. Required segmented question with nothing picked: Continue must not leave.
            XCTAssertTrue(text(app, "Pick one, required"))
            shot(app, "\(m)-5-segmented-empty")
            tapButton(app, "Continue")
            sleep(2)
            let held = !text(app, "Walk finished", timeout: 2) && text(app, "Pick one, required", timeout: 2)
            shot(app, "\(m)-5b-segmented-held")
            app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Medium")).firstMatch.tap()
            shot(app, "\(m)-5c-segmented-picked")
            tapButton(app, "Continue")

            // 6. Read-back.
            let finished = text(app, "Walk finished", timeout: 10)
            let readBack = text(app, "Stars 4 size medium", timeout: 5)
            shot(app, "\(m)-6-readback")
            tapButton(app, "Finish")
            let raw = app.staticTexts["host.responsesRaw"]
            XCTAssertTrue(raw.waitForExistence(timeout: 10))
            let stored = raw.label
            NSLog("RENDERWALK \(m) responses=\(stored)")
            report.append("\(m) flow: timeline=\(timeline) zones=\(zones) pale=\(pale) rating=\(ratingValue) segmentedHeld=\(held) finished=\(finished) readBack=\(readBack)")
            XCTAssertTrue(timeline && zones && pale && finished, "[\(m)] a step did not show")
            XCTAssertEqual(ratingValue, "4 of 5 stars", "[\(m)] the rating did not take the fourth star")
            XCTAssertTrue(held, "[\(m)] a required segmented question with nothing picked let Continue through")
            XCTAssertTrue(readBack, "[\(m)] the answers did not read back on the last step")
            XCTAssertTrue(stored.contains("\"stars\":4"), "[\(m)] stored: \(stored)")
            XCTAssertTrue(stored.contains("\"size\":\"medium\""), "[\(m)] stored: \(stored)")
            app.terminate()

            // Paywall icons.
            let pw = XCUIApplication()
            pw.launchArguments += ["-appdnaSeedPaywalls", "render-walk-paywall", "-appdnaPaywall", "render_walk_pw", "-appdnaLogLevel", "debug"]
            pw.launch()
            XCTAssertTrue(pw.staticTexts["host.title"].waitForExistence(timeout: 30))
            var shown = false
            for _ in 0..<12 where !shown {
                pw.buttons["host.paywall"].tap()
                shown = text(pw, "Icons walk", timeout: 5)
            }
            XCTAssertTrue(shown, "[\(m)] the seeded paywall never presented")
            let icons = text(pw, "Bolt") && text(pw, "Infinity")
            shot(pw, "\(m)-7-paywall-top")
            pw.swipeUp(); sleep(1)
            let badges = text(pw, "Default guarantee badge") && text(pw, "Shield guarantee badge")
            shot(pw, "\(m)-8-paywall-guarantees")
            let close = pw.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "close", "close")).firstMatch
            let closed = close.waitForExistence(timeout: 5) ? { close.tap(); sleep(2); return !text(pw, "Icons walk", timeout: 2) }() : false
            shot(pw, "\(m)-9-paywall-closed")
            report.append("\(m) paywall: icons=\(icons) badges=\(badges) closed=\(closed)")
            XCTAssertTrue(icons && badges, "[\(m)] the paywall sections did not show")
            pw.terminate()
        }
        XCUIDevice.shared.appearance = .light
        NSLog("[render-walk] report:\n\(report.joined(separator: "\n"))")
    }
}
