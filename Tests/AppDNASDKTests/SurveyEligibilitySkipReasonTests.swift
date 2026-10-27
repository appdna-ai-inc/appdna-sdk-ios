import XCTest
@testable import AppDNASDK

/// No SDK computes a love score yet, so the stored value is always 0 and a survey whose `love_score_range` has a
/// minimum above 0 is never shown. It used to be skipped with no trace; the skip now carries a reason, which the
/// trigger loop writes to the debug log.
final class SurveyEligibilitySkipReasonTests: XCTestCase {
    private func makeManager() -> SurveyManager {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        return SurveyManager(remoteConfigManager: rcm, eventTracker: EventTracker(identityManager: identity))
    }

    private func rules(_ json: String) throws -> SurveyTriggerRules {
        try JSONDecoder().decode(SurveyTriggerRules.self, from: Data(json.utf8))
    }

    func testALoveScoreMinimumAboveZeroIsSkippedAndSaysTheDeviceHasNoLoveScore() throws {
        UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.love_score")
        let reason = makeManager().eligibilitySkipReason(surveyId: "s1", rules: try rules(#"{"event":"e","love_score_range":{"min":40,"max":100}}"#))
        XCTAssertEqual(reason, "Survey s1 skipped — love_score_range not met (the device has no love score)")
    }

    func testNoLoveScoreRuleOrARangeFromZeroIsNotASkip() throws {
        XCTAssertNil(makeManager().eligibilitySkipReason(surveyId: "s1", rules: try rules(#"{"event":"e"}"#)))
        XCTAssertNil(makeManager().eligibilitySkipReason(surveyId: "s1", rules: try rules(#"{"event":"e","love_score_range":{"min":0,"max":100}}"#)))
    }

    func testAnUnmetMinSessionsIsSkippedWithItsOwnReason() throws {
        XCTAssertEqual(makeManager().eligibilitySkipReason(surveyId: "s2", rules: try rules(#"{"event":"e","min_sessions":5000}"#)),
                       "Survey s2 skipped — min_sessions not reached")
    }
}
