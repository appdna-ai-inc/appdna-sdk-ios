// SharedFixtureDrivers+Billing.swift
//
// SPEC-497 — iOS drivers for the billing-area fixture kinds, dispatched from `SharedFixtureTests.drive`:
//
//   billing_ownership          REAL: BillingOwnership.policy(for:bridgeLinked:) — the table configure uses.
//   purchase (billing_provider set; the `paywall_purchase_*_fails_loudly` fixtures)
//                              REAL: PaywallManager.handlePurchase — the tap path — with the bridge and
//                              policy production builds for that provider (BillingOwnership.makeBridge).
//                              No store call happens on that path, so it is drivable end to end.
//   derive_app_account_token   REAL: AppAccountTokenResolver.token(forUserId:).
//   subscription_snapshot_diff REAL: SubscriptionStatusObserver.reconcile() (diffAndEmit + saveSnapshot)
//                              over an injected loader and a per-fixture UserDefaults suite. Event
//                              properties are compared EXACTLY (no extra, no missing key — R49).
//   trial_price                REAL: TrialDetection.isFreeTrial + chargedPrice + PurchaseSuccessEvents.properties.
//   late_purchase              REAL: LatePurchaseProcessor.process (LatePurchaseFilter.decide + the queue
//                              write + the emit) into a real PurchaseDeliveryQueue.
//   rebuy_already_owned        REAL: StoreKit2Bridge.isAlreadyOwned + PurchaseSuccessEvents.emitAlreadyOwned.
//   decode_verify_reply        REAL: the `/billing/verify` reply decoder (`VerifyReply` + VerifiedPurchase.parse)
//                              that ReceiptVerifier.verify runs on the server's bytes.
//   delivery_queue             REAL: PurchaseDeliveryQueue (identity rule, drain) + LatePurchaseProcessor
//                              for `report` steps. The queue's triggers (setDelegate / identify) are
//                              emulated by calling the drain they call — the trigger wiring itself is
//                              covered by DeliveryQueueTests.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import UIKit
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveSpec497Billing(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "billing_ownership":           runBillingOwnership(f, h)
        case "derive_app_account_token":    runDeriveAppAccountToken(f, h)
        case "subscription_snapshot_diff":  await runSubscriptionSnapshotDiff(f, h)
        case "trial_price":                 runTrialPrice(f, h)
        case "late_purchase":               await runLatePurchase(f, h)
        case "rebuy_already_owned":         await runRebuyAlreadyOwned(f, h)
        case "delivery_queue":              await runDeliveryQueue(f, h)
        case "decode_verify_reply":         runDecodeVerifyReply(f, h)
        default:
            return false
        }
        return true
    }

    // MARK: - billing_ownership

    private func runBillingOwnership(_ f: Fixture, _ h: Harness) {
        guard let provider = Self.billingProvider(from: f.action.raw["provider"]) else {
            return XCTFail("[\(f.id)] billing_ownership needs action.provider")
        }
        let linked = f.action.raw["bridge_linked"]?.boolValue ?? false
        let policy = BillingOwnership.policy(for: provider, bridgeLinked: linked)   // REAL
        h.state["policy"] = [
            "ownsTransactions": policy.ownsTransactions,
            "sdkCanPurchase": policy.sdkCanPurchase,
            "sdkCanRestore": policy.sdkCanRestore,
            "observerMode": policy.observerMode.rawValue,
            "emitsLifecycleEvents": policy.emitsLifecycleEvents,
        ]
    }

    /// The fixture speaks the wire form (`"storeKit2"`, `{"type":"adapty","apiKey":"k"}`) and, for the
    /// ownership table, a bare `"adapty"` (the key does not matter to the policy).
    static func billingProvider(from json: AnyJSON?) -> BillingProvider? {
        guard let json else { return nil }
        if let parsed = BillingProvider.fromWire(json.foundation) { return parsed }
        if json.stringValue == "adapty" { return .adapty(apiKey: "fixture") }
        return nil
    }

    // MARK: - purchase under a provider the SDK cannot buy through (fails loudly)

    /// `true` when this fixture's paywall declares a `billing_provider` — the tap then goes through the
    /// REAL `PaywallManager.handlePurchase` guard.
    func runPurchaseUnderProvider(_ f: Fixture, _ h: Harness) async -> Bool {
        guard let config = f.setup.config?.objectValue,
              let provider = Self.billingProvider(from: config["billing_provider"]) else { return false }
        let paywallId = f.action.raw["paywall_id"]?.stringValue ?? ""
        let productId = f.action.raw["product_id"]?.stringValue ?? ""

        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        guard let paywall = rcm.decodePaywallPayload(config.mapValues { $0.foundation }),
              let plan = paywall.plans?.first(where: { $0.productId == productId }) else {
            XCTFail("[\(f.id)] setup.config does not decode into a paywall holding plan \(productId)")
            return true
        }

        // The bridge and the policy production builds for this provider.
        let policy = BillingOwnership.policy(for: provider, bridgeLinked: BillingOwnership.isLinked(provider))
        let bridge = BillingOwnership.makeBridge(for: provider, tracker: h.tracker)
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: bridge,
            billingPolicy: policy,
            eventTracker: h.tracker
        )
        let delegate = TapPathPaywallDelegateSpy(harness: h)

        await MainActor.run {
            manager.handlePurchase(
                paywallId: paywallId,
                plan: plan,
                config: paywall,
                delegate: delegate,
                viewController: UIViewController()
            )
        }
        // The delegate call is dispatched to the main queue; wait for it (bounded).
        for _ in 0..<100 where h.delegateCalls.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await MainActor.run {}
        }
        return true
    }

    /// Records `onPaywallPurchaseStarted` too — the refusal path must NOT call it.
    final class TapPathPaywallDelegateSpy: AppDNAPaywallDelegate {
        private weak var harness: Harness?
        init(harness: Harness) { self.harness = harness }
        func onPaywallPresented(paywallId: String) {}
        func onPaywallPurchaseStarted(paywallId: String, productId: String) {
            harness?.recordDelegate("onPaywallPurchaseStarted", ["paywallId": paywallId, "productId": productId])
        }
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
            harness?.recordDelegate("onPaywallPurchaseCompleted", ["paywallId": paywallId, "productId": productId])
        }
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
            harness?.recordDelegate("onPaywallPurchaseFailed", [
                "paywallId": paywallId,
                "errorType": errorType,
                "productId": SharedFixtureTests.orNull(productId),
            ])
        }
        func onPaywallDismissed(paywallId: String) {}
    }

    // MARK: - derive_app_account_token

    private func runDeriveAppAccountToken(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            return XCTFail("[\(f.id)] derive_app_account_token needs action.cases")
        }
        h.state["tokens"] = cases.map { c -> Any in
            let userId = c.objectValue?["user_id"]?.stringValue ?? ""
            return SharedFixtureTests.orNull(AppAccountTokenResolver.token(forUserId: userId)?.uuidString.lowercased())
        }
    }

    // MARK: - subscription_snapshot_diff

    private func runSubscriptionSnapshotDiff(_ f: Fixture, _ h: Harness) async {
        let previous = Self.snapshots(f.setup.raw["previous_snapshot"])
        let current = Self.snapshots(f.setup.raw["current"])
        let suiteName = "ai.appdna.sdk.fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("[\(f.id)] no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let observer = SubscriptionStatusObserver(
            eventTracker: h.tracker,
            defaults: defaults,
            mode: .providerOwned,
            emitsLifecycleEvents: true,
            loadCurrent: { current }
        )
        observer.saveSnapshot(previous)
        await observer.reconcile()                                   // REAL diffAndEmit + saveSnapshot

        h.state["snapshot_after"] = observer.loadSnapshot().values
            .sorted { $0.productId < $1.productId }
            .map { s -> [String: Any] in
                var out: [String: Any] = [
                    "product_id": s.productId,
                    "purchase_time": s.purchaseTime,
                    "is_auto_renewing": s.isAutoRenewing,
                ]
                if let id = s.transactionId { out["transaction_id"] = id }
                if let original = s.originalTransactionId { out["original_transaction_id"] = original }
                return out
            }

        // R49 — the properties are compared EXACTLY: an extra or a missing key fails.
        for (i, expected) in (f.expect.events ?? []).enumerated() where i < h.events.count {
            let expectedKeys = Set(expected.properties?.objectValue?.keys.map { $0 } ?? [])
            let actualKeys = Set(h.events[i].properties?.keys.map { $0 } ?? [])
            XCTAssertEqual(actualKeys, expectedKeys, "[\(f.id)] event[\(i)] property keys (exact)")
        }
    }

    static func snapshots(_ json: AnyJSON?) -> [String: SubSnapshot] {
        var out: [String: SubSnapshot] = [:]
        for item in json?.arrayValue ?? [] {
            guard let o = item.objectValue, let productId = o["product_id"]?.stringValue else { continue }
            out[productId] = SubSnapshot(
                productId: productId,
                purchaseTime: Int64(o["purchase_time"]?.doubleValue ?? 0),
                isAutoRenewing: o["is_auto_renewing"]?.boolValue ?? false,
                transactionId: o["transaction_id"]?.stringValue,
                originalTransactionId: o["original_transaction_id"]?.stringValue,
                price: o["price"]?.doubleValue,
                currency: o["currency"]?.stringValue
            )
        }
        return out
    }

    // MARK: - decode_verify_reply

    /// Each case's reply goes through the SAME bytes → `VerifyReply` → `VerifiedPurchase.parse` path
    /// `ReceiptVerifier.verify` runs; the result is written under the DTO's snake_case names.
    private func runDecodeVerifyReply(_ f: Fixture, _ h: Harness) {
        var parsed: [String: Any] = [:]
        for item in f.action.raw["cases"]?.arrayValue ?? [] {
            guard let c = item.objectValue, let name = c["name"]?.stringValue, let reply = c["reply"] else { continue }
            do {
                let data = try JSONSerialization.data(withJSONObject: reply.foundation)
                let v = VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: data).data)   // REAL
                parsed[name] = [
                    "entitled": v.entitled,
                    "product_id": v.productId,
                    "product_type": SharedFixtureTests.orNull(v.productType),
                    "store": v.store,
                    "status": v.status,
                    "expires_at": SharedFixtureTests.orNull(v.expiresAt),
                    "is_trial": v.isTrial,
                    "original_transaction_id": SharedFixtureTests.orNull(v.originalTransactionId),
                    "consume": v.consume,
                ]
            } catch {
                XCTFail("[\(f.id)] case \(name): the reply did not decode: \(error)")
            }
        }
        h.state["parsed"] = parsed
    }

    // MARK: - trial_price

    private func runTrialPrice(_ f: Fixture, _ h: Harness) {
        let setup = f.setup.raw
        let offer = setup["offer"]?.objectValue
        let facts = TrialFacts(
            offerType: offer?["type"]?.stringValue,
            offerPaymentMode: offer?["paymentMode"]?.stringValue,
            introPaymentMode: setup["product_intro_payment_mode"]?.stringValue,
            usesOfferAPI: setup["offer_api"]?.stringValue == "17.2"
        )
        let isTrial = TrialDetection.isFreeTrial(facts)                                // REAL
        let price = chargedPrice(                                                       // REAL
            transactionPrice: Self.decimal(setup["transaction_price"]),
            productPrice: Self.decimal(setup["product_price"]) ?? 0
        )
        let result = PurchaseResult(
            productId: f.action.raw["product_id"]?.stringValue ?? "",
            transactionId: "",
            price: price,
            currency: "USD",
            provider: "storekit2",
            isSubscription: true,
            isConsumable: false,
            isTrial: isTrial
        )
        let props = PurchaseSuccessEvents.properties(paywallId: nil, result: result)      // REAL
        h.state["event"] = [
            "price": SharedFixtureTests.orNull(props["price"]),
            "is_trial": SharedFixtureTests.orNull(props["is_trial"]),
        ]
    }

    static func decimal(_ json: AnyJSON?) -> Decimal? {
        guard let d = json?.doubleValue else { return nil }
        return Decimal(string: String(d))
    }

    // MARK: - late_purchase

    private func runLatePurchase(_ f: Fixture, _ h: Harness) async {
        let world = QueueWorld()
        let queue = world.makeQueue(tracker: h.tracker)
        await queue.activate(environment: world.environment(tracker: h.tracker))

        if let cases = f.action.raw["cases"]?.arrayValue {
            // Per-case decisions only: each case's emit goes to a scratch tracker (the fixture asserts
            // the decision and the stored envelope, not the events).
            let scratch = EventTracker(identityManager: h.identityManager)
            var decisions: [Any] = []
            var purchasedAt: [Any] = []
            for c in cases {
                guard let factsJSON = c.objectValue?["transaction_facts"], let facts = Self.transactionFacts(factsJSON) else {
                    return XCTFail("[\(f.id)] a late_purchase case needs transaction_facts")
                }
                let decision = await LatePurchaseProcessor.process(facts: facts, queue: queue, tracker: scratch) {
                    self.lateEnvelope(f, facts)
                }
                decisions.append(decision.rawValue)
                if decision == .deferToOwner,
                   let stored = await queue.entry(transactionId: facts.id)?.properties?["purchased_at_ms"]?.value {
                    purchasedAt.append(stored)
                } else {
                    purchasedAt.append(NSNull())
                }
            }
            h.state["late_decisions"] = decisions
            h.state["purchased_at_ms"] = purchasedAt
            return
        }

        guard let facts = Self.transactionFacts(f.setup.raw["transaction_facts"]) else {
            return XCTFail("[\(f.id)] late_purchase needs setup.transaction_facts or action.cases")
        }
        world.delegateSet = f.setup.raw["delegate_set"]?.boolValue ?? true
        world.delegate = BillingDelegateSpy(harness: h)
        let decision = await LatePurchaseProcessor.process(facts: facts, queue: queue, tracker: h.tracker) {
            self.lateEnvelope(f, facts)
        }
        if decision == .report { world.deliveries += await queue.drain() }   // trigger (i)
        h.state["late_decision"] = decision.rawValue
        h.state["queue"] = await queue.queuedIds()
    }

    private func lateEnvelope(_ f: Fixture, _ facts: TransactionFacts) -> LateEnvelope {
        let config = f.setup.config?.objectValue ?? [:]
        return LateEnvelope.make(
            facts: facts,
            productId: config["product_id"]?.stringValue ?? "",
            price: config["price"]?.doubleValue,
            currency: config["currency"]?.stringValue,
            isTrial: false
        )
    }

    static func transactionFacts(_ json: AnyJSON?) -> TransactionFacts? {
        guard let o = json?.objectValue, let id = o["id"]?.stringValue else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date? { o[key]?.stringValue.flatMap { iso.date(from: $0) } }
        func uuid(_ key: String) -> UUID? { o[key]?.stringValue.flatMap { UUID(uuidString: $0) } }
        return TransactionFacts(
            ownershipType: o["ownershipType"]?.stringValue ?? "purchased",
            revocationDate: date("revocationDate"),
            isUpgraded: o["isUpgraded"]?.boolValue ?? false,
            reason: o["reason"]?.stringValue,
            productType: o["productType"]?.stringValue ?? "nonConsumable",
            id: id,
            originalID: o["originalID"]?.stringValue ?? id,
            appAccountToken: uuid("appAccountToken"),
            ownerUserId: o["ownerUserId"]?.stringValue,
            currentToken: uuid("currentToken"),
            currentUserId: o["currentUserId"]?.stringValue,
            alreadyReported: o["alreadyReported"]?.boolValue ?? false,
            purchaseDate: date("purchaseDate") ?? Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - rebuy_already_owned

    private func runRebuyAlreadyOwned(_ f: Fixture, _ h: Harness) async {
        let config = f.setup.config?.objectValue ?? [:]
        let owned = await Self.driveRebuy(
            preCallIds: Set((f.setup.raw["pre_call_entitlement_ids"]?.arrayValue ?? []).compactMap(\.stringValue)),
            transactionId: f.action.raw["transaction_id"]?.stringValue ?? "",
            productId: f.action.raw["product_id"]?.stringValue ?? "",
            price: config["price"]?.doubleValue ?? 0,
            currency: config["currency"]?.stringValue ?? "USD",
            tracker: h.tracker,
            delegate: BillingDelegateSpy(harness: h)
        )
        h.state["already_owned"] = owned
    }

    /// The `rebuy_already_owned` pipeline, shared with its positive control
    /// (`RebuyDriverPositiveControlTests`, impl audit round 2 I8): `alreadyOwned == false` must deliver
    /// exactly one `onPurchaseCompleted`, so a driver that never delivers cannot pass the re-buy fixture
    /// vacuously. Returns `alreadyOwned`.
    static func driveRebuy(
        preCallIds: Set<String>,
        transactionId: String,
        productId: String,
        price: Double,
        currency: String,
        tracker: EventTracker,
        delegate: AppDNABillingDelegate
    ) async -> Bool {
        let owned = StoreKit2Bridge.isAlreadyOwned(preCallIds: preCallIds, transactionId: transactionId)   // REAL
        // REAL — the live caller's `onPurchaseCompleted` delivery `StoreKit2Bridge.purchase` makes after
        // `finish()`, with a recording delegate: `delegate_calls: []` fails if a re-buy delivers.
        let txInfo = TransactionInfo(
            transactionId: transactionId,
            productId: productId,
            purchaseDate: Date(timeIntervalSince1970: 0)
        )
        await MainActor.run {
            _ = StoreKit2Bridge.deliverToLiveCaller(alreadyOwned: owned, transaction: txInfo, delegate: delegate)
        }
        let result = PurchaseResult(
            productId: productId,
            transactionId: transactionId,
            price: price,
            currency: currency,
            provider: "storekit2",
            isSubscription: false,
            isConsumable: false,
            isTrial: false,
            alreadyOwned: owned
        )
        // REAL — what both callers (BillingModule.purchase, PaywallManager) do with an owned result.
        if result.alreadyOwned {
            PurchaseSuccessEvents.emitAlreadyOwned(tracker: tracker, paywallId: nil, result: result)
        } else {
            PurchaseSuccessEvents.emit(tracker: tracker, paywallId: nil, result: result)
        }
        return owned
    }

    // MARK: - delivery_queue

    private func runDeliveryQueue(_ f: Fixture, _ h: Harness) async {
        let world = QueueWorld()
        world.currentUserId = f.setup.raw["current_user_id"]?.stringValue
        world.firstIdentifiedUserId = f.setup.raw["first_identified_user_id"]?.stringValue ?? world.currentUserId
        world.delegateSet = f.setup.raw["delegate_set"]?.boolValue ?? true
        world.delegate = BillingDelegateSpy(harness: h)

        let queue = world.makeQueue(tracker: h.tracker)
        await queue.activate(environment: world.environment(tracker: h.tracker))

        // Seed: already-reported, already-queued purchases.
        for item in f.setup.raw["pending_deliveries"]?.arrayValue ?? [] {
            guard let o = item.objectValue, let token = o["token"]?.stringValue else { continue }
            await queue.recordReport(PendingDelivery(
                transactionId: token,
                productId: o["productId"]?.stringValue ?? "",
                purchaseTime: 0,
                ownerToken: o["ownerToken"]?.stringValue,
                emitPending: false,
                properties: nil,
                isSubscription: false
            ))
        }

        for step in f.action.raw["steps"]?.arrayValue ?? [] {
            guard let s = step.objectValue, let kind = s["kind"]?.stringValue else { continue }
            switch kind {
            case "set_delegate":
                world.delegateSet = true
                world.deliveries += await queue.drain()                 // trigger (ii)
            case "reset":
                world.currentUserId = nil                               // reset keeps the first-identifier
            case "identify":
                let userId = s["user_id"]?.stringValue
                world.currentUserId = userId
                if world.firstIdentifiedUserId == nil { world.firstIdentifiedUserId = userId }
                world.deliveries += await queue.drain()                 // trigger (iii)
            case "report":
                guard let facts = Self.transactionFacts(s["transaction_facts"]) else {
                    return XCTFail("[\(f.id)] a report step needs transaction_facts")
                }
                let decision = await LatePurchaseProcessor.process(facts: facts, queue: queue, tracker: h.tracker) {
                    self.lateEnvelope(f, facts)
                }
                if decision == .report { world.deliveries += await queue.drain() }   // trigger (i)
            default:
                return XCTFail("[\(f.id)] unknown delivery_queue step '\(kind)'")
            }
        }
        h.state["queue"] = await queue.queuedIds()
        h.state["deliveries"] = world.deliveries
    }

    /// The identity + delegate world a fixture's queue sees.
    final class QueueWorld {
        var currentUserId: String?
        var firstIdentifiedUserId: String?
        var delegateSet = false
        var delegate: AppDNABillingDelegate?
        var deliveries: [String] = []
        let suiteName = "ai.appdna.sdk.fixture.queue.\(UUID().uuidString)"

        func environment(tracker: EventTracker) -> PurchaseDeliveryQueue.Environment {
            PurchaseDeliveryQueue.Environment(
                defaults: UserDefaults(suiteName: suiteName) ?? .standard,
                now: Date.init,
                currentToken: { [unowned self] in self.currentUserId.flatMap { AppAccountTokenResolver.token(forUserId: $0) } },
                firstIdentifiedToken: { [unowned self] in self.firstIdentifiedUserId.flatMap { AppAccountTokenResolver.token(forUserId: $0) } },
                deliveringDelegate: { [unowned self] in self.delegateSet ? self.delegate : nil },
                tracker: { tracker }
            )
        }

        func makeQueue(tracker: EventTracker) -> PurchaseDeliveryQueue {
            PurchaseDeliveryQueue(environment: environment(tracker: tracker))
        }
    }

    /// The host's billing delegate — the drain is what calls it.
    final class BillingDelegateSpy: AppDNABillingDelegate {
        private weak var harness: Harness?
        init(harness: Harness) { self.harness = harness }
        func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
            harness?.recordDelegate("onPurchaseCompleted", [
                "productId": productId,
                "transactionId": transaction.transactionId,
            ])
        }
    }
}
