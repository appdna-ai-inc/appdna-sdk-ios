import XCTest
@testable import AppDNASDK

/// `onPaywallPurchaseFailed` now carries `productId`.
///
/// THE BUG: a paywall selling two products reported "a purchase failed" and the host had no way to
/// tell WHICH — it could not retry the right product, attribute the failure, or price-test. The
/// callback carried `paywallId` + an untyped `Error` (and, since the last pass, an `errorType`), and
/// nothing that named the product.
///
/// The fix follows the `errorType` precedent exactly: a wider overload whose default implementation
/// forwards down the chain, so every existing conformer keeps compiling and keeps receiving calls.
final class PaywallPurchaseFailedProductIdTests: XCTestCase {

    private let testError = NSError(
        domain: "ai.appdna.sdk", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "card declined"]
    )

    // MARK: - The new parameter reaches a modern host

    private final class ModernDelegate: AppDNAPaywallDelegate {
        var received: (paywallId: String, errorType: String, productId: String?)?
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
            received = (paywallId, errorType, productId)
        }
    }

    func testFullVariantDeliversTheProductId() {
        let delegate = ModernDelegate()
        delegate.onPaywallPurchaseFailed(
            paywallId: "pw_1", error: testError, errorType: "serverError", productId: "pro_monthly"
        )
        XCTAssertEqual(delegate.received?.paywallId, "pw_1")
        XCTAssertEqual(delegate.received?.errorType, "serverError")
        XCTAssertEqual(delegate.received?.productId, "pro_monthly")
    }

    // MARK: - Source compatibility (the whole point of the overload chain)

    /// A host written before this change implements only the TWO-argument method. The SDK now calls
    /// the four-argument one; the defaults must walk it all the way down, or every existing app stops
    /// receiving purchase failures.
    private final class LegacyTwoArgDelegate: AppDNAPaywallDelegate {
        var calls: [String] = []
        func onPaywallPurchaseFailed(paywallId: String, error: Error) {
            calls.append(paywallId)
        }
    }

    func testLegacyTwoArgumentConformerStillReceivesTheCall() {
        let delegate: AppDNAPaywallDelegate = LegacyTwoArgDelegate()
        delegate.onPaywallPurchaseFailed(
            paywallId: "pw_1", error: testError, errorType: "userCancelled", productId: "pro_monthly"
        )
        XCTAssertEqual((delegate as? LegacyTwoArgDelegate)?.calls, ["pw_1"])
    }

    /// A host on the intermediate THREE-argument method (added with `errorType`) must also keep
    /// working — the four-argument default forwards to it.
    private final class ThreeArgDelegate: AppDNAPaywallDelegate {
        var errorTypes: [String] = []
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String) {
            errorTypes.append(errorType)
        }
    }

    func testThreeArgumentConformerStillReceivesTheCall() {
        let delegate: AppDNAPaywallDelegate = ThreeArgDelegate()
        delegate.onPaywallPurchaseFailed(
            paywallId: "pw_1", error: testError, errorType: "networkError", productId: "pro_annual"
        )
        XCTAssertEqual((delegate as? ThreeArgDelegate)?.errorTypes, ["networkError"])
    }

    /// An empty conformer (all defaults) must not trap.
    func testEmptyConformerIsSafe() {
        final class EmptyDelegate: AppDNAPaywallDelegate {}
        let delegate: AppDNAPaywallDelegate = EmptyDelegate()
        delegate.onPaywallPurchaseFailed(
            paywallId: "pw_1", error: testError, errorType: "unknown", productId: nil
        )
    }

    // MARK: - The purchase_failed event props

    func testPurchaseFailedEventCarriesProductId() {
        let props = PurchaseFailedProps.build(
            paywallId: "pw_1", productId: "pro_monthly", error: testError, errorType: "serverError"
        )
        XCTAssertEqual(props["paywall_id"] as? String, "pw_1")
        XCTAssertEqual(props["product_id"] as? String, "pro_monthly")
        XCTAssertEqual(props["error_type"] as? String, "serverError")
        XCTAssertEqual(props["error"] as? String, "card declined")
    }

    /// A `nil` productId must serialize as an empty string. `plan.productId` is `String?`, and an
    /// Optional dropped into a `[String: Any]` box stays wrapped — it used to reach BigQuery as the
    /// literal text "nil".
    func testNilProductIdIsEmptyStringNotTheWordNil() {
        let props = PurchaseFailedProps.build(
            paywallId: "pw_1", productId: nil, error: testError, errorType: "unknown"
        )
        XCTAssertEqual(props["product_id"] as? String, "")
        XCTAssertNotEqual(String(describing: props["product_id"]!), "nil")
    }
}
