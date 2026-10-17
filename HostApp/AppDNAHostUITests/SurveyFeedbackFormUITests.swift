// SurveyFeedbackFormUITests.swift — #901
//
// The end-to-end half of #901: answer a survey NEGATIVELY, let the sheet dismiss, and assert the
// feedback form actually appears. That is the branch where the old code presented an alert on a
// controller that was already being dismissed, which UIKit silently refuses.
//
// It needs a backend, a key and a published survey, so it is SKIPPED unless `TestCredentials` has
// been filled in — `packages/appdna-sdk-ios/**` is a public mirror and must carry no credentials.
// `scripts/sdk-host-ios.ts --uitest --api-key … --survey …` writes them on the Mac before building.
import XCTest

final class SurveyFeedbackFormUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var surveyId: String? { TestCredentials.surveyId.isEmpty ? nil : TestCredentials.surveyId }

    func testANegativeAnswerRaisesTheFeedbackForm() throws {
        guard let apiKey, let surveyId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaSurvey", surveyId]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 15))

        // The SDK fetches its config after configure(); the survey cannot present before it lands.
        // Tapping and retrying is more honest than one long sleep: it records how long it took.
        var presented = false
        for attempt in 0..<12 where !presented {
            app.buttons["host.survey"].tap()
            presented = app.buttons["survey.rating.1"].waitForExistence(timeout: 5)
            if !presented { NSLog("survey not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(presented, "the survey never presented — config did not arrive")

        // 1 of 5 on a CSAT is NEGATIVE, which is the branch that shows the form.
        app.buttons["survey.rating.1"].tap()
        XCTAssertTrue(app.buttons["survey.submit"].waitForExistence(timeout: 5))
        app.buttons["survey.submit"].tap()

        // The form is a UIAlertController. Before the fix it was presented on the survey sheet
        // while that sheet was being dismissed, and UIKit refused it without raising — so this
        // assertion is the whole issue.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: 10),
            "the feedback form did not appear after a negative answer — the alert was presented on "
            + "a controller that could not present it, which is exactly #901",
        )
        XCTAssertTrue(alert.textFields.firstMatch.exists, "the form must offer somewhere to type")

        // And it is operable, not merely present.
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("probe feedback")
        XCTAssertTrue(alert.buttons["Submit"].exists)
        alert.buttons["Submit"].tap()
        XCTAssertFalse(alert.exists, "submitting must dismiss the form")
    }
}
