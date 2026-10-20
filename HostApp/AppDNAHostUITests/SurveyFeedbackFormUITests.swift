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
    /// #1041 — ITS OWN survey. This walk waits for `survey.rating.1`, so it needs a survey whose
    /// FIRST question is a NUMERIC rating. Sharing `surveyId` with the survey walk — whose
    /// survey opens on an emoji scale — made it look for a control that cannot exist and
    /// report "the survey never presented — config did not arrive": a sentence about the
    /// network, for a problem about the survey's shape. Empty skips.
    private var surveyId: String? { TestCredentials.feedbackSurveyId.isEmpty ? nil : TestCredentials.feedbackSurveyId }

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

    /**
     #920 — A FORM THAT IS TAKEN AWAY GOES, AND IS RECORDED AS TAKEN AWAY.

     The test above proves the form appears. This proves the other half: when the host tears its
     presentation stack down — a window rebuilt, a root view controller swapped, a deep link
     replacing the stack — the form goes with it instead of outliving the context it belongs to.

     The swap is driven by backgrounding the app and bringing it back, which is deterministic and
     test-controlled, rather than by a timer this test would have to race.

     🔴 What is asserted here is the OBSERVABLE half: the alert is gone and the host is alive. The
     `feedback_form_dismissed` event with `reason: "presenter_released"` is asserted in
     `OrphanedFeedbackFormTests`, because a UI test has no access to the SDK's event tracker — the
     two together are the claim.
     */
    func testAFormIsTakenDownWithItsPresenter() throws {
        guard let apiKey, let surveyId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-appdnaApiKey", apiKey,
            "-appdnaSurvey", surveyId,
            // 🔴 A VALUE, not a bare flag: `Launch.arg` reads UserDefaults, which only
            // parses `-key value` pairs — a valueless flag is silently dropped, and the
            // swap simply never armed.
            "-appdnaSwapRootOnForeground", "1",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 15))

        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.survey"].tap()
            presented = app.buttons["survey.rating.1"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(presented, "the survey never presented — config did not arrive")

        app.buttons["survey.rating.1"].tap()
        XCTAssertTrue(app.buttons["survey.submit"].waitForExistence(timeout: 5))
        app.buttons["survey.submit"].tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the feedback form must be up before it can be orphaned")

        // Take the presenter away, the way a host would.
        XCUIDevice.shared.press(.home)
        app.activate()

        // 🔴 Assert the HARNESS first. Without this, "the alert is gone" and "the swap never ran"
        // are the same green, and "the alert is still there" blames the SDK for a test that did
        // nothing — which is exactly what the first run of this test did.
        XCTAssertTrue(
            app.staticTexts["host.swappedRoot"].waitForExistence(timeout: 20),
            "the host did not swap its root view controller, so nothing below is about the SDK",
        )
        XCTAssertFalse(
            alert.waitForExistence(timeout: 3),
            "the form must NOT outlive the controller that presented it",
        )
        XCTAssertEqual(app.state, .runningForeground, "and the host must survive losing it")
    }
}
