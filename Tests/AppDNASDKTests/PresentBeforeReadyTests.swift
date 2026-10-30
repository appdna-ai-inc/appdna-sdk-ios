import XCTest
import UIKit
@testable import AppDNASDK

/**
 "ONBOARDING FLOW NOT FOUND" MUST NOT BE SAID BEFORE ANYTHING HAS BEEN LOOKED UP.

 `present` returned `false` with that line both when a flow genuinely does not exist and when the
 SDK had simply not loaded its config yet. A host could not tell the two apart — the return is one
 boolean — and an integrator reading the log went to their flow id and their console, the one place
 the problem is not.

 🔴 On a COLD FIRST LAUNCH the second window is long. Measured on an iPhone simulator driving the
 flow with no tap: `present` answered `false` on attempts 1-3 and `true` on attempt 4, roughly
 three seconds in, on every cold launch. On a Pixel-class Android emulator the same window ran
 ~20-25s, and with a bad network one run took 103s on an unchanged process. Configure reaches its
 config load only after a cold init and a bootstrap round trip; on every later launch the cached
 config is already on disk and the window closes before a user can reach a button — which is why
 this only ever looks like a first-launch bug.

 The fix is two things, and this covers both: the log tells the truth, and `AppDNA.isReady` lets a
 host ask which case it is instead of guessing. Mirrors `PresentBeforeReadyTest` on Android.
 */
final class PresentBeforeReadyTests: XCTestCase {

    private func manager() -> OnboardingFlowManager {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.presentready.\(UUID().uuidString)")
        // No config loaded — exactly the cold-first-launch state this is about.
        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        return OnboardingFlowManager(remoteConfigManager: rcm, eventTracker: EventTracker(identityManager: identity))
    }

    private func presentLogs(_ flowId: String?) -> String {
        var captured: [String] = []
        Log.testSink = { captured.append($0) }
        defer { Log.testSink = nil }
        _ = manager().present(flowId: flowId, from: UIViewController(), delegate: nil)
        return captured.joined(separator: "\n")
    }

    func testAppDNAExposesIsReadyAndItIsFalseBeforeConfigure() {
        // The host-facing half: a synchronous answer to "should I retry, or is the flow gone?".
        XCTAssertFalse(AppDNA.isReady, "an unconfigured SDK must not report itself ready")
    }

    func testPresentingBeforeTheConfigLoadsDoesNotClaimTheFlowIsMissing() {
        let logs = presentLogs("some-flow-id")
        XCTAssertFalse(logs.contains("Onboarding flow not found"),
                       "the SDK has not looked anything up yet, so it must not say 'not found' — logs were:\n\(logs)")
        XCTAssertTrue(logs.contains("still") && logs.contains("configuring") && logs.contains("onReady"),
                      "it must say WHY, and point at the thing to wait for — logs were:\n\(logs)")
        XCTAssertTrue(logs.contains("some-flow-id"), "it must name the flow id the host asked for")
    }

    func testTheNoFlowIdCaseIsCoveredToo() {
        // `present(nil)` resolves the ACTIVE flow; the same window applies.
        let logs = presentLogs(nil)
        XCTAssertFalse(logs.contains("Onboarding flow not found"))
        XCTAssertTrue(logs.contains("active"))
    }

    func testPresentStillReturnsFalse() {
        // A host that already handles `false` must keep working unchanged.
        XCTAssertFalse(manager().present(flowId: "some-flow-id", from: UIViewController(), delegate: nil))
    }

    /*
     * 🔴 THE CASE THE REST OF THIS FILE COULD NOT SEE.
     *
     * Every test above builds an `OnboardingFlowManager` directly, so the manager always exists.
     * At the REAL entry point it does not: `shared.onboardingFlowManager` is assigned at the end
     * of the bootstrap, and before that `AppDNA.presentOnboarding` was
     * `nil?.present(...) ?? false` — a silent `false` with no log at all. The honest-vs-misleading
     * branch added to the manager therefore could never run in the one case it exists for.
     *
     * Found by a device run, not by a test: 20 calls on an iPhone simulator held before ready with
     * a blackhole base URL, 17 of them logging NOTHING. Android did not have the hole — it already
     * logged on its nil-manager branch — which is why only one platform looked correct.
     *
     * This asserts the entry point itself, on an SDK that was never configured, which is the state
     * a unit test CAN reach.
     */
    func testPresentOnboardingLogsWhenTheManagerDoesNotExistYet() {
        var captured: [String] = []
        Log.testSink = { captured.append($0) }
        defer { Log.testSink = nil }

        // Never configured in this process ⇒ `shared.onboardingFlowManager` is nil.
        XCTAssertFalse(AppDNA.isReady, "precondition: the SDK must not be ready for this to test anything")
        let shown = AppDNA.presentOnboarding(flowId: "some-flow-id", from: UIViewController(), delegate: nil)

        let logs = captured.joined(separator: "\n")
        XCTAssertFalse(shown, "nothing can be presented before the managers are wired")
        XCTAssertTrue(logs.contains("was NOT looked up"),
                      "a silent false is the defect — the caller must be told WHY. Logs were:\n\(logs)")
        XCTAssertFalse(logs.contains("Onboarding flow not found"),
                       "it has not looked anything up yet")
        XCTAssertTrue(logs.contains("onReady"), "it must name what to wait for")
    }
}

