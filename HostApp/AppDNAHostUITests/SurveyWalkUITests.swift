// SurveyWalkUITests.swift — a survey, presented and ANSWERED on a device.
//
// #1023. A survey had never been walked. The onboarding flow had this treatment and nothing
// presented a SURVEY and answered one, so four behaviours were unproven on both platforms:
// sentiment → follow-up routing, `trigger_winback` (which only signals), the feedback form, and
// `show_if` questions appearing as answers change.
//
// 🔴 IT ANSWERS THE SURVEY, it does not photograph it (Rule 24). The emoji is TAPPED, the
// conditional question is asserted to have APPEARED because of that tap, and the follow-up branch
// is asserted by the words the probe authored into it — `show_feedback_form` carries the message
// "NEGATIVE BRANCH", which no other screen can produce.
//
// The survey comes from `scripts/spec502/probe-survey-walk.ts`: a five-emoji scale, a `show_if`
// free-text question that exists only for the two unhappy faces, and both follow-up branches.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class SurveyWalkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var surveyId: String? { TestCredentials.surveyId.isEmpty ? nil : TestCredentials.surveyId }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testASurveyIsAnsweredOnADevice() throws {
        guard let apiKey, let surveyId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest --survey <id>")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaSurvey", surveyId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.survey"].tap()
            presented = app.staticTexts["How was the walk?"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the survey never presented — config did not arrive")
        shot(app, "01-scale")

        /*
         * 🔴 The UNHAPPY face, deliberately: it is the one that both routes NEGATIVE and satisfies
         * the `show_if` on the next question, so one tap proves two behaviours and a miss on either
         * is unambiguous.
         */
        let angry = app.staticTexts["😡"]
        XCTAssertTrue(angry.waitForExistence(timeout: 5), "the authored emoji scale did not render")
        angry.tap()

        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no Next after answering")
        next.tap()

        // #1023 — `show_if`: this question exists only because the answer was one of the two
        // unhappy faces. An emoji answer is stored as the EMOJI, not its index, so the condition is
        // written against the emoji — a `show_if` against `[0, 1]` matches nothing and the question
        // silently never appears.
        XCTAssertTrue(
            app.staticTexts["What went wrong?"].waitForExistence(timeout: 8),
            "the show_if question did not appear for an answer that satisfies its condition",
        )
        shot(app, "02-show-if")

        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Which part?"].waitForExistence(timeout: 8), "the survey did not advance")

        app.buttons["Submit"].firstMatch.tap()

        // The negative branch is `show_feedback_form`, whose message the probe authored as
        // "NEGATIVE BRANCH" — a string no other surface in this app can produce.
        let followUp = app.staticTexts["NEGATIVE BRANCH"]
        XCTAssertTrue(
            followUp.waitForExistence(timeout: 10),
            "the negative follow-up did not appear.\nTREE:\n" + String(app.debugDescription.prefix(3000)),
        )
        shot(app, "03-follow-up")
    }
}
