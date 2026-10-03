// BillingOwnershipTests.swift
//
// The ownership table, row by row, plus the bridge production builds per provider.

import XCTest
@testable import AppDNASDK

final class BillingOwnershipTests: XCTestCase {

    private func assertPolicy(
        _ provider: BillingProvider, linked: Bool,
        owns: Bool, purchase: Bool, restore: Bool, mode: BillingObserverMode, lifecycle: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let p = BillingOwnership.policy(for: provider, bridgeLinked: linked)
        XCTAssertEqual(p.ownsTransactions, owns, "ownsTransactions", file: file, line: line)
        XCTAssertEqual(p.sdkCanPurchase, purchase, "sdkCanPurchase", file: file, line: line)
        XCTAssertEqual(p.sdkCanRestore, restore, "sdkCanRestore", file: file, line: line)
        XCTAssertEqual(p.observerMode, mode, "observerMode", file: file, line: line)
        XCTAssertEqual(p.emitsLifecycleEvents, lifecycle, "emitsLifecycleEvents", file: file, line: line)
    }

    func testStoreKit2OwnsEverything() {
        assertPolicy(.storeKit2, linked: true, owns: true, purchase: true, restore: true, mode: .storeKitOwned, lifecycle: true)
        // The bridgeLinked flag is irrelevant for the SDK's own billing.
        assertPolicy(.storeKit2, linked: false, owns: true, purchase: true, restore: true, mode: .storeKitOwned, lifecycle: true)
    }

    func testRevenueCatUnlinkedNeverOwnsAndCannotBuy() {
        assertPolicy(.revenueCat, linked: false, owns: false, purchase: false, restore: false, mode: .providerOwned, lifecycle: false)
    }

    func testRevenueCatLinkedBuysThroughRevenueCatButNeverOwns() {
        assertPolicy(.revenueCat, linked: true, owns: false, purchase: true, restore: true, mode: .providerOwned, lifecycle: false)
    }

    func testAdaptyKeepsLifecycleEventsLinkedOrNot() {
        assertPolicy(.adapty(apiKey: "k"), linked: true, owns: false, purchase: false, restore: true, mode: .providerOwned, lifecycle: true)
        assertPolicy(.adapty(apiKey: "k"), linked: false, owns: false, purchase: false, restore: false, mode: .providerOwned, lifecycle: true)
    }

    func testNoneHasNoBillingAtAll() {
        assertPolicy(BillingProvider.none, linked: false, owns: false, purchase: false, restore: false, mode: .none, lifecycle: false)
        XCTAssertNil(BillingOwnership.policy(for: BillingProvider.none, bridgeLinked: false).observerMode.subscriptionObserverMode)
    }

    /// Rule 1 — `.storeKitOwned` ONLY for `storeKit2`.
    func testOnlyStoreKit2GetsTheOwningObserver() {
        let providers: [BillingProvider] = [.storeKit2, .revenueCat, .adapty(apiKey: "k"), .none]
        for provider in providers {
            for linked in [true, false] {
                let mode = BillingOwnership.policy(for: provider, bridgeLinked: linked).observerMode
                XCTAssertEqual(mode == .storeKitOwned, provider == .storeKit2, "\(provider) linked=\(linked)")
            }
        }
    }

    /// Published channels link neither provider SDK.
    func testThisBuildLinksNeitherProvider() {
        XCTAssertFalse(BillingOwnership.isLinked(.revenueCat))
        XCTAssertFalse(BillingOwnership.isLinked(.adapty(apiKey: "k")))
        XCTAssertTrue(BillingOwnership.isLinked(.storeKit2))
    }

    /// The bridge production builds: an unlinked provider gets `ExternalProviderBridge` — never the
    /// old silent `StoreKit2Bridge` fallback.
    func testUnlinkedProvidersGetTheExternalProviderBridge() {
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
        XCTAssertTrue(BillingOwnership.makeBridge(for: .storeKit2, tracker: tracker) is StoreKit2Bridge)
        let rc = BillingOwnership.makeBridge(for: .revenueCat, tracker: tracker)
        XCTAssertFalse(rc is StoreKit2Bridge)
        XCTAssertEqual((rc as? ExternalProviderBridge)?.provider, .revenueCat)
        XCTAssertEqual((BillingOwnership.makeBridge(for: .adapty(apiKey: "k"), tracker: tracker) as? ExternalProviderBridge)?.provider, .adapty)
        XCTAssertNil(BillingOwnership.makeBridge(for: .none, tracker: tracker))
    }

    func testExternalProviderBridgeRefusesPurchaseAndRestoreWithProviderNotAvailable() async {
        let bridge = ExternalProviderBridge(provider: .revenueCat)
        do {
            _ = try await bridge.purchase(productId: "p1", appAccountToken: nil)
            XCTFail("purchase must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
            XCTAssertEqual(error.localizedDescription, "RevenueCat: purchases are made by RevenueCat in your app")
        }
        do {
            _ = try await bridge.restore(appAccountToken: nil)
            XCTFail("restore must throw")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
    }

    func testRefusalMessages() {
        XCTAssertEqual(BillingOwnership.policy(for: .none, bridgeLinked: false).refusalMessage, "No billing provider configured")
        XCTAssertEqual(BillingOwnership.policy(for: .adapty(apiKey: "k"), bridgeLinked: false).refusalMessage,
                       "Adapty: purchases are made by Adapty in your app")
    }

    // MARK: - marker helpers

    func testMarkedAddsEmittedBySdkAndStripRemovesBothReservedKeys() {
        XCTAssertEqual(BillingEventProps.marked(["a": 1])["emitted_by"] as? String, "sdk")
        let stripped = BillingEventProps.strippingReservedKeys([
            "product_id": "p1", "emitted_by": "sdk", "_appdna_origin": "integration:revenuecat",
        ])
        XCTAssertEqual(stripped?.keys.sorted(), ["product_id"])
        XCTAssertNil(BillingEventProps.strippingReservedKeys(nil))
    }
}
