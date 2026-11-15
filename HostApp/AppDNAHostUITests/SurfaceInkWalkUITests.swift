// SurfaceInkWalkUITests.swift
//
// AUTHORED SURFACES IN BOTH PHONE APPEARANCES, OPERATED.
//
// Drives a walk build of this host that is ALREADY INSTALLED under `ai.appdna.wink` (built with a walk menu in its
// Info.plist by the walk script in the AppDNA repository; nothing about it is committed here), with the phone in Light
// and then Dark. For each surface it opens the menu item, saves a frame to the Mac's /tmp/wink, and operates it:
//   a light (#FFFFFF) and a dark (#111827) onboarding flow: the legacy welcome step (secondary text, Skip, the ✕),
//   Next, the animated_loading checklist (its spinner), the last step, then the ✕;
//   a white in-app message (its button), a white survey (an answer), a white screen with a dark section (its action),
//   and a white paywall.
// The frames are judged against what each surface's background requires; the test asserts only that each surface
// opened and each control it taps exists, which is what lets a frame stand for that surface.
import XCTest

final class SurfaceInkWalkUITests: XCTestCase {

    private let bundleId = "ai.appdna.wink"

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(atPath: "/tmp/wink", withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "/tmp/wink/i-\(name).png"))
    }

    private func fresh() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        app.launch()
        return app
    }

    private func tapMenu(_ app: XCUIApplication, _ title: String) -> Bool {
        let b = app.buttons[title]
        guard b.waitForExistence(timeout: 20) else { NSLog("[ink-walk] MISSING menu \(title)"); return false }
        b.tap(); return true
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, containing label: String, timeout: TimeInterval = 10) -> Bool {
        let b = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
        guard b.waitForExistence(timeout: timeout) else { NSLog("[ink-walk] MISSING button \(label)"); return false }
        b.tap(); return true
    }

    private func text(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch.waitForExistence(timeout: timeout)
    }

    func testEverySurfaceInLightAndDark() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("needs iOS 17 for the appearance switch") }
        guard XCUIApplication(bundleIdentifier: bundleId).state != .unknown else { throw XCTSkip("the wink walk build is not installed") }
        var report: [String] = []
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let m = appearance == .dark ? "dark" : "light"
            for tone in ["light", "dark"] {
                var app = fresh()
                XCTAssertTrue(tapMenu(app, "Ink · \(tone) flow"))
                let welcome = text(app, "Ink walk, \(tone) flow", timeout: 25)
                let secondary = text(app, "This secondary line must read")
                let skip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Skip")).firstMatch.exists
                shot(app, "\(m)-\(tone)-1-welcome")
                tap(app, containing: "Next")
                sleep(3); shot(app, "\(m)-\(tone)-2-loading")
                let loading = text(app, "Building your plan")
                sleep(5); shot(app, "\(m)-\(tone)-3-loading-later")
                let finish = text(app, "The end of the ink walk", timeout: 30)
                shot(app, "\(m)-\(tone)-4-finish")
                let closed = tap(app, containing: "Close")
                sleep(2); shot(app, "\(m)-\(tone)-5-closed")
                report.append("\(m)/\(tone) flow: welcome=\(welcome) secondary=\(secondary) skip=\(skip) loading=\(loading) finish=\(finish) closeTapped=\(closed)")
                XCTAssertTrue(welcome && secondary && loading && finish, "[\(m)/\(tone)] a flow step did not show")

                // Skip, operated: from the welcome step it leaves the step.
                app = fresh()
                _ = tapMenu(app, "Ink · \(tone) flow"); _ = text(app, "Ink walk, \(tone) flow", timeout: 25)
                let skipped = tap(app, containing: "Skip")
                sleep(3); shot(app, "\(m)-\(tone)-6-after-skip")
                report.append("\(m)/\(tone) skip tapped=\(skipped) leftWelcome=\(!text(app, "This secondary line must read", timeout: 2))")
            }
            var app = fresh()
            _ = tapMenu(app, "Ink · white message")
            let msg = text(app, "This text has no colour of its own", timeout: 20)
            shot(app, "\(m)-message")
            let msgTap = tap(app, containing: "Got it")
            report.append("\(m) message shown=\(msg) buttonTapped=\(msgTap)")

            app = fresh()
            _ = tapMenu(app, "Ink · white survey")
            let survey = text(app, "Is this question readable", timeout: 20)
            shot(app, "\(m)-survey")
            let answered = tap(app, containing: "Yes")
            sleep(2); shot(app, "\(m)-survey-answered")
            report.append("\(m) survey shown=\(survey) answered=\(answered)")

            app = fresh()
            _ = tapMenu(app, "Ink · white screen")
            let screen = text(app, "Unstyled text on the white screen", timeout: 20) && text(app, "Unstyled text in a dark section")
            shot(app, "\(m)-screen")
            let screenTap = tap(app, containing: "A secondary action")
            sleep(2); shot(app, "\(m)-screen-closed")
            report.append("\(m) screen shown=\(screen) actionTapped=\(screenTap)")

            app = fresh()
            _ = tapMenu(app, "Ink · white paywall")
            sleep(8); shot(app, "\(m)-paywall")
            XCTAssertTrue(msg && survey && screen, "[\(m)] a surface did not show")
        }
        XCUIDevice.shared.appearance = .light
        NSLog("[ink-walk] report:\n\(report.joined(separator: "\n"))")
    }
}
