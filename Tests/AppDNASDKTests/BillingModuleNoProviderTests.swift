// BillingModuleNoProviderTests.swift
//
// SPEC-497 §3.2 rule 3 / rule 5, §3.4, §3.10 — the direct `AppDNA.billing.purchase` / `restorePurchases`
// on every path the SDK cannot buy through:
//   - before `configure` wired billing (and after `shutdown()`): an `unknown` error with the message
//     "AppDNA SDK not configured yet — call configure() first" (no new error type, R65–R67);
//   - configured with `none`: `BillingError.providerNotAvailable` (was `BillingModuleError.noBillingProvider`)
//     and exactly one `purchase_failed` (no `paywall_id`, no `purchase_started`);
//   - a non-owning bridge (RevenueCat / Adapty not linked): the bridge throws `providerNotAvailable`
//     itself; one `purchase_failed`, no `purchase_started`.

import XCTest
@testable import AppDNASDK

final class BillingModuleNoProviderTests: XCTestCase {

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!

    override func setUp() {
        super.setUp()
        events = []
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        tracker = EventTracker(identityManager: identity)
        tracker.eventSink = { [weak self] event in self?.events.append(event) }
    }

    func testPurchaseBeforeConfigureIsUnknownNotConfiguredYet() async {
        let module = AppDNA.BillingModule()
        do {
            _ = try await module.purchase("p1")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "unknown")
            XCTAssertEqual(error.localizedDescription, "AppDNA SDK not configured yet — call configure() first")
        }
        do {
            _ = try await module.restorePurchases()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "unknown")
        }
        XCTAssertTrue(events.isEmpty, "no tracker before configure → nothing emitted")
    }

    func testConfiguredWithNoneThrowsProviderNotAvailableAndEmitsOnePurchaseFailed() async {
        let module = AppDNA.BillingModule()
        module.wire(bridge: nil, policy: BillingOwnership.policy(for: .none, bridgeLinked: false), tracker: tracker)
        do {
            _ = try await module.purchase("p1")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
            XCTAssertEqual(error.localizedDescription, "No billing provider configured")
            XCTAssertFalse(error is BillingModuleError, "no longer the deprecated noBillingProvider")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_failed"])
        let props = events.first?.properties
        XCTAssertEqual(props?["error_type"]?.value as? String, "providerNotAvailable")
        XCTAssertEqual(props?["product_id"]?.value as? String, "p1")
        XCTAssertNil(props?["paywall_id"], "a direct purchase has no paywall")
        XCTAssertEqual(props?["emitted_by"]?.value as? String, "sdk")

        do {
            _ = try await module.restorePurchases()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
    }

    func testNonOwningBridgeRefusesWithoutPurchaseStarted() async {
        let module = AppDNA.BillingModule()
        module.wire(
            bridge: ExternalProviderBridge(provider: .revenueCat),
            policy: BillingOwnership.policy(for: .revenueCat, bridgeLinked: false),
            tracker: tracker
        )
        do {
            _ = try await module.purchase("p1")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_failed"])
        do {
            _ = try await module.restorePurchases()
            XCTFail("restore must throw under a provider that owns restoring")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
    }

    func testTeardownRestoresTheNotConfiguredError() async {
        let module = AppDNA.BillingModule()
        module.wire(bridge: nil, policy: BillingOwnership.policy(for: .none, bridgeLinked: false), tracker: tracker)
        module.teardown()
        do {
            _ = try await module.purchase("p1")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "unknown")
            XCTAssertEqual(error.localizedDescription, AppDNA.BillingModule.notConfiguredMessage)
        }
    }

    /// R40 parity — a direct purchase that the bridge fails emits `purchase_started` then ONE terminal
    /// event, like Android.
    func testDirectPurchaseFailureEmitsStartedThenFailed() async {
        final class FailingBridge: BillingBridgeProtocol {
            func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
                throw BillingError.productNotFound(productId)
            }
            func restore(appAccountToken: UUID?) async throws -> [String] { [] }
            func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
        }
        let module = AppDNA.BillingModule()
        module.wire(bridge: FailingBridge(), policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        _ = try? await module.purchase("missing")
        XCTAssertEqual(events.map(\.event_name), ["purchase_started", "purchase_failed"])
        XCTAssertEqual(events.last?.properties?["error_type"]?.value as? String, "productNotFound")
    }

    // MARK: - SPEC-497 §13b.2 R37/R38/R39 — a failed DIRECT restore tracks exactly one purchase_restore_failed

    private func restoreFailedEvents() -> [SDKEvent] {
        events.filter { $0.event_name == "purchase_restore_failed" }
    }

    func testDirectRestoreWithNoneTracksExactlyOneRestoreFailed() async {
        let module = AppDNA.BillingModule()
        module.wire(bridge: nil, policy: BillingOwnership.policy(for: .none, bridgeLinked: false), tracker: tracker)
        do {
            _ = try await module.restorePurchases()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_restore_failed"])
        let props = restoreFailedEvents().first?.properties
        XCTAssertEqual(props?["error_type"]?.value as? String, "providerNotAvailable")
        XCTAssertEqual(props?["error"]?.value as? String, "No billing provider configured")
        XCTAssertNil(props?["paywall_id"], "a direct restore has no paywall")
        XCTAssertEqual(props?["emitted_by"]?.value as? String, "sdk")
    }

    func testDirectRestoreWithUnlinkedProviderTracksExactlyOneRestoreFailed() async {
        let module = AppDNA.BillingModule()
        module.wire(
            bridge: ExternalProviderBridge(provider: .revenueCat),
            policy: BillingOwnership.policy(for: .revenueCat, bridgeLinked: false),
            tracker: tracker
        )
        do {
            _ = try await module.restorePurchases()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_restore_failed"])
        XCTAssertEqual(restoreFailedEvents().first?.properties?["error_type"]?.value as? String, "providerNotAvailable")
    }

    func testDirectRestoreBridgeFailureTracksExactlyOneRestoreFailed() async {
        final class FailingRestoreBridge: BillingBridgeProtocol {
            func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
                throw BillingError.productNotFound(productId)
            }
            func restore(appAccountToken: UUID?) async throws -> [String] { throw URLError(.notConnectedToInternet) }
            func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
        }
        let module = AppDNA.BillingModule()
        module.wire(bridge: FailingRestoreBridge(), policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        do {
            _ = try await module.restorePurchases()
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is URLError, "rethrows the bridge's error unchanged")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_restore_failed"])
        XCTAssertEqual(restoreFailedEvents().first?.properties?["error_type"]?.value as? String,
                       billingErrorType(URLError(.notConnectedToInternet)))
    }

    func testSuccessfulDirectRestoreTracksNoRestoreFailed() async throws {
        final class OkBridge: BillingBridgeProtocol {
            func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
                throw BillingError.productNotFound(productId)
            }
            func restore(appAccountToken: UUID?) async throws -> [String] { ["p1"] }
            func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
        }
        let module = AppDNA.BillingModule()
        module.wire(bridge: OkBridge(), policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        let restored = try await module.restorePurchases()
        XCTAssertEqual(restored, ["p1"])
        XCTAssertTrue(restoreFailedEvents().isEmpty)
    }

    /// R40/R41 — a re-buy of an owned item: one `purchase_restored{reason: item_already_owned}`, no price,
    /// no conversion; `purchase()` still returns the TransactionInfo.
    func testRebuyOfAnOwnedItemBooksNoRevenue() async throws {
        final class OwnedBridge: BillingBridgeProtocol {
            func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
                PurchaseResult(productId: productId, transactionId: "42", price: 4.99, currency: "USD",
                               provider: "storekit2", isSubscription: false, isConsumable: false,
                               isTrial: false, alreadyOwned: true)
            }
            func restore(appAccountToken: UUID?) async throws -> [String] { [] }
            func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
        }
        let module = AppDNA.BillingModule()
        module.wire(bridge: OwnedBridge(), policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        let info = try await module.purchase("lifetime")
        XCTAssertEqual(info.transactionId, "42")
        XCTAssertEqual(events.map(\.event_name), ["purchase_started", "purchase_restored"])
        let props = events.last?.properties
        XCTAssertEqual(props?["reason"]?.value as? String, "item_already_owned")
        XCTAssertNil(props?["price"])
        XCTAssertNil(props?["currency"])
    }
}
