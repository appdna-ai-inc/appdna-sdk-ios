import XCTest
@testable import AppDNASDK

/// `identify` / `reset` made on the same tick as `configure()` are applied, in call order.
///
/// `configure()` returns at once and builds on the SDK queue after a hop through the main queue. A call made right
/// after it used to enqueue its own block on the SDK queue first, find no identity manager and do nothing — no user
/// id stored, no `identify` event, no log line. The usual "restore the signed-in user at launch" code ran the whole
/// session as anonymous. The calls are now held until the build and applied there, in order.
///
/// Each test checks the identity the SDK holds once it is ready. Every request goes to a local server; the identity
/// keychain is an in-memory one, so nothing is left in the simulator's keychain.
final class IdentityOnTheConfigureTickTests: XCTestCase {

    private var savedDropped = 0
    private var server: LoopbackHTTPServer?

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        server = LoopbackHTTPServer { label in
            label.hasPrefix("GET /api/v1/sdk/bootstrap")
                ? BootstrapRecoveryTests.body("org_tick")
                : .init(status: 200, headers: ["Content-Type": "application/json"], body: "{}")
        }
        if let server {
            APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
            APIBaseURL.gateForTesting = { true }
        }
        ConsentFixtureKeychain.shared.wipe()
        ConsentFixtureKeychain.shared.setAnonId("anon-tick")
        AppAccountTokenResolver.clearFirstIdentifiedUserId()
        AppDNA.keychainStoreFactoryForTesting = { ConsentFixtureKeychain.shared }
    }

    override func tearDown() {
        AppDNA.resetInitStateForTesting()
        AppDNA.resetForTesting()
        AppDNA.drainSDKQueueForTesting()
        ShutdownUploadIsolation.restore(savedDropped)
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        AppDNA.keychainStoreFactoryForTesting = nil
        ConsentFixtureKeychain.shared.wipe()
        // identify() records the device's first-identifier anchor; leave none behind for the billing tests.
        AppAccountTokenResolver.clearFirstIdentifiedUserId()
        super.tearDown()
    }

    private func configureAnd(_ calls: () -> Void) {
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        calls() // the same tick: no wait, no hop
        let ready = expectation(description: "ready")
        AppDNA.onReady { ready.fulfill() }
        wait(for: [ready], timeout: 90)
        AppDNA.drainSDKQueueForTesting()
    }

    private var heldUserId: String? { AppDNA.drainSDKQueueForTesting(); return AppDNA.identityManagerRef?.currentIdentity.userId }

    func testIdentifyOnTheConfigureTickIsApplied() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        configureAnd { AppDNA.identify(userId: "tick-user") }
        XCTAssertEqual(heldUserId, "tick-user", "identify() on the configure tick was dropped: the session runs as anonymous")
        XCTAssertEqual(ConsentFixtureKeychain.shared.getUserId(), "tick-user", "the user id was not stored")
    }

    func testResetOnTheConfigureTickIsApplied() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        ConsentFixtureKeychain.shared.setUserId("signed-out-user")
        configureAnd { AppDNA.reset() }
        XCTAssertNil(heldUserId, "reset() on the configure tick was dropped: the signed-out user is still identified")
    }

    /// Order matters: `reset(); identify(b)` ends identified as b, `identify(a); reset()` ends anonymous.
    func testHeldCallsRunInCallOrder() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        ConsentFixtureKeychain.shared.setUserId("signed-out-user")
        configureAnd {
            AppDNA.reset()
            AppDNA.identify(userId: "first")
            AppDNA.identify(userId: "second")
        }
        XCTAssertEqual(heldUserId, "second", "the held calls ran out of order, or were dropped")

        AppDNA.resetForTesting()
        AppDNA.drainSDKQueueForTesting()
        configureAnd {
            AppDNA.identify(userId: "third")
            AppDNA.reset()
        }
        XCTAssertNil(heldUserId, "identify(); reset() on the configure tick must end anonymous")
    }

    /// Before any `configure()` an identify has no identity to apply to, as on Android (whose `configure()` builds
    /// synchronously, so it has no window to hold a call in). It is not held across a later configure.
    func testIdentifyBeforeAnyConfigureIsIgnored() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        AppDNA.identify(userId: "too-early")
        AppDNA.drainSDKQueueForTesting()
        configureAnd {}
        XCTAssertNil(heldUserId)
    }
}
