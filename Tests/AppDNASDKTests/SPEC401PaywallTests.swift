import XCTest
@testable import AppDNASDK

/// Public API surface tests for the entitlement-aware paywall
/// trigger + restore routing fixes.
///
/// The internal pieces (OnboardingPaywallBridge, PaywallDismissGuard) are
/// `private` to OnboardingRenderer.swift / PaywallManager.swift, so we can
/// only assert the PUBLIC contract here:
///
///   1. `AppDNA.paywall.skipNextAutoDismissOnRestore` exists, is a `Bool`,
///      defaults to false, and round-trips through get/set on the main
///      thread.
///   2. `AppDNA.billing.refreshEntitlementCache()` exists and is callable
///      without throwing or blocking the caller.
///   3. `AppDNA.billing.hasActiveSubscription()` exists (Fix 1A relies on
///      it being callable from the entitlement gate).
///
/// End-to-end behaviour (entitlement-skip routing, auto-dismiss-on-restore,
/// bridge `didPurchase` flag, identify→refresh chain) is covered by the
/// shared behavioural fixtures at `packages/sdk-shared-fixtures/billing/`
/// and the Mac build bridge sample app (per AC.5B + AC.13).
final class SPEC401PaywallTests: XCTestCase {

    override func tearDown() {
        // Reset the one-shot flag so other tests aren't affected.
        AppDNA.paywall.skipNextAutoDismissOnRestore = false
        super.tearDown()
    }

    // MARK: - Fix 1C public API

    /// `AppDNA.paywall.skipNextAutoDismissOnRestore` exists as a public
    /// mutable Bool. The flag is the host's only
    /// supported way to opt out of SDK auto-dismiss on restore success.
    /// Compile-time verification that the property exists with the
    /// declared shape; runtime verification that it round-trips.
    func testSkipNextAutoDismissOnRestoreExistsAndDefaultsFalse() {
        XCTAssertFalse(AppDNA.paywall.skipNextAutoDismissOnRestore)
    }

    func testSkipNextAutoDismissOnRestoreRoundTrip() {
        AppDNA.paywall.skipNextAutoDismissOnRestore = true
        XCTAssertTrue(AppDNA.paywall.skipNextAutoDismissOnRestore)

        AppDNA.paywall.skipNextAutoDismissOnRestore = false
        XCTAssertFalse(AppDNA.paywall.skipNextAutoDismissOnRestore)
    }

    /// Per spec line 109 the flag is "one-shot": PaywallManager.handleRestore
    /// reads + clears it on every restore terminal event. We can't trigger
    /// a real restore from a unit test (requires StoreKit), but we CAN
    /// assert that the host can re-set the flag after the SDK reads it —
    /// i.e. it's not write-once. This pins the property as a normal var.
    func testSkipNextAutoDismissOnRestoreCanBeReSetAfterClear() {
        AppDNA.paywall.skipNextAutoDismissOnRestore = true
        // Simulate the SDK clearing it after a restore.
        AppDNA.paywall.skipNextAutoDismissOnRestore = false
        XCTAssertFalse(AppDNA.paywall.skipNextAutoDismissOnRestore)

        // Host can re-set for the next paywall presentation.
        AppDNA.paywall.skipNextAutoDismissOnRestore = true
        XCTAssertTrue(AppDNA.paywall.skipNextAutoDismissOnRestore)
    }

    // MARK: - Fix 1D public API

    /// `AppDNA.billing.refreshEntitlementCache()` exists as a public
    /// async no-throw method. Per spec line 117-186, callers must be
    /// able to chain without try/catch and identify uses it
    /// fire-and-forget. This test asserts the method is callable in
    /// that contract — silent failure when no billing bridge is wired.
    func testRefreshEntitlementCacheIsCallableWithoutThrow() async {
        // No billing bridge configured in unit tests → method logs
        // a warning and returns silently. The point is that this
        // compiles and doesn't blow up.
        await AppDNA.billing.refreshEntitlementCache()
        // If we got here without an exception, the contract holds.
        XCTAssertTrue(true)
    }

    /// `AppDNA.billing.hasActiveSubscription()` is the gate Fix 1A reads
    /// from. Confirm it exists as a public async Bool method.
    func testHasActiveSubscriptionIsCallable() async {
        let result = await AppDNA.billing.hasActiveSubscription()
        // No bridge configured → returns false. We just assert the
        // method exists, returns a Bool, and is callable.
        XCTAssertFalse(result)
    }
}
