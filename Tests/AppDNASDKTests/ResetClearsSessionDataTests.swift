import XCTest
@testable import AppDNASDK

/// 🔴 USER A'S ONBOARDING ANSWERS SURVIVED THE SIGN-OUT AND RENDERED INTO USER B'S PAYWALL.
///
/// `SessionDataStore` is a PERSISTED process-global — `UserDefaults` here, `SharedPreferences` on
/// Android — holding three buckets: onboarding responses, computed data, session data. `AppDNA.reset()`
/// cleared identity, exposures, message session and survey session, and NEVER TOUCHED IT. Neither did
/// `shutdown()`. `clearAll()` existed on both platforms and had ZERO callers.
///
/// So on a shared device — a family tablet, a hot-desk phone, a demo unit, a resold handset — user B
/// could read user A's onboarding answers and structured location straight back out, via
/// `getOnboardingResponses()`, `session.get(_:)`, `getLocationData(fieldId:)`.
///
/// And worse than the read: `TemplateEngine.buildContext()` feeds all three buckets into the `{{…}}`
/// namespace, so A's answers RENDERED INTO B's paywall, onboarding and in-app-message copy. "Welcome
/// back, {{onboarding.first_name}}" — with the wrong name. It survived app restarts, because the store
/// is on disk. The file's own comment said the data was "not sensitive"; it is an email, a name and a
/// location.
///
/// These tests assert the LEAK IS CLOSED, not that a method was called: they write the data, reset, and
/// read back through the same surface a host (or the template engine) would use. A test asserting
/// `verify(clearAll)` would pass against a `clearAll()` that does nothing.
final class ResetClearsSessionDataTests: XCTestCase {

    private var store: SessionDataStore { SessionDataStore.shared }

    override func setUp() {
        super.setUp()
        store.clearAll()
    }

    override func tearDown() {
        store.clearAll()
        super.tearDown()
    }

    /// User A fills in an onboarding flow: an email, a name, a location. Real PII.
    private func signInAsUserAAndAnswerOnboarding() {
        // Responses are keyed by STEP id, each step holding its own field map — the shape the flow
        // manager persists on completion.
        store.setOnboardingResponses([
            "step_email": ["email": "alice@example.com"],
            "step_name": ["first_name": "Alice"],
            "step_goal": ["goal": "lose_weight"],
        ])
        store.mergeComputedData(["bmi": 22.4])
        store.setSessionData(key: "last_city", value: "Warsaw")
    }

    /// `reset()` dispatches onto the SDK's private serial queue, so the assertions have to wait for the
    /// work to land. The queue is not reachable from a test (`shared` is private, correctly), so this
    /// waits on the OBSERVABLE EFFECT rather than on an internal — which is the right thing to wait on
    /// anyway: it is exactly what a host would see.
    ///
    /// It used to give up after 2 seconds and deliberately NOT assert, on the reasoning that "timed out"
    /// says nothing about the bug while the assertions below name it. That reasoning had it backwards,
    /// and CI proved it: on a runner also doing a Debug build, a Release build and 900 other tests, the
    /// clear had not landed inside 2s and the test reported *"user B can read user A's onboarding
    /// answers"* — a data-leak message for what was only a slow machine. The scariest message in the
    /// file, for a non-bug, while passing every time locally.
    ///
    /// So it now waits long enough for a loaded runner AND fails explicitly when it does not land. A
    /// real hang is still caught — it just gets named for what it is, and the leak assertions below
    /// keep their meaning because they only ever run once the reset has actually happened.
    private func resetAndWait(
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        AppDNA.reset()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.onboardingResponses.isEmpty && store.computedData.isEmpty { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail(
            "AppDNA.reset() did not clear the store within \(timeout)s. This is a TIMEOUT, not a leak: "
            + "the assertions below would have reported user A's data as readable by user B, when the "
            + "truth is the reset had not finished yet.",
            file: file,
            line: line
        )
    }

    func testResetClearsEveryBucketSoUserBCannotReadUserAsAnswers() {
        signInAsUserAAndAnswerOnboarding()

        // Sanity: the data really is there before the sign-out. Without this, "empty after reset" would
        // also pass against a store that never stored anything.
        XCTAssertEqual(store.onboardingResponses["step_email"]?["email"] as? String, "alice@example.com")
        XCTAssertEqual(store.getSessionData(key: "last_city") as? String, "Warsaw")

        resetAndWait()

        XCTAssertTrue(
            store.onboardingResponses.isEmpty,
            "user B can read user A's onboarding answers after A signed out"
        )
        XCTAssertTrue(
            store.computedData.isEmpty,
            "user B can read user A's computed data after A signed out"
        )
        XCTAssertNil(
            store.getSessionData(key: "last_city"),
            "user B can read user A's session data after A signed out"
        )
    }

    /// The bucket that mattered most, on its own: this is what the template engine reads. A stale
    /// `first_name` here does not merely leak — it PRINTS, in user B's paywall copy.
    func testAfterResetTheTemplateNamespaceIsEmpty() {
        signInAsUserAAndAnswerOnboarding()
        XCTAssertEqual(store.onboardingResponses["step_name"]?["first_name"] as? String, "Alice")

        resetAndWait()

        XCTAssertNil(
            store.onboardingResponses["step_name"]?["first_name"],
            "\"Welcome back, {{onboarding.first_name}}\" would still render Alice's name to user B"
        )
    }

    /// `shutdown()` is a LIFECYCLE stop, not a user change. Clearing a user's answers because the app is
    /// tearing down would be a different bug — the same person relaunches and their flow is gone. Pinned
    /// so a later tidy-up cannot quietly collapse the two.
    func testShutdownDoesNotClearSessionData() {
        signInAsUserAAndAnswerOnboarding()

        AppDNA.shutdown()

        XCTAssertEqual(
            store.onboardingResponses["step_email"]?["email"] as? String,
            "alice@example.com",
            "shutdown() erased the user's own onboarding answers — it is not a sign-out"
        )
    }
}
