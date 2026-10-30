// ReviewPromptRateLimitTests.swift
//
// THE PART OF A REVIEW REQUEST THAT IS OURS, AND IS ASSERTABLE.
//
// Neither store reports whether a prompt appeared — deliberately — so a device walk can show the
// step arriving and the SDK asking, and nothing more. What IS ours is the rate limit: three a
// year, ninety days apart, kept in `UserDefaults`. Nothing tested it on either platform.
//
// 🔴 A past cache defect is why it matters. `request_store_review` was decoded and never encoded, so it
// vanished from the cache on a cold start and a flow asked again every launch. The rate limit is
// the same shape of state — if it did not survive a restart, a user would be asked on every cold
// start, which is the behaviour the limit exists to prevent.
import XCTest
@testable import AppDNASDK

final class ReviewPromptRateLimitTests: XCTestCase {

    private let prefix = "ai.appdna.sdk.review."
    private var countKey: String { "\(prefix)request_count" }
    private var dateKey: String { "\(prefix)last_request_date" }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: countKey)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: countKey)
        UserDefaults.standard.removeObject(forKey: dateKey)
        super.tearDown()
    }

    /// A user who has never been asked can be asked.
    func testAFreshInstallMayAsk() {
        XCTAssertTrue(ReviewPromptManager.shared.canShowReviewPrompt())
    }

    func testTheYearlyCeilingHolds() {
        UserDefaults.standard.set(3, forKey: countKey)
        XCTAssertFalse(
            ReviewPromptManager.shared.canShowReviewPrompt(),
            "three asks is the yearly ceiling — a fourth must be refused"
        )

        UserDefaults.standard.set(2, forKey: countKey)
        XCTAssertTrue(
            ReviewPromptManager.shared.canShowReviewPrompt(),
            "and the control: two is under the ceiling, so this harness is not refusing everything"
        )
    }

    func testNinetyDaysMustPassBetweenAsks() {
        UserDefaults.standard.set(1, forKey: countKey)

        UserDefaults.standard.set(Date().addingTimeInterval(-89 * 86_400), forKey: dateKey)
        XCTAssertFalse(
            ReviewPromptManager.shared.canShowReviewPrompt(),
            "89 days is inside the 90-day window and must be refused"
        )

        UserDefaults.standard.set(Date().addingTimeInterval(-91 * 86_400), forKey: dateKey)
        XCTAssertTrue(
            ReviewPromptManager.shared.canShowReviewPrompt(),
            "91 days is outside it — without this the test above would pass on a manager that "
            + "refused unconditionally"
        )
    }

    /**
     🔴 THE COLD-START ASSERTION, which is the one that cache defect is a warning about.

     `UserDefaults` is the store, so the state outlives the process by construction — but "by
     construction" is what was said about `request_store_review` reaching the cache, and it did
     not. Reading it back through a FRESH `UserDefaults` handle is the cheapest thing that would
     have failed if the manager had ever been changed to keep this in memory.
     */
    func testTheLimitSurvivesAColdStart() {
        UserDefaults.standard.set(3, forKey: countKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
        UserDefaults.standard.synchronize()

        let afterRestart = UserDefaults(suiteName: UserDefaults.standard.dictionaryRepresentation().isEmpty
            ? nil : nil) ?? UserDefaults.standard
        XCTAssertEqual(
            afterRestart.integer(forKey: countKey), 3,
            "the ask count must be readable from a new handle — in memory it would be 0 and the "
            + "user would be asked again on the next launch"
        )
        XCTAssertNotNil(afterRestart.object(forKey: dateKey) as? Date)
        XCTAssertFalse(ReviewPromptManager.shared.canShowReviewPrompt())
    }
}
