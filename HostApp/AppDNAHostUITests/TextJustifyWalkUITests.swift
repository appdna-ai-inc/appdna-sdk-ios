// TextJustifyWalkUITests.swift — Heading and Rich Text colour runs and Justify, walked on the simulator.
//
// The flow is synthetic and bundled (`WalkFlows/text-walk.json`): the same heading and the same rich text, each
// drawn left-aligned and then justified, with a colour run in both, bold and a link in the rich text. The walk
// captures the screen (the crops are the proof of colour and justification), and taps the link in the JUSTIFIED
// rich text, which is drawn through UIKit, to prove it still opens.
import XCTest

final class TextJustifyWalkUITests: XCTestCase {
    static let flowId = "text_walk_flow"
    static let shotDir = "/tmp/sdkdec-1700-shots"

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

    func testColourRunsAndJustifyDrawAndTheJustifiedLinkOpens() {
        let app = XCUIApplication()
        app.launchArguments += ["-appdnaSeedOnboarding", "text-walk", "-appdnaFlow", Self.flowId, "-appdnaLogLevel", "debug"]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 30), "the host did not launch")
        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.buttons["Continue"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the seeded flow never presented")
        sleep(1)
        shot("1700-ios-1-text")
        // The brackets are syntax: neither heading shows them.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "](color:")).firstMatch.exists,
                       "a colour run's syntax is drawn as text")
        // The justified rich text is drawn through a UITextView (the first text view is the justified HEADING,
        // which has no link). Its link is the LAST "walk link" on screen: the left-aligned copy is drawn first.
        XCTAssertGreaterThanOrEqual(app.textViews.count, 2, "the justified heading and rich text are not drawn through UIKit")
        let links = app.links.matching(identifier: "walk link").allElementsBoundByIndex
        NSLog("TEXTWALK links found=\(links.count) frames=\(links.map { $0.frame })")
        XCTAssertEqual(links.count, 2, "both copies of the rich text carry their link")
        // 🔴 CONTROL: the left-aligned copy is SwiftUI Text, whose links have always opened the step's in-app
        // browser. Whatever that browser shows is what the justified copy must also show.
        let frames = links.map { $0.frame }
        func openAndClose(_ frame: CGRect, _ tag: String) -> Bool {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            sleep(3)
            shot("1700-ios-2-\(tag)-after-tap")
            NSLog("TEXTWALK \(tag) after tap: webViews=\(app.webViews.count) done=\(app.buttons["Done"].exists) close=\(app.buttons["Close"].exists) safari=\(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state.rawValue)")
            // The step's in-app browser: a web view, closed by its own "Close" (the step has a "Close" too, under it).
            let opened = app.webViews.count > 0
            let closers = app.buttons.matching(identifier: "Close").allElementsBoundByIndex.filter { $0.isHittable }
            closers.last?.tap()
            sleep(2)
            return opened
        }
        XCTAssertTrue(openAndClose(frames[0], "left"), "control: the SwiftUI link opened nothing the harness can see")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10), "did not return to the step after the control")
        XCTAssertTrue(openAndClose(frames[1], "justified"), "the justified link did not open the in-app browser")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10), "did not return to the step")
        NSLog("TEXTWALK link tapped; webViews=\(app.webViews.count) safari=\(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state.rawValue)")
    }
}
