import XCTest
@testable import AppDNASDK

/// Verify `OnboardingPaywallBridge` forwards every
/// `AppDNAPaywallDelegate` callback to the host's registered global
/// delegate at `AppDNA.paywall.delegate` AND preserves the existing
/// onboarding routing side-effects.
///
/// `OnboardingPaywallBridge` is `private` to `OnboardingRenderer.swift`,
/// so we can't construct it directly from a test target. Instead we
/// assert the **contract** by validating:
///
/// 1. The protocol shape (12 methods) — guards against silent removal
///    of any method during refactoring.
/// 2. The fresh-read design — `AppDNA.paywall.delegate` reads its
///    current value on every callback, not a captured-at-init copy.
/// 3. The setDelegate / clear / re-register lifecycle, exercised
///    through the public `AppDNA.paywall.setDelegate(...)` API.
///
/// The end-to-end forwarding (bridge → host delegate during a real
/// paywall launched from onboarding) is exercised on the Mac build
/// bridge with a sample iOS app.
final class OnboardingPaywallBridgeForwardingTests: XCTestCase {

    override func tearDown() {
        // Clear any test delegate so other tests aren't affected.
        AppDNA.paywall.setDelegate(nil)
        super.tearDown()
    }

    // MARK: - Protocol shape

    /// All 12 methods on `AppDNAPaywallDelegate` are reachable through
    /// a default-implementing legacy delegate. If any method is removed
    /// or renamed, this test fails to compile.
    func testAllTwelveProtocolMethodsExist() {
        final class LegacyDelegate: AppDNAPaywallDelegate {}
        let delegate = LegacyDelegate()
        let txInfo = TransactionInfo(transactionId: "t1", productId: "p1", purchaseDate: Date())
        let testError = NSError(domain: "test", code: 1)

        // 12 methods, in protocol declaration order.
        delegate.onPaywallPresented(paywallId: "p1")
        delegate.onPaywallAction(paywallId: "p1", action: .ctaTapped)
        delegate.onPaywallPurchaseStarted(paywallId: "p1", productId: "prod_a")
        delegate.onPaywallPurchaseCompleted(paywallId: "p1", productId: "prod_a", transaction: txInfo)
        delegate.onPaywallPurchaseFailed(paywallId: "p1", error: testError)
        delegate.onPaywallDismissed(paywallId: "p1")
        let exp = expectation(description: "promo completion")
        delegate.onPromoCodeSubmit(paywallId: "p1", code: "SUMMER", completion: { valid in
            // Default behavior returns false.
            XCTAssertFalse(valid)
            exp.fulfill()
        })
        wait(for: [exp], timeout: 1.0)
        delegate.onPostPurchaseDeepLink(paywallId: "p1", url: "https://example.com")
        delegate.onPostPurchaseNextStep(paywallId: "p1")
        delegate.onPaywallRestoreStarted(paywallId: "p1")
        delegate.onPaywallRestoreCompleted(paywallId: "p1", productIds: [])
        delegate.onPaywallRestoreFailed(paywallId: "p1", error: testError)
    }

    // MARK: - Fresh-read design

    /// `AppDNA.paywall.delegate` returns whatever was most recently
    /// registered. Late registration (after a hypothetical bridge has
    /// been constructed) MUST be visible — the bridge re-reads on
    /// every callback rather than capturing at init.
    func testLateRegistrationIsVisible() {
        // Before registration: nil.
        XCTAssertNil(AppDNA.paywall.delegate)

        // After register: visible.
        let recorder = RecordingDelegate()
        AppDNA.paywall.setDelegate(recorder)
        XCTAssertTrue(AppDNA.paywall.delegate === recorder)

        // Re-register a different one: fresh read returns the new one.
        let recorder2 = RecordingDelegate()
        AppDNA.paywall.setDelegate(recorder2)
        XCTAssertTrue(AppDNA.paywall.delegate === recorder2)

        // Clear: nil again.
        AppDNA.paywall.setDelegate(nil)
        XCTAssertNil(AppDNA.paywall.delegate)
    }

    // MARK: - Forwarding behavior (via AppDNA.paywall.delegate read)

    /// When a host registers a delegate, the SDK paths that call
    /// `AppDNA.paywall.delegate?.onX(...)` (which the onboarding bridge
    /// uses inside `forwardOnMain`) reach the host.
    func testForwardReachesRegisteredDelegate() {
        let recorder = RecordingDelegate()
        AppDNA.paywall.setDelegate(recorder)

        let txInfo = TransactionInfo(transactionId: "t1", productId: "p1", purchaseDate: Date())
        AppDNA.paywall.delegate?.onPaywallPurchaseCompleted(paywallId: "p1", productId: "prod_a", transaction: txInfo)
        XCTAssertEqual(recorder.purchaseCompletedCount, 1)
        XCTAssertEqual(recorder.lastPurchaseProductId, "prod_a")

        AppDNA.paywall.delegate?.onPaywallDismissed(paywallId: "p1")
        XCTAssertEqual(recorder.dismissedCount, 1)
    }

    /// Releasing the delegate mid-flow turns subsequent forwards into
    /// silent no-ops. Routing side-effects in the bridge fire
    /// regardless of host availability — verified at the bridge level
    /// in the Mac build smoke test.
    func testMidFlowReleaseIsSafe() {
        let recorder = RecordingDelegate()
        AppDNA.paywall.setDelegate(recorder)
        AppDNA.paywall.delegate?.onPaywallPurchaseStarted(paywallId: "p1", productId: "x")
        XCTAssertEqual(recorder.purchaseStartedCount, 1)

        AppDNA.paywall.setDelegate(nil)
        // Subsequent forwards no-op.
        AppDNA.paywall.delegate?.onPaywallPurchaseCompleted(
            paywallId: "p1",
            productId: "x",
            transaction: TransactionInfo(transactionId: "t", productId: "x", purchaseDate: Date())
        )
        XCTAssertEqual(recorder.purchaseCompletedCount, 0, "Forward must not fire after delegate cleared")
    }
}

// MARK: - Test helpers

/// A delegate that records every `AppDNAPaywallDelegate` callback for
/// later assertion. Used across the bridge-forwarding test suite.
private final class RecordingDelegate: AppDNAPaywallDelegate {
    var presentedCount = 0
    var actionCount = 0
    var purchaseStartedCount = 0
    var purchaseCompletedCount = 0
    var purchaseFailedCount = 0
    var dismissedCount = 0
    var promoSubmitCount = 0
    var postPurchaseDeepLinkCount = 0
    var postPurchaseNextStepCount = 0
    var restoreStartedCount = 0
    var restoreCompletedCount = 0
    var restoreFailedCount = 0
    var lastPurchaseProductId: String?

    func onPaywallPresented(paywallId: String) { presentedCount += 1 }
    func onPaywallAction(paywallId: String, action: PaywallAction) { actionCount += 1 }
    func onPaywallPurchaseStarted(paywallId: String, productId: String) { purchaseStartedCount += 1 }
    func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
        purchaseCompletedCount += 1
        lastPurchaseProductId = productId
    }
    func onPaywallPurchaseFailed(paywallId: String, error: Error) { purchaseFailedCount += 1 }
    func onPaywallDismissed(paywallId: String) { dismissedCount += 1 }
    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void) {
        promoSubmitCount += 1
        completion(false)
    }
    func onPostPurchaseDeepLink(paywallId: String, url: String) { postPurchaseDeepLinkCount += 1 }
    func onPostPurchaseNextStep(paywallId: String) { postPurchaseNextStepCount += 1 }
    func onPaywallRestoreStarted(paywallId: String) { restoreStartedCount += 1 }
    func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) { restoreCompletedCount += 1 }
    func onPaywallRestoreFailed(paywallId: String, error: Error) { restoreFailedCount += 1 }
}
