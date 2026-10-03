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

    // MARK: - parity (Android answers the same — ExperimentEligibilityTest / ExperimentCacheAndDocParseTest)

    func testDeviceRegionIsTheFirstAlpha2Candidate() {
        XCTAssertEqual(DeviceRegion.resolve(["us"]), "US")
        XCTAssertEqual(DeviceRegion.resolve(["", nil, "419", " de "]), "DE")
        XCTAssertNil(DeviceRegion.resolve(["419", "USA", "", nil]))
        XCTAssertNil(DeviceRegion.resolve([]))
        XCTAssertNil(DeviceRegion.resolve(["D1", "Ü1"]), "not ASCII letters")
    }

    // MARK: - Install date (`AppInstallDate`): update / reinstall / restore

    private func tempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("install-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A Documents directory created at `date` (the app container's date — what a restore may carry over).
    private func documents(createdAt date: Date) throws -> URL {
        let dir = tempDir("documents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: dir.path)
        return dir
    }

    private let y2020 = Date(timeIntervalSince1970: 1_577_836_800)
    private let now = Date(timeIntervalSince1970: 1_767_312_000.25)

    /// Fresh install (and a reinstall: the container is new): the first launch writes the marker — excluded from
    /// backup — and every later launch reads the same date.
    func testInstallDateOnAFreshInstallIsTheFirstLaunchAndIsKept() throws {
        let sdk = tempDir("sdk"); defer { try? FileManager.default.removeItem(at: sdk) }
        let docs = try documents(createdAt: now); defer { try? FileManager.default.removeItem(at: docs) }
        let first = AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now)
        XCTAssertEqual(first, 1_767_312_000_250)
        XCTAssertEqual(AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now.addingTimeInterval(86_400)), first,
                       "an update keeps the date")
        let marker = sdk.appendingPathComponent(AppInstallDate.markerFileName)
        XCTAssertEqual(try marker.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try sdk.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    /// Restore from a backup / device transfer: the backup brings back the app's files (a Documents directory from 2020)
    /// and preferences (the old 2020 install-date key), but not the backup-excluded SDK directory. The date is this
    /// launch — nothing restorable is read.
    /// NEGATIVE CONTROL (base code: the earlier of the Documents date and the marker): 2020.
    func testInstallDateAfterARestoreIsTheFirstLaunchNotTheRestoredDates() throws {
        let sdk = tempDir("sdk"); defer { try? FileManager.default.removeItem(at: sdk) }
        let docs = try documents(createdAt: y2020); defer { try? FileManager.default.removeItem(at: docs) }
        UserDefaults.standard.set(y2020.timeIntervalSince1970, forKey: AppInstallDate.legacyStoredKey)
        defer { UserDefaults.standard.removeObject(forKey: AppInstallDate.legacyStoredKey) }
        XCTAssertEqual(AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now), 1_767_312_000_250,
                       "a restored app is a new install on this device")
    }

    /// Update from an SDK version without the marker: the older SDK's backup-excluded directory is there (it survives
    /// an update, never a restore), so the container's date is taken once and written as the marker.
    func testInstallDateOnTheFirstLaunchAfterUpdatingFromAnOlderSdkIsTheContainerDate() throws {
        let sdk = tempDir("sdk"); defer { try? FileManager.default.removeItem(at: sdk) }
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sdk.appendingPathComponent("pending_events.json"))
        let docs = try documents(createdAt: y2020); defer { try? FileManager.default.removeItem(at: docs) }
        XCTAssertEqual(AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now), 1_577_836_800_000)
        // Once: the marker holds it from now on, whatever the container says.
        try FileManager.default.setAttributes([.creationDate: now], ofItemAtPath: docs.path)
        XCTAssertEqual(AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now.addingTimeInterval(86_400)),
                       1_577_836_800_000)
    }

    /// The migration never dates an install in the future (a container date after now — a wrong clock).
    func testInstallDateMigrationNeverLiesInTheFuture() throws {
        let sdk = tempDir("sdk"); defer { try? FileManager.default.removeItem(at: sdk) }
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let docs = try documents(createdAt: now.addingTimeInterval(86_400 * 30)); defer { try? FileManager.default.removeItem(at: docs) }
        XCTAssertEqual(AppInstallDate.read(documentsDirectory: docs, sdkDirectory: sdk, now: now), 1_767_312_000_250)
    }

    /// No marker can be written (the SDK directory's path is a file): unknown, so "new users only" fails closed.
    func testInstallDateIsUnknownWhenTheMarkerCannotBeWritten() throws {
        let blocker = tempDir("blocker"); defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("x".utf8).write(to: blocker)
        XCTAssertNil(AppInstallDate.read(documentsDirectory: nil, sdkDirectory: blocker.appendingPathComponent("sdk"), now: now))
    }

    /// NEGATIVE CONTROL (base code): each of these docs threw out of the synthesized decode — the whole experiment was
    /// dropped on iOS while Android served it (and allocated everyone on a malformed allocation).
    func testMalformedAllocationAndStartDoNotDropTheExperiment() throws {
        func decode(_ extra: String) throws -> ExperimentConfig {
            let doc = #"{"id":"e","status":"running","salt":"s","platforms":["ios"],"variants":[{"id":"a","weight":1}]"# + extra + "}"
            return try JSONDecoder().decode(ExperimentConfig.self, from: Data(doc.utf8))
        }
        for bad in [#""1""#, "true", #"{"v":1}"#] {
            let cfg = try decode(#","traffic_allocation":"# + bad)
            XCTAssertEqual(cfg.traffic_allocation?.isNaN, true, "traffic_allocation=\(bad) must read as malformed")
            XCTAssertFalse(ExperimentEligibility.isAllocated(experimentId: "e", salt: "s", userId: "u", trafficAllocation: cfg.traffic_allocation))
        }
        XCTAssertNil(try decode(#","traffic_allocation":null"#).traffic_allocation, "null = everyone")
        XCTAssertNil(try decode(#","started_at_ms":"2026-01-01""#).started_at_ms)
        XCTAssertEqual(try decode(#","started_at_ms":1767225600000.9"#).started_at_ms, 1_767_225_600_000)
        XCTAssertEqual(try decode(#","targeting":"US""#).targeting?.malformed, true)
        XCTAssertEqual(try decode(#","salt":5"#).variants?.first?.id, "a", "an odd field is absent, not fatal")
    }

    /// NEGATIVE CONTROL (base code): the rule without a trait name was skipped (pass), and an `NSNumber` Bool compared
    /// as 1 (a numeric rule let it in); a `UInt` trait was not a number.
    func testTraitValueTypesCompareLikeAndroid() throws {
        func rule(_ op: String, _ value: String) throws -> ExperimentTargeting {
            try targeting(#"{"user_traits":[{"trait":"x","operator":""# + op + #"","value":"# + value + "}]}")
        }
        let E = ExperimentEligibility.self
        XCTAssertNil(E.failedRule(targeting: try rule("gte", #""10""#), startedAtMs: nil, context: ctx(traits: ["x": Int64(12)])))
        XCTAssertNil(E.failedRule(targeting: try rule("gte", #""10""#), startedAtMs: nil, context: ctx(traits: ["x": UInt(12)])))
        XCTAssertNil(E.failedRule(targeting: try rule("eq", #""9007199254740993""#), startedAtMs: nil, context: ctx(traits: ["x": Int64(9_007_199_254_740_993)])))
        let bools: [Any] = [true, NSNumber(value: true)]
        for b in bools {
            XCTAssertEqual(E.failedRule(targeting: try rule("gte", #""1""#), startedAtMs: nil, context: ctx(traits: ["x": b])), .userTraits, "a Bool is not a number")
            XCTAssertEqual(E.failedRule(targeting: try rule("eq", "1"), startedAtMs: nil, context: ctx(traits: ["x": b])), .userTraits, "a Bool is not 1")
            XCTAssertNil(E.failedRule(targeting: try rule("eq", #""true""#), startedAtMs: nil, context: ctx(traits: ["x": b])))
            XCTAssertNil(E.failedRule(targeting: try rule("eq", "true"), startedAtMs: nil, context: ctx(traits: ["x": b])))
        }
        XCTAssertNil(E.failedRule(targeting: try rule("eq", "12.0"), startedAtMs: nil, context: ctx(traits: ["x": NSNumber(value: 12)])))
        // A number 1 is still 1, never `true`.
        XCTAssertFalse(ConditionEvaluator.valuesEqual(NSNumber(value: 1), true))
        XCTAssertTrue(ConditionEvaluator.valuesEqual(NSNumber(value: 1), 1))
    }

    func testATraitConditionWithoutAStringTraitOrOperatorFailsClosed() throws {
        XCTAssertEqual(try targeting(#"{"user_traits":[{"trait":5,"operator":"neq","value":"x"}]}"#).malformed, true)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"trait":"plan","operator":7,"value":"pro"}]}"#).malformed, true)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"operator":"neq","value":"x"}]}"#).malformed, true)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"trait":" ","operator":"neq","value":"x"}]}"#).malformed, true)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"field":3,"operator":"eq","value":"x"}]}"#).malformed, true)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"field":"plan","value":"pro"}]}"#).malformed, false)
        XCTAssertEqual(try targeting(#"{"user_traits":[{"trait":"","field":"plan","operator":"eq","value":"pro"}]}"#).malformed, false)
    }
}
