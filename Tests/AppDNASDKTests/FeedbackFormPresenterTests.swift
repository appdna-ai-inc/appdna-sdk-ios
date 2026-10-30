// FeedbackFormPresenterTests.swift
//
// The controller a survey's feedback form is presented on.
//
// 🔴 The form was presented on the topmost presented controller, taken unconditionally. At the
// moment the follow-up runs, that is the survey sheet being dismissed — and UIKit does not leak
// the way Android did. It logs
//
//     Attempt to present <UIAlertController> on <…> which is already presenting / being dismissed
//
// and does NOTHING. The form silently never appeared, on the branch a user takes when they have
// just said the experience was bad.
//
// The issue said this "is not reproducible from here: the simulator on the bridge has no tap verb".
// That is true of driving a survey by hand; it is not true of the DECISION, which is a pure
// function over a controller hierarchy.
//
// 🔴 The first version of these tests called the real `present(_:animated:completion:)` and the
// run HUNG: there is no active window scene in a unit-test host, so the transition never completes
// and the completion handler never fires. One test passed, the next never returned, and the suite
// sat there looking like a slow build. The hierarchy is stubbed now — `presentedViewController` is
// overridable, which is all the function under test reads.
import XCTest
import UIKit
@testable import AppDNASDK

@MainActor
final class FeedbackFormPresenterTests: XCTestCase {

    /// A controller whose presentation chain is whatever the test says it is.
    private final class StubController: UIViewController {
        var stubPresented: UIViewController?
        var stubDismissing = false
        override var presentedViewController: UIViewController? { stubPresented }
        override var isBeingDismissed: Bool { stubDismissing }
    }

    private func chain(_ controllers: [StubController]) {
        for (a, b) in zip(controllers, controllers.dropFirst()) { a.stubPresented = b }
    }

    func testAPlainControllerIsItsOwnPresenter() {
        let root = StubController()
        XCTAssertTrue(SurveyManager.presentableController(from: root) === root)
    }

    func testWalksToTheTopWhenNothingIsDismissing() {
        let root = StubController(), sheet = StubController(), inner = StubController()
        chain([root, sheet, inner])
        XCTAssertTrue(
            SurveyManager.presentableController(from: root) === inner,
            "a live presented controller is still the right place for the form",
        )
    }

    func testStopsABOVEaControllerThatIsBeingDismissed() {
        let root = StubController(), dying = StubController()
        dying.stubDismissing = true
        chain([root, dying])
        XCTAssertTrue(
            SurveyManager.presentableController(from: root) === root,
            "the form must land on the presenter, NOT on the sheet that is going away — presenting "
            + "on that one is the silent no-op this issue is about",
        )
    }

    func testSkipsOnlyTheDyingLayerAndNotTheLiveOneBeneathIt() {
        let root = StubController(), live = StubController(), dying = StubController()
        dying.stubDismissing = true
        chain([root, live, dying])
        XCTAssertTrue(
            SurveyManager.presentableController(from: root) === live,
            "walking must stop at the live layer under the dismissing one, not fall back to the root",
        )
    }

    /// The exact shape of the reported defect: the survey sheet on top, mid-dismissal, and the host
    /// underneath it. Before the fix this returned the sheet and the form was never seen.
    func testTheSurveySheetMidDismissalYieldsTheHostBeneath() {
        let host = StubController(), surveySheet = StubController()
        surveySheet.stubDismissing = true
        chain([host, surveySheet])
        let chosen = SurveyManager.presentableController(from: host)
        XCTAssertFalse(chosen.isBeingDismissed, "never return a controller that cannot present")
        XCTAssertTrue(chosen === host)
    }
}
