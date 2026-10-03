import XCTest
@testable import AppDNASDK

/// An in-memory `KeychainStoring`. Same contract, no environment.
///
/// 🔴 It replaces a real `KeychainStore(service:)` whose two persistence tests were guarded by
///
///     try XCTSkipIf(keychainStore.getString(key: "anon_id") == nil, "Keychain not available")
///
/// THE SKIP CONDITION WAS THE BUG IT WAS TESTING FOR. `getString` returns nil in exactly two cases:
/// the runner has no keychain entitlements (the normal SwiftPM-simulator CI path), or **the SDK
/// failed to persist `anon_id`** — the defect. The test could not tell them apart, so on the failure
/// it was written to catch it printed a skip and the suite went green. Both persistence tests were
/// dormant on every CI run we have ever done.
///
/// An injected store has no entitlements to lack. Nothing can be "unavailable", so nothing is
/// skipped, and `testAnonIdPersistedToKeychain` now fails when persistence is broken — which is all
/// it was ever supposed to do.
private final class InMemoryKeychainStore: KeychainStoring {
    private var anonId: String?
    private var userId: String?
    private var traits: [String: Any]?

    /// Reads/writes seen — so a test can assert the manager actually WROTE, not merely cached in RAM.
    private(set) var setAnonIdCallCount = 0

    func getAnonId() -> String? { anonId }
    func setAnonId(_ id: String) {
        anonId = id
        setAnonIdCallCount += 1
    }

    func getUserId() -> String? { userId }
    func setUserId(_ id: String) { userId = id }
    func clearUserId() { userId = nil }

    func getUserTraits() -> [String: Any]? { traits }
    func setUserTraits(_ traits: [String: Any]) { self.traits = traits }
    func clearUserTraits() { traits = nil }
}

final class IdentityManagerTests: XCTestCase {

    private var keychainStore: InMemoryKeychainStore!
    private var manager: IdentityManager!

    override func setUp() {
        super.setUp()
        // Deterministic on every runner, entitlements or not. A second IdentityManager built over the
        // SAME store is exactly what "relaunch the app" means to this class — that is what the
        // persistence tests below exercise, and they can no longer opt out of doing so.
        keychainStore = InMemoryKeychainStore()
        manager = IdentityManager(keychainStore: keychainStore)
    }

    // MARK: - Anonymous ID

    func testAnonIdGeneratedOnFirstLaunch() {
        let identity = manager.currentIdentity
        XCTAssertFalse(identity.anonId.isEmpty)
    }

    func testAnonIdIsValidUUID() {
        let identity = manager.currentIdentity
        XCTAssertNotNil(UUID(uuidString: identity.anonId))
    }

    func testAnonIdPersistedToKeychain() {
        let anonId = manager.currentIdentity.anonId

        // It was WRITTEN — not merely held in the manager's memory.
        XCTAssertEqual(keychainStore.getAnonId(), anonId)

        // And it SURVIVES: a second manager over the same store (i.e. the next app launch) loads the
        // same id rather than minting a new one. A new id here means every returning user looks like
        // a new install — the exact failure the old XCTSkipIf swallowed.
        let manager2 = IdentityManager(keychainStore: keychainStore)
        XCTAssertEqual(manager2.currentIdentity.anonId, anonId)

        // And it does not re-write on load: one mint, ever.
        XCTAssertEqual(keychainStore.setAnonIdCallCount, 1)
    }

    func testAnonIdStableAcrossMultipleAccesses() {
        let id1 = manager.currentIdentity.anonId
        let id2 = manager.currentIdentity.anonId
        let id3 = manager.currentIdentity.anonId
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id2, id3)
    }

    // MARK: - Identify

    func testIdentifySetsUserId() {
        manager.identify(userId: "user_123")
        XCTAssertEqual(manager.currentIdentity.userId, "user_123")
    }

    func testIdentifySetsTraits() {
        manager.identify(userId: "user_123", traits: ["plan": "pro", "age": 25])
        let traits = manager.currentIdentity.traits
        XCTAssertEqual(traits?["plan"] as? String, "pro")
        XCTAssertEqual(traits?["age"] as? Int, 25)
    }

    func testIdentifyPersistsToKeychain() {
        manager.identify(userId: "user_456", traits: ["name": "Test"])

        XCTAssertEqual(keychainStore.getUserId(), "user_456")

        // Survives the relaunch — both the id and the traits.
        let manager2 = IdentityManager(keychainStore: keychainStore)
        XCTAssertEqual(manager2.currentIdentity.userId, "user_456")
        XCTAssertEqual(manager2.currentIdentity.traits?["name"] as? String, "Test")
    }

    func testIdentifyOverwritesPrevious() {
        manager.identify(userId: "user_1")
        manager.identify(userId: "user_2")
        XCTAssertEqual(manager.currentIdentity.userId, "user_2")
    }

    // MARK: - Bootstrap location traits

    /// The bootstrap's location traits (`mergeTraits`) survive `identify(userId, traits)`, an account switch and
    /// `reset()`; a host key with the same name wins. NEGATIVE CONTROL (build Mac, base code): `identify` with traits
    /// replaced the whole set — `country` was nil after the login until the next bootstrap.
    func testBootstrapLocationTraitsSurviveIdentifyWithTraitsSwitchAndReset() {
        manager.mergeTraits(["country": "DE", "city": "Berlin"])
        manager.identify(userId: "user_1", traits: ["plan": "pro", "city": "Hamburg"])
        var traits = manager.currentIdentity.traits
        XCTAssertEqual(traits?["country"] as? String, "DE", "identify with traits dropped the location traits")
        XCTAssertEqual(traits?["city"] as? String, "Hamburg", "a host trait wins over a location trait")
        XCTAssertEqual(traits?["plan"] as? String, "pro")

        manager.identify(userId: "user_2")   // an account switch: the host's traits go, the location stays
        traits = manager.currentIdentity.traits
        XCTAssertNil(traits?["plan"])
        XCTAssertEqual(traits?["country"] as? String, "DE")
        XCTAssertEqual(traits?["city"] as? String, "Berlin")

        manager.reset()
        XCTAssertEqual(manager.currentIdentity.traits?["country"] as? String, "DE")
        XCTAssertNil(manager.currentIdentity.userId)
    }

    // MARK: - Reset

    func testResetClearsUserId() {
        manager.identify(userId: "user_123")
        manager.reset()
        XCTAssertNil(manager.currentIdentity.userId)
    }

    func testResetClearsTraits() {
        manager.identify(userId: "user_123", traits: ["plan": "pro"])
        manager.reset()
        XCTAssertNil(manager.currentIdentity.traits)
    }

    func testResetKeepsAnonId() {
        let anonId = manager.currentIdentity.anonId
        manager.identify(userId: "user_123")
        manager.reset()
        XCTAssertEqual(manager.currentIdentity.anonId, anonId)
    }

    func testResetPersistsToKeychain() {
        manager.identify(userId: "user_123")
        manager.reset()
        let manager2 = IdentityManager(keychainStore: keychainStore)
        XCTAssertNil(manager2.currentIdentity.userId)
        XCTAssertFalse(manager2.currentIdentity.anonId.isEmpty)
    }

    // MARK: - Thread safety

    func testConcurrentIdentifyCalls() {
        let expectation = self.expectation(description: "concurrent")
        expectation.expectedFulfillmentCount = 100

        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<100 {
            queue.async {
                self.manager.identify(userId: "user_\(i)")
                _ = self.manager.currentIdentity
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 30)
        // Should not crash — that's the test
        let identity = manager.currentIdentity
        XCTAssertFalse(identity.anonId.isEmpty)
    }

    func testConcurrentResetCalls() {
        let expectation = self.expectation(description: "concurrent reset")
        expectation.expectedFulfillmentCount = 50

        let queue = DispatchQueue(label: "test.concurrent.reset", attributes: .concurrent)

        for i in 0..<50 {
            queue.async {
                if i % 2 == 0 {
                    self.manager.identify(userId: "user_\(i)")
                } else {
                    self.manager.reset()
                }
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 30)
        // Should not crash
        XCTAssertFalse(manager.currentIdentity.anonId.isEmpty)
    }
}
