// AgreementConsentsWalkUITests.swift — one Agreement with three consents, walked on the simulator.
//
// Synthetic flow (`WalkFlows/consents-walk.json`): consents "terms" (required), "news" (optional) and "age"
// (required). The walk OPERATES the gate: Continue with nothing checked stays put, with only one required consent
// checked still stays put, with both required ones checked advances; the optional one is never needed. The stored
// responses are read back from the host's raw bucket.
import XCTest

final class AgreementConsentsWalkUITests: XCTestCase {
    static let flowId = "consents_walk_flow"
    static let shotDir = "/tmp/sdkdec-1765-shots"

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

    func testEachRequiredConsentGatesTheCtaAndEachIsStoredUnderItsOwnKey() {
        let app = XCUIApplication()
        app.launchArguments += ["-appdnaSeedOnboarding", "consents-walk", "-appdnaFlow", Self.flowId, "-appdnaLogLevel", "debug"]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 30), "the host did not launch")
        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["Before you start"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the seeded flow never presented")
        let terms = app.switches["agreement.consent.terms"].exists ? app.switches["agreement.consent.terms"] : app.descendants(matching: .any)["agreement.consent.terms"]
        let news = app.descendants(matching: .any)["agreement.consent.news"]
        let age = app.descendants(matching: .any)["agreement.consent.age"]
        XCTAssertTrue(terms.waitForExistence(timeout: 5) && news.exists && age.exists, "three consent checkboxes")
        shot("1765-ios-1-three-consents")

        let finished = app.staticTexts["Walk finished"]
        app.buttons["Continue"].tap()
        XCTAssertFalse(finished.waitForExistence(timeout: 2), "advanced with no consent checked")
        terms.tap()
        app.buttons["Continue"].tap()
        XCTAssertFalse(finished.waitForExistence(timeout: 2), "advanced with a required consent unchecked")
        shot("1765-ios-2-one-of-two-required")
        age.tap()
        shot("1765-ios-3-both-required")
        app.buttons["Continue"].tap()
        XCTAssertTrue(finished.waitForExistence(timeout: 5), "did not advance with both required consents checked")
        app.buttons["Finish"].tap()

        let raw = app.staticTexts["host.responsesRaw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 10))
        NSLog("CONSENTWALK responses=\(raw.label)")
        XCTAssertTrue(raw.label.contains("\"agree.terms\":true"), raw.label)
        XCTAssertTrue(raw.label.contains("\"agree.age\":true"), raw.label)
        XCTAssertTrue(raw.label.contains("\"agree.news\":false"), raw.label)
    }
}
