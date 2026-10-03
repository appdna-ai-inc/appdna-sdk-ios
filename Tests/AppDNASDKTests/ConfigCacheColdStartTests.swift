import XCTest
@testable import AppDNASDK

/// An offline cold start on iOS: what a previous online session cached is served by a NEW manager with no fetch.
/// iOS reads its caches with JSONSerialization (the dictionaries and arrays a fetch gives), so the sections load;
/// what was missing is the hand-off of cached surveys to the survey handler, which `configure` attaches AFTER the
/// manager has read the cache. Android `ConfigCacheColdStartTest`, same cases.
final class ConfigCacheColdStartTests: XCTestCase {

    /// NEGATIVE CONTROL (base code): `onSurveyConfigsUpdated` only stored the handler — the cached surveys reached it
    /// on the next fetch, never offline (`delivered` stays nil).
    func testCachedSurveysReachALateSurveyHandler() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let doc: [String: Any] = ["surveys": ["s1": ["name": "Survey", "survey_type": "nps",
                                                       "questions": [["id": "q1", "type": "nps", "text": "How likely?"]]]]]
        cache.storeSurveys(try JSONSerialization.data(withJSONObject: doc))

        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        XCTAssertEqual(Set(rcm.getSurveyConfigs().keys), ["s1"], "the cached survey did not load")

        let delivered = expectation(description: "cached surveys handed to the survey handler")
        var keys: Set<String>?
        rcm.onSurveyConfigsUpdated { configs in
            keys = Set(configs.keys)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(keys, ["s1"])
    }

    func testCachedExperimentsLoadOffline() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let experiments: [String: Any] = ["experiments": ["e1": ["id": "e1", "status": "running", "salt": "s",
                                                                  "platforms": ["ios"], "variants": [["id": "a", "weight": 1]],
                                                                  "targeting": ["countries": ["US"]]]]]
        cache.storeExperiments(try JSONSerialization.data(withJSONObject: experiments))
        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        let cfg = try XCTUnwrap(rcm.getExperimentConfig(id: "e1"), "the cached experiment did not load")
        XCTAssertEqual(cfg.variants?.first?.id, "a")
        XCTAssertEqual(cfg.targeting?.countries, ["US"])
    }
}
