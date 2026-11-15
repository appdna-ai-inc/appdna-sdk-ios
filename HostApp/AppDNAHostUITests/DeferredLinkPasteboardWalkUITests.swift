// DeferredLinkPasteboardWalkUITests.swift — the first-launch deferred-link check, walked on the simulator.
//
// The check used to read the pasteboard on every first launch, so any text the user had copied in
// another app made iOS show "Allow Paste?" and blocked the reading thread until it was answered. It now
// reads only when iOS says, without a prompt, that the pasteboard holds a web link.
//
// The pasteboard is written from THIS process (the UI-test runner), which is another app as far as
// iOS is concerned, so reading it from the host is exactly the cross-app read that prompts.
//
// Needs a walk build whose base URL answers the bootstrap with the walk org and app, and a deferred
// link document for `visitorId` in that app (`scripts/walks/seed-walk-1858-ddl.ts`). Synthetic only.
import XCTest
import UIKit

final class DeferredLinkPasteboardWalkUITests: XCTestCase {
    static let visitorId = "walk1858visitor"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    static let shotDir = "/tmp/sdkdec-1858-shots"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: Self.shotDir, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(Self.shotDir)/\(name).png"))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-appdnaCheckDeferredLink", "1", "-appdnaResetFirstLaunch", "1", "-appdnaLogLevel", "debug"]
        app.terminate()
        app.launch()
        return app
    }

    private var pasteAlert: XCUIElement { springboard.alerts.firstMatch }

    /// Arbitrary copied text: NO paste alert, the check still answers, and the app takes a tap.
    func testArbitraryCopiedTextShowsNoPasteAlert() {
        UIPasteboard.general.string = "a shopping list someone copied: eggs, milk, bread"
        let app = launch()
        let answer = app.staticTexts["host.deferredLink"]
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the deferred-link check never answered")
        // The window in which the old code asked: from launch until the check answered, and 3s more.
        XCTAssertFalse(pasteAlert.waitForExistence(timeout: 3), "iOS showed a paste alert for text that is not a link")
        XCTAssertEqual(answer.label, "deferred link → none")
        shot("1858-a-arbitrary-text-no-alert")
        // Responsive: a tap lands and the app reacts.
        let title = app.staticTexts["host.title"]
        XCTAssertTrue(title.isHittable, "the host is not taking taps")
        title.tap()
        XCTAssertEqual(UIPasteboard.general.string, "a shopping list someone copied: eggs, milk, bread",
                       "the user's own text must be left where they put it")
        NSLog("DDLWALK-A done label=\(answer.label)")
    }

    /// Our own link copied: the read happens (iOS asks, as it must for any cross-app read), and the
    /// deferred link is matched for the visitor id in it.
    func testOurCopiedLinkStillMatchesTheDeferredLink() {
        UIPasteboard.general.string = "https://links.example.com/install?appdna_visitor=\(Self.visitorId)"
        let app = launch()
        if pasteAlert.waitForExistence(timeout: 20) {
            shot("1858-b1-our-link-paste-alert")
            NSLog("DDLWALK-B alert buttons=\(pasteAlert.buttons.allElementsBoundByIndex.map { $0.label })")
            let allow = pasteAlert.buttons["Allow Paste"]
            XCTAssertTrue(allow.exists, "no Allow Paste button")
            allow.tap()
        } else {
            NSLog("DDLWALK-B no paste alert appeared")
        }
        let answer = app.staticTexts["host.deferredLink"]
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the deferred-link check never answered")
        shot("1858-b2-our-link-matched")
        XCTAssertEqual(answer.label, "deferred link → /walk/ddl-1858 visitor=\(Self.visitorId)")
        NSLog("DDLWALK-B done label=\(answer.label)")
    }
}
