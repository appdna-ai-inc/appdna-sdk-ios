// LatePurchaseFilterTests.swift
//
// Every branch of `LatePurchaseFilter.decide` and of the queue
// entry's `ownerToken`: family-shared, upgraded, revoked, renewal (17+ and pre-17), already reported, nil
// token, the current user's token, a custom token mapped to the current user, a token mapped to another
// user, an unmapped custom token, and a pending purchase approved after a user switch.

import XCTest
@testable import AppDNASDK

final class LatePurchaseFilterTests: XCTestCase {

    private let tokenA = AppAccountTokenResolver.token(forUserId: "user_a")!
    private let tokenB = AppAccountTokenResolver.token(forUserId: "user_b")!
    private let custom = UUID(uuidString: "9b2d6f3a-1c4e-4a7b-8f0d-2e6c5a4b3d21")!

    private func facts(
        ownership: String = "purchased",
        revoked: Bool = false,
        upgraded: Bool = false,
        reason: String? = "purchase",
        productType: String = "nonConsumable",
        id: String = "100",
        originalID: String = "100",
        token: UUID? = nil,
        owner: String? = nil,
        currentUser: String? = "user_a",
        reported: Bool = false
    ) -> TransactionFacts {
        TransactionFacts(
            ownershipType: ownership,
            revocationDate: revoked ? Date() : nil,
            isUpgraded: upgraded,
            reason: reason,
            productType: productType,
            id: id,
            originalID: originalID,
            appAccountToken: token,
            ownerUserId: owner,
            currentToken: currentUser.flatMap { AppAccountTokenResolver.token(forUserId: $0) },
            currentUserId: currentUser,
            alreadyReported: reported,
            purchaseDate: Date(timeIntervalSince1970: 1_788_256_800)
        )
    }

    func testSilentCases() {
        XCTAssertEqual(LatePurchaseFilter.decide(facts(ownership: "familyShared")), .finishSilently)
        XCTAssertEqual(LatePurchaseFilter.decide(facts(revoked: true)), .finishSilently)
        XCTAssertEqual(LatePurchaseFilter.decide(facts(upgraded: true)), .finishSilently)
        XCTAssertEqual(LatePurchaseFilter.decide(facts(reported: true)), .finishSilently)
    }

    func testRenewalsAreNeverReported() {
        // iOS 17+: the reason says so.
        XCTAssertEqual(LatePurchaseFilter.decide(facts(reason: "renewal", productType: "autoRenewable")), .finishSilently)
        // Before 17: an auto-renewable whose id differs from its original id.
        XCTAssertEqual(LatePurchaseFilter.decide(facts(reason: nil, productType: "autoRenewable", id: "101", originalID: "100")), .finishSilently)
        // …while the first period (id == originalID) is a purchase.
        XCTAssertEqual(LatePurchaseFilter.decide(facts(reason: nil, productType: "autoRenewable", id: "100", originalID: "100")), .report)
        // A non-renewing product before 17 is always a first purchase.
        XCTAssertEqual(LatePurchaseFilter.decide(facts(reason: nil, productType: "consumable", id: "7", originalID: "3")), .report)
    }

    func testOwnership() {
        // nil token → report, untagged.
        let untagged = facts(token: nil)
        XCTAssertEqual(LatePurchaseFilter.decide(untagged), .report)
        XCTAssertNil(LatePurchaseFilter.ownerToken(for: untagged, decision: .report))

        // the current user's derived token → report, tagged for them.
        let own = facts(token: tokenA)
        XCTAssertEqual(LatePurchaseFilter.decide(own), .report)
        XCTAssertEqual(LatePurchaseFilter.ownerToken(for: own, decision: .report), tokenA)

        // a custom token mapped to the current user → report, with the current user's DERIVED token.
        let mappedToMe = facts(token: custom, owner: "user_a")
        XCTAssertEqual(LatePurchaseFilter.decide(mappedToMe), .report)
        XCTAssertEqual(LatePurchaseFilter.ownerToken(for: mappedToMe, decision: .report), tokenA)

        // a token mapped to ANOTHER user → deferToOwner, tagged with that owner's derived token.
        let othersPurchase = facts(token: tokenB, owner: "user_b")
        XCTAssertEqual(LatePurchaseFilter.decide(othersPurchase), .deferToOwner)
        XCTAssertEqual(LatePurchaseFilter.ownerToken(for: othersPurchase, decision: .deferToOwner), tokenB)

        // an unmapped custom token → report, untagged (known: purchases before the upgrade / while
        // anonymous / evicted from the map).
        let unmapped = facts(token: custom, owner: nil)
        XCTAssertEqual(LatePurchaseFilter.decide(unmapped), .report)
        XCTAssertNil(LatePurchaseFilter.ownerToken(for: unmapped, decision: .report))
    }

    /// User A starts a purchase with the derived token that goes PENDING, the app switches to user
    /// B, the purchase is approved → deferred to A.
    func testPendingPurchaseApprovedAfterUserSwitchIsDeferredToItsOwner() {
        let approvedWhileB = facts(token: tokenA, owner: "user_a", currentUser: "user_b")
        XCTAssertEqual(LatePurchaseFilter.decide(approvedWhileB), .deferToOwner)
        XCTAssertEqual(LatePurchaseFilter.ownerToken(for: approvedWhileB, decision: .deferToOwner), tokenA)
    }

    /// An anonymous current identity never matches an owned token.
    func testAnonymousCurrentIdentityDefersAMappedPurchase() {
        XCTAssertEqual(LatePurchaseFilter.decide(facts(token: tokenA, owner: "user_a", currentUser: nil)), .deferToOwner)
    }

    // MARK: - The owner map

    func testOwnerMapRecordsAndResolvesAndSkipsAnonymous() {
        let suite = "ai.appdna.sdk.test.owner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PurchaseOwnerMap.record(token: custom, userId: "user_a", defaults: defaults)
        XCTAssertEqual(PurchaseOwnerMap.owner(of: custom, defaults: defaults), "user_a")
        PurchaseOwnerMap.record(token: tokenB, userId: nil, defaults: defaults)
        XCTAssertNil(PurchaseOwnerMap.owner(of: tokenB, defaults: defaults), "an anonymous purchase is not recorded")
        // The latest write for a token wins.
        PurchaseOwnerMap.record(token: custom, userId: "user_c", defaults: defaults)
        XCTAssertEqual(PurchaseOwnerMap.owner(of: custom, defaults: defaults), "user_c")
    }

    // MARK: - Trial detection + charged price

    func testTrialDetection() {
        func t(_ type: String?, _ mode: String?, intro: String? = nil, api: Bool = true) -> Bool {
            TrialDetection.isFreeTrial(TrialFacts(offerType: type, offerPaymentMode: mode, introPaymentMode: intro, usesOfferAPI: api))
        }
        XCTAssertTrue(t("introductory", "freeTrial"))
        XCTAssertTrue(t("promotional", "freeTrial"), "a promotional free trial counts (Play offerPhase parity)")
        XCTAssertTrue(t("code", "freeTrial"), "an offer-code free trial counts (R64)")
        XCTAssertTrue(t("winBack", "freeTrial"))
        XCTAssertFalse(t("introductory", "payUpFront"), "a paid intro is not a trial")
        XCTAssertFalse(t("introductory", "payAsYouGo"))
        XCTAssertFalse(t(nil, nil))
        // Legacy (pre-17.2): introductory + the product's intro mode.
        XCTAssertTrue(t("introductory", nil, intro: "freeTrial", api: false))
        XCTAssertFalse(t("introductory", nil, intro: "payUpFront", api: false))
        XCTAssertFalse(t("promotional", nil, intro: "freeTrial", api: false), "known: a promotional trial before 17.2 is not detected")
    }

    func testChargedPrice() {
        XCTAssertEqual(chargedPrice(transactionPrice: Decimal(string: "2.99"), productPrice: Decimal(string: "9.99")!), 2.99, accuracy: 1e-9)
        XCTAssertEqual(chargedPrice(transactionPrice: 0, productPrice: Decimal(string: "9.99")!), 0)
        XCTAssertEqual(chargedPrice(transactionPrice: nil, productPrice: Decimal(string: "9.99")!), 9.99, accuracy: 1e-9)
    }

    /// `is_trial` only when known (omitted for RevenueCat / Adapty), price 0 for a trial, `is_consumable`
    /// always, `original_transaction_id` when known, and the `emitted_by` marker.
    func testPurchaseSuccessEventProperties() {
        let trial = PurchaseResult(productId: "m", transactionId: "2", originalTransactionId: "1", price: 9.99,
                                   currency: "USD", provider: "storekit2", isSubscription: true,
                                   isConsumable: false, isTrial: true)
        let p = PurchaseSuccessEvents.properties(paywallId: nil, result: trial)
        XCTAssertEqual(p["price"] as? Double, 0)
        XCTAssertEqual(p["is_trial"] as? Bool, true)
        XCTAssertEqual(p["is_consumable"] as? Bool, false)
        XCTAssertEqual(p["original_transaction_id"] as? String, "1")
        XCTAssertEqual(p["emitted_by"] as? String, "sdk")

        let coins = PurchaseResult(productId: "coins", transactionId: "3", price: 0.99, currency: "USD",
                                   provider: "revenuecat", isSubscription: false, isConsumable: true)
        let c = PurchaseSuccessEvents.properties(paywallId: "pw", result: coins)
        XCTAssertNil(c["is_trial"], "RevenueCat / Adapty results carry no is_trial")
        XCTAssertEqual(c["is_consumable"] as? Bool, true)
        XCTAssertEqual(c["price"] as? Double, 0.99)
        XCTAssertNil(c["original_transaction_id"])
    }

    func testIsAlreadyOwnedSeam() {
        XCTAssertTrue(StoreKit2Bridge.isAlreadyOwned(preCallIds: ["5", "6"], transactionId: "5"))
        XCTAssertFalse(StoreKit2Bridge.isAlreadyOwned(preCallIds: ["5"], transactionId: "7"))
        XCTAssertFalse(StoreKit2Bridge.isAlreadyOwned(preCallIds: [], transactionId: "7"))
    }
}
