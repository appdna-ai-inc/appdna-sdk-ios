// SyntheticTransactionIdTests.swift
//
// An Adapty purchase with no store transaction id gets a unique,
// clearly-marked id for the host's idempotent grant, and that id never reaches analytics as
// `transaction_id` (dedupe sees an unknown id).
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class SyntheticTransactionIdTests: XCTestCase {

    func testAnAdaptySyntheticIdIsMarkedUniqueAndNeverEmpty() {
        let a = SyntheticTransactionId.make(provider: "adapty")
        let b = SyntheticTransactionId.make(provider: "adapty")
        XCTAssertTrue(a.hasPrefix("adapty:"))
        XCTAssertNotEqual(a, b, "two purchases never share an id — a host's idempotent grant keeps both")
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(SyntheticTransactionId.isSynthetic(a))
    }

    func testRealStoreIdsAreNotSynthetic() {
        XCTAssertFalse(SyntheticTransactionId.isSynthetic("2000000812345678"))
        XCTAssertFalse(SyntheticTransactionId.isSynthetic("GPA.1234-5678-9012-34567"))
        XCTAssertFalse(SyntheticTransactionId.isSynthetic(""))
        XCTAssertFalse(SyntheticTransactionId.isSynthetic("other:abc"))
    }

    private func result(_ transactionId: String) -> PurchaseResult {
        PurchaseResult(
            productId: "pro_monthly",
            transactionId: transactionId,
            price: 4.99,
            currency: "USD",
            provider: "adapty",
            isSubscription: true,
            isConsumable: false
        )
    }

    func testTheEnvelopeOmitsASyntheticIdAndKeepsARealOne() {
        let synthetic = PurchaseSuccessEvents.properties(paywallId: "pw", result: result(SyntheticTransactionId.make(provider: "adapty")))
        XCTAssertNil(synthetic["transaction_id"], "a synthetic id is not a §13e.5 dedupe key")
        let real = PurchaseSuccessEvents.properties(paywallId: "pw", result: result("2000000812345678"))
        XCTAssertEqual(real["transaction_id"] as? String, "2000000812345678")
    }

    func testTheAlreadyOwnedEventOmitsASyntheticId() {
        let keychain = KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        var events: [SDKEvent] = []
        tracker.eventSink = { events.append($0) }
        PurchaseSuccessEvents.emitAlreadyOwned(tracker: tracker, paywallId: nil, result: result(SyntheticTransactionId.make(provider: "adapty")))
        let props = events.first { $0.event_name == "purchase_restored" }?.properties
        XCTAssertNotNil(props)
        XCTAssertNil(props?["transaction_id"])
    }
}
