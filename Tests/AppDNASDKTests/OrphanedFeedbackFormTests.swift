// OrphanedFeedbackFormTests.swift — #920
//
// A feedback form that is TAKEN AWAY is not a form the user dismissed.
//
// #901 fixed the presentation — the form lands on the controller underneath, which is staying.
// This is the reverse: the form is up and its presenter goes away for a reason of the host's own
// (a window torn down, a root view controller swapped, a deep link replacing the stack). UIKit
// takes the alert down with its presenter and, before this, nothing was recorded — so
// `feedback_form_dismissed` under-counted and two different outcomes looked identical in
// analytics: a user who read the form and closed it, and a user who never saw it at all.
//
// 🔴 The presentation itself is NOT driven here, for the reason `FeedbackFormPresenterTests`
// records: calling the real `present(_:animated:)` in a hostless test target HANGS, because there
// is no active window scene for the transition to complete in. What is driven is the mechanism —
// an observer attached to a controller, and the once-only event — which is the part that was
// missing.
import XCTest
import UIKit
@testable import AppDNASDK

@MainActor
final class OrphanedFeedbackFormTests: XCTestCase {

    private func manager() -> (SurveyManager, () -> [(String, [String: Any])]) {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        let tracker = EventTracker(identityManager: identity)
        var captured: [(String, [String: Any])] = []
        tracker.eventSink = { event in
            captured.append((event.event_name, (event.properties ?? [:]).mapValues { $0.value }))
        }
        return (SurveyManager(remoteConfigManager: rcm, eventTracker: tracker), { captured })
    }

    // MARK: - The observer

    /// The mechanism: an object attached to a controller is released when the controller is, and
    /// its `deinit` is the only signal iOS offers that a presenter has gone.
    func testTheObserverFiresWhenItsControllerIsReleased() {
        var fired = 0
        autoreleasepool {
            let presenter = UIViewController()
            SurveyManager.observeRelease(of: presenter, .init { fired += 1 })
            XCTAssertEqual(fired, 0, "nothing should fire while the controller is alive")
        }
        XCTAssertEqual(fired, 1, "releasing the controller must fire the observer exactly once")
    }

    /// 🔴 And it must not keep the controller alive — an SDK that retains a host's view controller
    /// is a leak the host cannot see, which is worse than the under-counting being fixed.
    func testTheObserverDoesNotRetainItsController() {
        weak var weakPresenter: UIViewController?
        autoreleasepool {
            let presenter = UIViewController()
            weakPresenter = presenter
            SurveyManager.observeRelease(of: presenter, .init { })
            XCTAssertNotNil(weakPresenter)
        }
        XCTAssertNil(weakPresenter, "the observer must not extend its controller's life")
    }

    // MARK: - The event

    func testAnOrphanedFormIsRecordedWithItsReason() {
        let (mgr, events) = manager()
        mgr.feedbackFormResolved = false          // a form is on screen
        mgr.resolveFeedbackForm(reason: "presenter_released")

        let dismissed = events().filter { $0.0 == "feedback_form_dismissed" }
        XCTAssertEqual(dismissed.count, 1)
        XCTAssertEqual(dismissed.first?.1["reason"] as? String, "presenter_released")
    }

    func testAUserDismissalCarriesItsOwnReason() {
        let (mgr, events) = manager()
        mgr.feedbackFormResolved = false
        mgr.resolveFeedbackForm(reason: "user")

        XCTAssertEqual(events().filter { $0.0 == "feedback_form_dismissed" }.count, 1)
        XCTAssertEqual(events().first?.1["reason"] as? String, "user")
    }

    /**
     🔴 EXACTLY ONCE, whichever path gets there first.

     The user taps Cancel and the presenter is released a moment later — both paths reach the same
     resolver, and without the latch the form would be counted twice. Double-counting a dismissal
     is the same analytical lie as missing one, in the other direction.
     */
    func testItIsRecordedOnlyOnce() {
        let (mgr, events) = manager()
        mgr.feedbackFormResolved = false
        mgr.resolveFeedbackForm(reason: "user")
        mgr.resolveFeedbackForm(reason: "presenter_released")
        mgr.resolveFeedbackForm(reason: "presenter_released")

        let dismissed = events().filter { $0.0 == "feedback_form_dismissed" }
        XCTAssertEqual(dismissed.count, 1, "the first resolution wins and the rest are silent")
        XCTAssertEqual(dismissed.first?.1["reason"] as? String, "user")
    }

    /// With no form outstanding — the state before one is ever shown — nothing is recorded. A
    /// presenter released at any other moment must not invent a dismissal.
    func testNothingIsRecordedWhenNoFormIsOutstanding() {
        let (mgr, events) = manager()
        XCTAssertTrue(mgr.feedbackFormResolved, "no form is outstanding before one is shown")
        mgr.resolveFeedbackForm(reason: "presenter_released")
        XCTAssertTrue(events().isEmpty)
    }
}
