import XCTest
@testable import AppDNASDK

/// Experiment audience gate: traffic allocation + the targeting rules the Console offers, evaluated on device before
/// a variant is assigned. The shared fixtures (`sdk-shared-fixtures/experiment_serving/*get_variant*`, driven by
/// SharedFixtureTests) pin the cross-platform answers; these tests pin the edges and the distributions.
final class ExperimentEligibilityTests: XCTestCase {

    private func ctx(app: String? = "3.0.0", region: String? = "US", installed: Int64? = 2_000, traits: [String: Any] = [:]) -> ExperimentEligibilityContext {
        ExperimentEligibilityContext(platform: "ios", appVersion: app, deviceRegion: region, installEpochMs: installed, traits: traits)
    }

    private func targeting(_ json: String) throws -> ExperimentTargeting {
        try JSONDecoder().decode(ExperimentTargeting.self, from: Data(json.utf8))
    }

    // MARK: - Allocation

    func testIsAllocatedEdges() {
        XCTAssertTrue(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: nil), "legacy doc = everyone")
        XCTAssertTrue(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: 1.0))
        XCTAssertTrue(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: 7))
        XCTAssertFalse(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: 0))
        XCTAssertFalse(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: -1))
        XCTAssertFalse(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: .nan))
        XCTAssertFalse(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: .infinity))
    }

    func testAllocationShareIndependenceAndGrowthStability() {
        var in30 = Set<String>(), in60 = Set<String>()
        var controlIn30 = 0
        for i in 0..<10_000 {
            let u = "user_\(i)"
            if ExperimentEligibility.isAllocated(experimentId: "exp", salt: "salt", userId: u, trafficAllocation: 0.3) {
                in30.insert(u)
                let variant = ExperimentBucketer.assignVariant(
                    experimentId: "exp", userId: u, salt: "salt",
                    variants: [ExperimentVariant(id: "control", weight: 0.5, payload: nil), ExperimentVariant(id: "b", weight: 0.5, payload: nil)])
                if variant == "control" { controlIn30 += 1 }
            }
            if ExperimentEligibility.isAllocated(experimentId: "exp", salt: "salt", userId: u, trafficAllocation: 0.6) { in60.insert(u) }
        }
        XCTAssertEqual(Double(in30.count) / 10_000, 0.3, accuracy: 0.02)
        XCTAssertEqual(Double(in60.count) / 10_000, 0.6, accuracy: 0.02)
        XCTAssertTrue(in30.isSubset(of: in60), "growing the allocation must keep every user who was in")
        // Allocation does not skew the variant split among the allocated users.
        XCTAssertEqual(Double(controlIn30) / Double(in30.count), 0.5, accuracy: 0.03)
    }

    // MARK: - Versions

    func testCompareVersions() {
        XCTAssertEqual(ExperimentEligibility.compareVersions("2.9.3", "2.10"), .orderedAscending)
        XCTAssertEqual(ExperimentEligibility.compareVersions("2.10.0-beta", "2.10"), .orderedSame)
        XCTAssertEqual(ExperimentEligibility.compareVersions("10", "9.9.9"), .orderedDescending)
        XCTAssertEqual(ExperimentEligibility.compareVersions(" 1.2 ", "1.2.0.0"), .orderedSame)
        XCTAssertEqual(ExperimentEligibility.compareVersions("1.2.1", "1.2"), .orderedDescending)
        XCTAssertNil(ExperimentEligibility.compareVersions("beta", "1.0"))
        XCTAssertNil(ExperimentEligibility.compareVersions("1.0", ""))
    }

    // MARK: - Rules

    func testEachRule() throws {
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: nil, startedAtMs: nil, context: ctx()))
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting("{}"), startedAtMs: nil, context: ctx()))
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"countries":[]}"#), startedAtMs: nil, context: ctx(region: nil)), "empty list = every country")
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: try targeting(#"{"countries":["DE"]}"#), startedAtMs: nil, context: ctx()), .country)
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"countries":[" de ","us"]}"#), startedAtMs: nil, context: ctx(region: "us")))
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: try targeting(#"{"min_app_version":"3.0.1"}"#), startedAtMs: nil, context: ctx()), .minAppVersion)
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"min_app_version":"3"}"#), startedAtMs: nil, context: ctx()))
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"min_app_version":"  "}"#), startedAtMs: nil, context: ctx(app: nil)), "blank = no rule")
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: try targeting(#"{"new_users_only":true}"#), startedAtMs: 2_001, context: ctx()), .newUsersOnly)
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"new_users_only":true}"#), startedAtMs: 2_000, context: ctx()))
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: try targeting(#"{"new_users_only":false}"#), startedAtMs: nil, context: ctx(installed: nil)))
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: try targeting(#"{"new_users_only":true}"#), startedAtMs: 1, context: ctx(installed: nil)), .newUsersOnly)
        let traits = try targeting(#"{"user_traits":[{"trait":"plan","operator":"in","value":["pro","team"]},{"trait":"beta","operator":"exists"}]}"#)
        XCTAssertNil(ExperimentEligibility.failedRule(targeting: traits, startedAtMs: nil, context: ctx(traits: ["plan": "pro", "beta": true])))
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: traits, startedAtMs: nil, context: ctx(traits: ["plan": "pro"])), .userTraits)
    }

    func testMalformedTargetingFailsClosedAndDoesNotDropTheExperiment() throws {
        let doc = #"{"id":"e","status":"running","salt":"s","platforms":["ios"],"variants":[{"id":"a","weight":1}],"targeting":{"countries":"US"}}"#
        let cfg = try JSONDecoder().decode(ExperimentConfig.self, from: Data(doc.utf8))
        XCTAssertEqual(cfg.targeting?.malformed, true)
        XCTAssertEqual(ExperimentEligibility.failedRule(targeting: cfg.targeting, startedAtMs: nil, context: ctx()), .malformedTargeting)
    }

    func testServedDocDecodesNestedTargetingAllocationAndStart() throws {
        let doc = #"""
        {"id":"e","status":"running","salt":"s","platforms":["ios","android"],"traffic_allocation":0.25,"started_at_ms":1767225600000,
         "variants":[{"id":"a","weight":1}],
         "targeting":{"countries":["US"],"min_app_version":"2.0","new_users_only":true,"user_traits":[{"trait":"plan","operator":"eq","value":"pro"}]}}
        """#
        let cfg = try JSONDecoder().decode(ExperimentConfig.self, from: Data(doc.utf8))
        XCTAssertEqual(cfg.traffic_allocation, 0.25)
        XCTAssertEqual(cfg.started_at_ms, 1_767_225_600_000)
        XCTAssertEqual(cfg.targeting?.countries, ["US"])
        XCTAssertEqual(cfg.targeting?.min_app_version, "2.0")
        XCTAssertEqual(cfg.targeting?.new_users_only, true)
        XCTAssertEqual(cfg.targeting?.user_traits?.first?.trait, "plan")
        XCTAssertEqual(cfg.targeting?.malformed, false)
    }

    // MARK: - Manager

    func testManagerOutsideAudienceNoVariantNoExposureThenInsideExposedOnce() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        let tracker = EventTracker(identityManager: identity)
        var events: [String] = []
        tracker.eventSink = { events.append($0.event_name) }
        identity.identify(userId: "user_4", traits: [:])
        var region = "FR"
        let em = ExperimentManager(remoteConfigManager: rcm, identityManager: identity, eventTracker: tracker,
                                   eligibilityContext: { traits in ExperimentEligibilityContext(platform: "ios", appVersion: "1", deviceRegion: region, installEpochMs: nil, traits: traits) })
        let doc = #"{"id":"e","status":"running","salt":"s","platforms":["ios"],"traffic_allocation":1,"variants":[{"id":"a","weight":1}],"targeting":{"countries":["US"]}}"#
        rcm._injectExperimentsForTesting(["e": try JSONDecoder().decode(ExperimentConfig.self, from: Data(doc.utf8))])

        XCTAssertNil(em.getVariant(experimentId: "e"))
        XCTAssertFalse(em.isInVariant(experimentId: "e", variantId: "a"))
        XCTAssertNil(em.getExperimentConfig(experimentId: "e", key: "k"))
        XCTAssertTrue(em.getExposures().isEmpty)
        XCTAssertFalse(events.contains("experiment_exposure"))

        region = "US"
        XCTAssertEqual(em.getVariant(experimentId: "e"), "a")
        XCTAssertEqual(em.getVariant(experimentId: "e"), "a")
        XCTAssertEqual(events.filter { $0 == "experiment_exposure" }.count, 1)
    }
}
