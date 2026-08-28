import XCTest
@testable import AppDNASDK

/// 🔴 TWO DEFECTS IN THE BILLING FACADE, BOTH INVISIBLE TO EVERY EXISTING TEST AND EVERY GATE.
///
/// **1. `AppDNA.billing.purchase()` emitted NOTHING.**
/// `purchase_completed` / `subscription_started` / `subscription_renewed` are the three events the MTPU
/// billing query counts (`COUNT(DISTINCT user)`). Emission was scattered across BOTH layers — some
/// bridges emitted and expected nothing of their caller; others emitted nothing and expected the caller
/// to do it — so three of six cells were wrong at once:
///
/// |                              | StoreKit2  | Adapty    | RevenueCat |
/// |------------------------------|------------|-----------|------------|
/// | native paywall               | 1 ✅       | **2** ❌   | 1 ✅       |
/// | `AppDNA.billing.purchase()`  | **0** ❌   | 1 ✅      | **0** ❌   |
///
/// The zero row is the one React Native and Flutter live on: a wrapper host — or any native host that
/// draws its own paywall — calls the facade directly, on the DEFAULT provider (StoreKit2), and reported
/// nothing at all. Those subscribers were never counted, in our metering or the customer's dashboard.
///
/// **2. `shutdown()` did not stop billing — it could still charge the user.**
/// Every other module facade holds its manager `weak`, so `shared.<manager> = nil` kills the facade's
/// reference too. `BillingModule.bridge` was the SDK's one **strong** facade reference. So
/// `shutdown()`'s `shared.billingBridge = nil` dropped only the SDK's copy, and the facade kept the
/// bridge ALIVE: `AppDNA.billing.purchase()` sailed past its `guard let bridge` and executed a REAL
/// StoreKit purchase, with `eventTracker` already nil so nobody was ever told. A host calling
/// `shutdown()` on sign-out could still bill the signed-out user, silently.
///
/// `subsystemsUp()` could not see it — it had no `billing` key, and read `shared.*` anyway: the shadow
/// copy, not the variable a host buys through.
///
/// These tests assert the OBSERVABLE BEHAVIOUR through the exact surfaces a host uses — they buy
/// through `AppDNA.billing.purchase()` and read the events off the live pipeline. A test asserting
/// "emit() was called" would pass against an emit that reaches nobody, and a test asserting
/// `billingBridge == nil` would have passed throughout the entire lifetime of defect 2.
final class PurchaseMeteringAndShutdownTests: XCTestCase {

    /// A bridge that bills nothing and records that it was asked to. Injected in place of the real
    /// StoreKit2 bridge so "did the SDK attempt to charge the user?" becomes an observable fact rather
    /// than a real transaction.
    private final class SpyBridge: BillingBridgeProtocol, @unchecked Sendable {
        private(set) var purchaseAttempts = 0
        var isSubscription = true

        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            purchaseAttempts += 1
            return PurchaseResult(
                productId: productId,
                transactionId: "txn_spy_1",
                price: 9.99,
                currency: "USD",
                provider: "storekit2",
                isSubscription: isSubscription
            )
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { [] }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    override func tearDown() {
        AppDNA.resetInitStateForTesting()
        AppDNA.shutdown()
        waitUntil("the SDK is torn down") { AppDNA.subsystemsUp()["events"] == false }
        super.tearDown()
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 30,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Real `configure()`, waited to true readiness via the SDK's own signal. A test host has no API
    /// key, so the bootstrap fails — that is the degraded launch every offline user has, and every
    /// manager is wired either way.
    private func configureAndWait() {
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        let ready = expectation(description: "configure() finished")
        AppDNA.onReady { ready.fulfill() }
        wait(for: [ready], timeout: 30)
    }

    /// Collects the names of events that actually reach the pipeline. A class, not a captured local,
    /// so the sink closure and the test read the same storage without locking across an `await`.
    private final class EventSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return names }
        func count(_ name: String) -> Int { seen.filter { $0 == name }.count }
    }

    /// Names of the events that actually reached the pipeline while `body` ran.
    ///
    /// Reads the LIVE `EventTracker` sink — what the SDK genuinely enqueued — rather than asserting
    /// that some emit helper was invoked. An emit that reaches nobody must fail this.
    ///
    /// 🔴 `body()` returning does NOT mean the events have arrived. Emission hops queues, so
    /// reading the spy the instant the purchase call returns is a race: it wins on a developer
    /// machine and loses on a loaded CI runner, which is exactly how this test failed three times
    /// in CI while passing four for four locally.
    ///
    /// So the caller names what it expects and this waits for it, then lets the pipeline go quiet.
    /// The settle is what keeps the NEGATIVE assertions honest — a test claiming
    /// `subscription_started` was not emitted proves nothing if it looked before the emit could
    /// have happened.
    private func eventsEmitted(
        expecting expected: [String] = [],
        during body: () async throws -> Void
    ) async rethrows -> EventSpy {
        let spy = EventSpy()
        AppDNA.eventTrackerForTesting?.eventSink = { ev in spy.record(ev.event_name) }
        defer { AppDNA.eventTrackerForTesting?.eventSink = nil }
        try await body()
        waitUntil("events \(expected) to reach the pipeline", timeout: 10) {
            expected.allSatisfy { spy.count($0) > 0 }
        }
        // Quiescence: give anything ELSE the same chance to arrive, so an event that should not
        // have been emitted still gets caught rather than merely being late.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        return spy
    }

    // MARK: - Defect 1 — the facade path was analytically silent

    /// The exact call a React Native / Flutter host makes. It must meter.
    func testDirectPurchaseEmitsBothMeteredEventsForASubscription() async throws {
        configureAndWait()
        let spy = SpyBridge()
        spy.isSubscription = true
        AppDNA.billing.bridge = spy

        let emitted = try await eventsEmitted(expecting: ["purchase_completed", "subscription_started"]) {
            _ = try await AppDNA.billing.purchase("com.example.pro.monthly")
        }

        XCTAssertEqual(spy.purchaseAttempts, 1, "the SDK did not actually attempt the purchase")
        XCTAssertEqual(
            emitted.count("purchase_completed"), 1,
            "purchase_completed must be emitted exactly once — every RN/Flutter purchase on StoreKit2 " +
            "used to emit it ZERO times, so the subscriber was never counted for MTPU. Got: \(emitted.seen)"
        )
        XCTAssertEqual(
            emitted.count("subscription_started"), 1,
            "an auto-renewing product must also emit subscription_started exactly once. Got: \(emitted.seen)"
        )
    }

    /// The discriminator must be honest in the other direction too: a one-off purchase is NOT a
    /// subscription, and emitting `subscription_started` for it would over-count the meter.
    func testDirectPurchaseOfAOneOffProductEmitsOnlyPurchaseCompleted() async throws {
        configureAndWait()
        let spy = SpyBridge()
        spy.isSubscription = false
        AppDNA.billing.bridge = spy

        // Only the event that MUST arrive is waited for. `subscription_started` is asserted absent,
        // so waiting for it would hang for the full timeout on every correct run.
        let emitted = try await eventsEmitted(expecting: ["purchase_completed"]) {
            _ = try await AppDNA.billing.purchase("com.example.lifetime")
        }

        XCTAssertEqual(emitted.count("purchase_completed"), 1, "got: \(emitted.seen)")
        XCTAssertEqual(
            emitted.count("subscription_started"), 0,
            "a non-renewing product must NOT emit subscription_started — that would meter a " +
            "subscription that does not exist. Got: \(emitted.seen)"
        )
    }

    // MARK: - Defect 2 — shutdown() left billing able to charge the user

    /// THE ONE THAT SPENDS MONEY. After `shutdown()`, a purchase must be REFUSED — not executed and
    /// silently unreported.
    func testPurchaseAfterShutdownIsRefusedAndNeverReachesTheStore() async throws {
        configureAndWait()
        let spy = SpyBridge()
        AppDNA.billing.bridge = spy

        AppDNA.shutdown()
        // Wait on the ACTUAL postcondition — billing released — not on a proxy signal. Waiting on
        // `events == false` is what exposed the ordering bug: shutdown() nils the event pipeline FIRST,
        // so that flag flips while billing is still live, leaving a window in which a purchase is
        // charged and reported to nobody. Billing is now torn down first, so this settles earlier.
        waitUntil("billing to be released") { AppDNA.billing.bridge == nil }

        do {
            _ = try await AppDNA.billing.purchase("com.example.pro.monthly")
            XCTFail(
                "AppDNA.billing.purchase() SUCCEEDED after shutdown() — the facade still held the " +
                "bridge, so a host that shut the SDK down on sign-out could still charge the " +
                "signed-out user, and with eventTracker already nil nobody would ever be told."
            )
        } catch BillingModuleError.noBillingProvider {
            // Correct: billing is down, and says so.
        }

        XCTAssertEqual(
            spy.purchaseAttempts, 0,
            "the SDK reached the billing bridge after shutdown() — this is a REAL StoreKit purchase " +
            "in production. It must not get that far."
        )
    }

    /// The diagnostic must read the same object the host buys through. It used to read `shared.*` — the
    /// shadow copy — and had no `billing` key at all, which is precisely why nothing observed the leak.
    func testSubsystemsUpReportsBillingAndTracksTheFacadeNotTheShadowCopy() {
        configureAndWait()
        XCTAssertEqual(
            AppDNA.subsystemsUp()["billing"], true,
            "billing must be reported UP after configure()"
        )

        AppDNA.shutdown()
        waitUntil("shutdown to land") { AppDNA.subsystemsUp()["events"] == false }

        XCTAssertEqual(
            AppDNA.subsystemsUp()["billing"], false,
            "billing must be reported DOWN after shutdown() — and it must be down because the FACADE " +
            "was released, not merely because a shadow copy was nilled while the facade kept billing."
        )
        XCTAssertNil(
            AppDNA.billing.bridge,
            "the facade still holds a live billing bridge after shutdown()"
        )
    }
}
