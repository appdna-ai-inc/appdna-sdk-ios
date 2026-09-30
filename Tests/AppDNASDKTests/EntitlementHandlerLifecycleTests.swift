import XCTest
@testable import AppDNASDK

/// The handler registries on the process-global `AppDNA` singleton are APPEND-only. Everything that
/// re-registers — every cross-platform wrapper, and any host that calls `configure()` twice — depends
/// on there being a way to get back to one handler. These tests pin that contract.
///
/// The bug they were written for: `AppDNA.shutdown()` cleared `webEntitlementChangeHandlers` and left
/// the BILLING entitlement handlers attached. The React Native wrapper re-registers on `configure()`
/// (its JS side re-arms the "observer started" latch on `shutdown()` precisely so it will), so
/// `configure → shutdown → configure` ended with TWO live handlers and emitted `onEntitlementsChanged`
/// twice for every subsequent change — after N cycles, N duplicate entitlement grants per purchase.
/// Android never had it: its `shutdown()` nulls the billing manager, taking the listeners with it.
final class EntitlementHandlerLifecycleTests: XCTestCase {

    override func tearDown() {
        // These handlers live on a process-global singleton; a leaked one would be delivered to the
        // next test in the suite.
        AppDNA.shutdown()
        settle()
        super.tearDown()
    }

    /// `AppDNA`'s serial work queue is `private`, so a test cannot barrier on it. The handler blocks
    /// themselves are dispatched on `OperationQueue.main`, so spinning the main run loop both drains
    /// them and gives `shutdown()`'s async body time to land.
    private func settle(_ seconds: TimeInterval = 0.4) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2.0)
    }

    private func postEntitlementsChanged() {
        let entitlement = ServerEntitlement(
            productId: "pro_monthly",
            store: "app_store",
            status: "active",
            expiresAt: nil,
            isTrial: false,
            offerType: nil
        )
        NotificationCenter.default.post(
            name: .entitlementsChanged,
            object: nil,
            userInfo: ["entitlements": [entitlement]]
        )
    }

    // MARK: - Store entitlements

    /// FIX 1 — `shutdown()` must drop the entitlement handlers, which is plainly what it already
    /// intends (it does exactly this for the web-entitlement handlers two lines up).
    func testShutdownRemovesEntitlementsChangedHandlers() {
        var calls = 0
        AppDNA.billing.onEntitlementsChanged { _ in calls += 1 }

        AppDNA.shutdown()
        settle()

        postEntitlementsChanged()
        settle()

        XCTAssertEqual(calls, 0, "a handler from before shutdown() must not still be live")
    }

    /// FIX 1, as the RN wrapper actually hits it. THE bug: two `configure()`s either side of a
    /// `shutdown()` used to leave two live handlers and deliver every change twice.
    func testConfigureShutdownConfigureDeliversEntitlementChangeExactlyOnce() {
        var deliveries = 0

        // configure() #1 → the wrapper's startEntitlementObserver registers.
        AppDNA.billing.onEntitlementsChanged { _ in deliveries += 1 }

        AppDNA.shutdown()
        settle()

        // configure() #2 → the JS latch was reset on shutdown, so the wrapper registers again.
        AppDNA.billing.onEntitlementsChanged { _ in deliveries += 1 }

        postEntitlementsChanged()
        settle()

        XCTAssertEqual(deliveries, 1, "one entitlement change must not be delivered twice (was 2)")
    }

    /// The removal API the wrapper's `invalidate()` — and now its idempotent
    /// `startEntitlementObserver` — depend on.
    func testRemoveEntitlementsChangedHandlerDropsOnlyThatHandler() {
        var first = 0
        var second = 0
        let firstToken = AppDNA.billing.onEntitlementsChanged { _ in first += 1 }
        AppDNA.billing.onEntitlementsChanged { _ in second += 1 }

        AppDNA.billing.removeEntitlementsChangedHandler(firstToken)

        postEntitlementsChanged()
        settle()

        XCTAssertEqual(first, 0, "the removed handler must be gone")
        XCTAssertEqual(second, 1, "the surviving handler must still fire, exactly once")
    }

    // MARK: - Web entitlements

    /// FIX 3 (SDK half) — `onWebEntitlementChanged` had NO removal API at all, so the RN wrapper,
    /// which called it unconditionally on every `configure()`, could only ever add. This is the token
    /// that lets it register once and detach on `invalidate()`.
    func testRemoveWebEntitlementChangedHandlerDropsOnlyThatHandler() {
        var first = 0
        var second = 0
        let firstToken = AppDNA.onWebEntitlementChanged { _ in first += 1 }
        AppDNA.onWebEntitlementChanged { _ in second += 1 }

        AppDNA.removeWebEntitlementChangedHandler(firstToken)

        NotificationCenter.default.post(name: .webEntitlementChanged, object: nil)
        settle()

        XCTAssertEqual(first, 0, "the removed web handler must be gone")
        XCTAssertEqual(second, 1, "the surviving web handler must still fire, exactly once")
    }

    /// Fix wave (shutdown → configure latch). `shutdown()` cleared the web-entitlement handlers in its
    /// ASYNC teardown, so a handler registered right after `shutdown()` returned — what the React Native
    /// and Flutter bridges do on the `configure()` that follows on the same tick — was removed when the
    /// teardown landed, and `onWebEntitlementChanged` never fired again.
    func testWebHandlerRegisteredRightAfterShutdownSurvivesTheTeardown() {
        var before = 0
        var after = 0
        AppDNA.onWebEntitlementChanged { _ in before += 1 }

        AppDNA.shutdown()
        AppDNA.onWebEntitlementChanged { _ in after += 1 }   // same tick, before the teardown runs
        settle()

        NotificationCenter.default.post(name: .webEntitlementChanged, object: nil)
        settle()

        XCTAssertEqual(before, 0, "the pre-shutdown handler must be gone")
        XCTAssertEqual(after, 1, "a handler registered after shutdown() returned must survive the async teardown")
    }
}
