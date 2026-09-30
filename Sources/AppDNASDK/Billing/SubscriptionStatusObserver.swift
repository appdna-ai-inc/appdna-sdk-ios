import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// One auto-renewable subscription as the SDK last observed it.
///
/// Field-for-field the same snapshot Android persists (`NativeBillingManager.SubSnapshot`), including
/// `purchaseTime` in epoch **milliseconds** — Play hands out millis, so iOS converts rather than
/// letting the same property mean two different things per platform.
struct SubSnapshot: Codable, Equatable {
    let productId: String
    let purchaseTime: Int64
    let isAutoRenewing: Bool
    /// SPEC-497 §13e.5 rule 2 (S-M4) — the ids LAST SEEN for this product (`Transaction.id` /
    /// `originalID`), so lifecycle events can be matched against provider rows. Optional: a snapshot
    /// persisted by an older SDK lacks the keys and must still decode — a required field would make the
    /// `try? … ?? [:]` load silently reset the baseline and lose one cycle of events. When absent, the
    /// event keys are OMITTED, never sent empty.
    var transactionId: String? = nil
    var originalTransactionId: String? = nil
    /// The price CHARGED for the current period (`transaction.price`, the product's price when StoreKit
    /// has none) and its ISO currency — what `subscription_renewed` reports as `price` / `currency`, the
    /// same property names `purchase_completed` uses. Optional for the same reason as the ids: an older
    /// snapshot lacks them, and the keys are then omitted, never sent as 0.
    var price: Double? = nil
    var currency: String? = nil

    init(
        productId: String,
        purchaseTime: Int64,
        isAutoRenewing: Bool,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        price: Double? = nil,
        currency: String? = nil
    ) {
        self.productId = productId
        self.purchaseTime = purchaseTime
        self.isAutoRenewing = isAutoRenewing
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.price = price
        self.currency = currency
    }
}

/// Who owns the StoreKit transaction lifecycle while this observer is running.
///
/// It decides ONE thing, and it is not cosmetic: whether the observer may drain `Transaction.updates`
/// and call `transaction.finish()`.
enum SubscriptionObserverMode {
    /// AppDNA owns billing (`billingProvider == .storeKit2`). `StoreKit2Bridge` finishes the
    /// transactions it purchases; nothing else finishes a renewal, so the observer must.
    case storeKitOwned

    /// A third-party provider (RevenueCat / Adapty) owns billing. It finishes transactions itself —
    /// only AFTER posting the receipt to its own backend — so the observer must NOT touch
    /// `Transaction.updates` or `finish()`. It still reconciles, because reading
    /// `Transaction.currentEntitlements` is read-only and provider-agnostic.
    case providerOwned
}

/// 🔴 iOS emitted ZERO subscription-lifecycle events.
///
/// `Billing/NativeBillingManager.swift` had a `Transaction.updates` listener, but that class was never
/// instantiated — the live billing surface is `BillingModule.bridge` → `StoreKit2Bridge`, which tracks
/// nothing. Net effect: an iOS subscriber produced exactly ONE MTPU-qualifying event, ever
/// (`purchase_completed` at signup). Every renewal after that was invisible, so iOS LTV,
/// renewal-retention and churn curves showed subscribers vanishing after month 1 — silently, because
/// `raw.sdk_events.properties` is a JSON blob and a missing event never alerts.
///
/// This observer is the live path's lifecycle emitter. It mirrors Android's
/// `NativeBillingManager.reconcileSubscriptionState` / `diffAndEmit` exactly — same three event names,
/// same property names, same snapshot-diff rules:
///
///   - product **vanished** from the entitlements, previously auto-renewing → `subscription_renewal_failed`
///     (billing retry / grace period), otherwise → `subscription_canceled`
///   - product **still present** with a later `purchaseTime` → `subscription_renewed`
///   - product **new** since the last snapshot → nothing (that is `purchase_completed`'s job — emitting
///     here too is how you get the double-count Android had on its purchase events)
///
/// Triggers, matching Android's: StoreKit's `Transaction.updates` (the direct analogue of Play's
/// `PurchasesUpdatedListener`, but unlike Play's it DOES fire for renewals — `.storeKitOwned` only),
/// app-foreground (Android uses `ProcessLifecycleOwner.ON_START` — it catches the expirations that
/// produce no transaction at all), and, under `.providerOwned`, the provider's own subscriber-state
/// callback via `AppDNA.reconcileSubscriptionState()`.
///
/// 🔴 **Every trigger funnels through a SERIAL chain.** `reconcile()` used to be a plain `async` method
/// with no lock and no in-flight flag, driven from two unsynchronized triggers — and it awaits
/// `Transaction.currentEntitlements` *and* a `Product.products(for:)` NETWORK call before it writes the
/// snapshot. Cold start after a renewal that happened while the app was dead fires both triggers at
/// once; both loaded the same stale `previous`, both saw the later `purchaseTime`, and BOTH emitted
/// `subscription_renewed`. That is an MTPU **over**-count on the single most common renewal case, and
/// MTPU is how customers are metered. Passes now queue behind each other: pass 2 reads the snapshot
/// pass 1 persisted, sees no change, and emits nothing. Serialized — not coalesced: a second trigger
/// still runs a full pass afterwards, because it may carry state the first pass began before.
final class SubscriptionStatusObserver {

    /// Persisted under the same semantic key Android uses (`billing_last_sub_snapshot_v1`).
    static let snapshotKey = "appdna.billing.last_sub_snapshot_v1"

    /// The async source of the CURRENT subscription state. Defaults to StoreKit; injectable so the
    /// serialization above can be driven by a unit test — StoreKit itself needs a StoreKitTest session,
    /// and a race that only reproduces on a device is a race nobody proves fixed.
    typealias EntitlementLoader = @Sendable () async -> [String: SubSnapshot]

    /// SPEC-497 §13a.2 — the source of `Transaction.updates` items. Injectable so a test can feed a
    /// real `Transaction` captured from an `SKTestSession` purchase.
    typealias UpdatesSource = () -> AsyncStream<VerificationResult<Transaction>>

    /// Under `.providerOwned`: one signal per `Transaction.updates` item, read-only (the item is never
    /// finished — the provider does that). Injectable for tests.
    typealias UpdateSignals = () -> AsyncStream<Void>

    private let eventTracker: EventTracker
    private let defaults: UserDefaults
    private let mode: SubscriptionObserverMode
    private let loadCurrent: EntitlementLoader
    /// SPEC-497 §3.2 rule 4 (owner Q2 / LD-R10-1) — device lifecycle events. `false` under RevenueCat
    /// (its webhook is the single source). The snapshot is computed and persisted EITHER WAY, so a later
    /// switch to `storeKit2` diffs against a current baseline instead of a burst of stale events.
    private let emitsLifecycleEvents: Bool
    private let updatesSource: UpdatesSource
    private let updateSignals: UpdateSignals
    private let deliveryQueue: PurchaseDeliveryQueue
    private let verificationQueue: PurchaseVerificationQueue
    /// Runs after EVERY pass (detached, outside the serial chain): the entitlement refresh — which fires
    /// `onEntitlementsChanged` when renewal, expiry or a refund changed them — and the verification retry.
    /// Nil in tests that do not need it.
    private let afterPass: (@Sendable () async -> Void)?

    private var updatesTask: Task<Void, Never>?
    private var foregroundToken: NSObjectProtocol?

    /// The tail of the serial chain. Guarded by `chainLock` because the triggers arrive on different
    /// threads: `Transaction.updates` on the cooperative pool, `didBecomeActive` on the main thread,
    /// and a provider callback on whichever thread the provider's SDK uses.
    private let chainLock = NSLock()
    private var chain: Task<Void, Never>?

    init(
        eventTracker: EventTracker,
        defaults: UserDefaults = .standard,
        mode: SubscriptionObserverMode = .storeKitOwned,
        emitsLifecycleEvents: Bool = true,
        loadCurrent: EntitlementLoader? = nil,
        updatesSource: UpdatesSource? = nil,
        updateSignals: UpdateSignals? = nil,
        deliveryQueue: PurchaseDeliveryQueue = .shared,
        verificationQueue: PurchaseVerificationQueue = .shared,
        afterPass: (@Sendable () async -> Void)? = nil
    ) {
        self.eventTracker = eventTracker
        self.defaults = defaults
        self.mode = mode
        self.emitsLifecycleEvents = emitsLifecycleEvents
        self.loadCurrent = loadCurrent ?? { await SubscriptionStatusObserver.storeKitSnapshot() }
        self.updatesSource = updatesSource ?? TransactionUpdatesSource.storeKit
        self.updateSignals = updateSignals ?? TransactionUpdatesSource.signals
        self.deliveryQueue = deliveryQueue
        self.verificationQueue = verificationQueue
        self.afterPass = afterPass
    }

    // MARK: - Lifecycle

    /// Start observing. Under `.storeKitOwned` this is long-lived: the `Transaction.updates` sequence
    /// never ends, so the task lives for the whole SDK session and is cancelled by `stop()` (called from
    /// `AppDNA.shutdown()`).
    func start() {
        guard updatesTask == nil else { return }

        switch mode {
        case .storeKitOwned:
            updatesTask = Task { [weak self] in
                // Renewals that happened while the app was dead do not necessarily arrive as an update —
                // reconcile once at launch so they are still caught. Same reason Android reconciles on
                // every foreground entry rather than trusting its purchase listener.
                await self?.reconcile()

                guard let source = self?.updatesSource else { return }
                for await result in source() {
                    guard let self else { return }
                    guard case .verified(let transaction) = result else { continue }
                    // Apple redelivers an unfinished transaction on every launch forever. StoreKit2Bridge
                    // finishes the ones it purchases; renewals, interrupted / Ask-to-Buy purchases and
                    // offer codes arrive here and nothing else would.
                    var update = OwnedTransactionUpdate(transaction: transaction)
                    update.signedTransaction = result.jwsRepresentation
                    await self.handleOwnedUpdate(update)
                    // A renewal, a refund / revocation or a late purchase: the pass below diffs the
                    // subscription snapshot and (via `afterPass`) refreshes the entitlements.
                    await self.reconcile()
                }
            }

        case .providerOwned:
            // RevenueCat and Adapty finish transactions themselves, and only after posting the receipt
            // to their backend. Draining `Transaction.updates` here would finish a renewal out from
            // under the provider — losing the subscription server-side, which is a far worse bug than
            // the one this class exists to fix. So under `.providerOwned` the observer never consumes
            // updates and never calls `finish()`. It reconciles from `Transaction.currentEntitlements`
            // (read-only, and populated for provider purchases too, since they are still Apple
            // purchases) on: start, every foreground, and every provider subscriber-state callback.
            //
            // `Transaction.updates` is still LISTENED to — read-only, as a signal: each item (a renewal, a
            // refund / revocation, a purchase the provider made) triggers a pass, so entitlement changes
            // report when they happen instead of at the next foreground. The item is never finished and
            // never inspected here; the provider finishes it after posting it to its backend.
            updatesTask = Task { [weak self] in
                await self?.reconcile()
                guard let signals = self?.updateSignals else { return }
                for await _ in signals() {
                    guard let self else { return }
                    await self.reconcile()
                }
            }
        }

        #if canImport(UIKit)
        foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconcileNow()
        }
        #endif
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        if let token = foregroundToken {
            NotificationCenter.default.removeObserver(token)
            foregroundToken = nil
        }
        chainLock.lock()
        chain = nil
        chainLock.unlock()
    }

    // MARK: - Late purchases (SPEC-497 §13a.2, D-R40-1(a))

    /// One verified `Transaction.updates` item under `.storeKitOwned` — the ONLY place this class
    /// finishes a transaction. Revoked → its queue entry is removed, nothing emitted (Q5). Otherwise
    /// `LatePurchaseFilter.decide` classifies it: `report` → one write (reported set + queue entry) →
    /// emit → finish → drain; `deferToOwner` → owner-tagged entry → finish; `finishSilently` (renewals,
    /// family-shared, upgraded, already reported by the purchase path) → finish.
    func handleOwnedUpdate(_ transaction: Transaction) async {
        await handleOwnedUpdate(OwnedTransactionUpdate(transaction: transaction))
    }

    /// The same, on an `OwnedTransactionUpdate` — the seam a unit test drives (a `Transaction` cannot be
    /// constructed there).
    func handleOwnedUpdate(_ update: OwnedTransactionUpdate) async {
        guard mode == .storeKitOwned else { return }
        let transactionId = update.transactionId

        if update.isRevoked {
            await deliveryQueue.removeEntry(transactionId: transactionId)
            await update.finish()
            return
        }

        // While a purchase of the SAME product is in flight, do not finish its update: the purchase path
        // reports and finishes it. Re-check once that purchase has ended.
        await deliveryQueue.waitForPurchaseToEnd(productId: update.productId)

        let facts = update.facts(
            PurchaseOwnerMap.owner(of: update.appAccountToken),
            AppAccountTokenResolver.tokenForCurrentUser(),
            AppDNA.identityManagerRef?.currentIdentity.userId,
            await deliveryQueue.isReported(transactionId)
        )
        let decision = await LatePurchaseProcessor.process(
            facts: facts,
            queue: deliveryQueue,
            tracker: eventTracker
        ) {
            await update.envelope(facts)
        }
        await update.finish()
        // §17-4 — a late purchase is verified by the server like any other (in the background; never
        // awaited). A deferred one is sent as its OWNER's; a renewal (`finishSilently`) is not sent — the
        // store's server notifications carry renewals.
        if decision != .finishSilently, let jws = update.signedTransaction {
            let entry = PendingVerification(
                transactionId: transactionId,
                productId: update.productId,
                signedTransaction: jws,
                productType: facts.productType == "autoRenewable" ? "subs" : "inapp",
                appUserId: decision == .deferToOwner ? facts.ownerUserId : facts.currentUserId,
                queuedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            let queue = verificationQueue
            Task.detached { await queue.submit(entry) }
        }
        if decision == .report {
            await deliveryQueue.drain()   // trigger (i)
        }
    }

    // MARK: - Reconcile

    /// Fire-and-forget reconcile, for callers that are not `async` (the foreground notification, a
    /// provider's subscriber-state callback). Still serialized — it enqueues on the same chain.
    func reconcileNow() {
        _ = enqueueReconcile()
    }

    /// Re-derive the current subscription snapshot, diff it against the persisted one, emit, and
    /// persist. Mirrors Android `reconcileSubscriptionState()`. Serialized against every other caller.
    func reconcile() async {
        await enqueueReconcile().value
    }

    /// Append one pass to the serial chain and return it. The new pass awaits the previous one, so two
    /// triggers firing at the same instant cannot both read the pre-renewal snapshot.
    private func enqueueReconcile() -> Task<Void, Never> {
        chainLock.lock()
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performReconcile()
        }
        chain = task
        chainLock.unlock()
        return task
    }

    private func performReconcile() async {
        let current = await loadCurrent()
        let previous = loadSnapshot()
        diffAndEmit(previous: previous, current: current)
        saveSnapshot(current)
        if let afterPass {
            // Detached from the chain: the entitlement refresh may make a network call, and the next pass
            // must not wait for it. The refresh has its own serial chain.
            Task.detached { await afterPass() }
        }
    }

    /// The StoreKit half of a pass: build the current snapshot from `Transaction.currentEntitlements`.
    /// Static, because it holds no observer state — only StoreKit's.
    private static func storeKitSnapshot() async -> [String: SubSnapshot] {
        // Cross-account-leak guard, resolved ONCE per pass so the decision matrix sees a stable value
        // even if the host identifies a different user mid-iteration (same as `StoreKit2Bridge.restore`).
        let expectedToken = AppAccountTokenResolver.tokenForCurrentUser()
        let firstIdentifier = AppAccountTokenResolver.firstIdentifiedToken()

        var current: [String: SubSnapshot] = [:]
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productType == .autoRenewable else { continue }
            if transaction.revocationDate != nil { continue }

            switch EntitlementOwnerFilter.decide(
                transactionToken: transaction.appAccountToken,
                expectedToken: expectedToken,
                firstIdentifiedToken: firstIdentifier
            ) {
            case .denyOtherUser, .denyUntaggedOtherUser:
                // A renewal for user A arriving while user B is signed in is not user B's renewal.
                continue
            case .grant, .grantAnonymousPolicy, .grantUntaggedMigration:
                break
            }

            let facts = await productFacts(for: transaction.productID)
            // The CHARGED price, as `purchase_completed` reports it: `transaction.price` (StoreKit's price of
            // this period), else the product's list price; omitted when neither is known.
            var price: Double?
            if let productPrice = facts.price {
                price = chargedPrice(transactionPrice: transaction.price, productPrice: productPrice)
            } else if let transactionPrice = transaction.price {
                price = chargedPrice(transactionPrice: transactionPrice, productPrice: transactionPrice)
            }
            current[transaction.productID] = SubSnapshot(
                productId: transaction.productID,
                purchaseTime: Int64(transaction.purchaseDate.timeIntervalSince1970 * 1000),
                isAutoRenewing: facts.willAutoRenew,
                transactionId: String(transaction.id),
                originalTransactionId: String(transaction.originalID),
                price: price,
                currency: transaction.currency?.identifier ?? facts.currency
            )
        }
        return current
    }

    /// The pure diff. No I/O, no StoreKit — this is the half a unit test can drive.
    ///
    /// Event + property names are Android's, verbatim (`NativeBillingManager.diffAndEmit`): a divergent
    /// property name here would be the same silent-analytics bug in a new place. Both names are spelled
    /// out as literals at the callsite so `check:event-name-parity` can see them.
    func diffAndEmit(previous: [String: SubSnapshot], current: [String: SubSnapshot]) {
        // SPEC-497 §3.2 rule 4 — suppressed under RevenueCat (owner Q2). `saveSnapshot` still runs.
        guard emitsLifecycleEvents else { return }

        for (productId, prev) in previous where current[productId] == nil {
            // SPEC-497 §13e.5 rule 2 — the product VANISHED, so no current transaction exists: the ids
            // are the LAST-SEEN ones from the snapshot (omitted when an older snapshot has none).
            var props: [String: Any] = ["product_id": productId]
            Self.addIds(prev, to: &props)
            if prev.isAutoRenewing {
                eventTracker.track(event: "subscription_renewal_failed", properties: BillingEventProps.marked(props))
            } else {
                // Churn semantics (SDK minor 17): a device cancel means "vanished while not
                // auto-renewing"; a provider cancel means "auto-renew turned off".
                props["cancel_semantics"] = "vanished_not_renewing"
                eventTracker.track(event: "subscription_canceled", properties: BillingEventProps.marked(props))
            }
        }

        for (productId, now) in current {
            guard let prev = previous[productId] else { continue } // new product = purchase, not renewal
            if now.purchaseTime > prev.purchaseTime {
                var props: [String: Any] = [
                    "product_id": productId,
                    "purchase_time": now.purchaseTime,
                ]
                Self.addIds(now, to: &props)   // the CURRENT ids
                // §17-5 — the renewal's revenue, under `purchase_completed`'s names. Both or neither: a price
                // without a currency is not revenue anyone can convert.
                if let price = now.price, let currency = now.currency, !currency.isEmpty {
                    props["price"] = price
                    props["currency"] = currency
                }
                eventTracker.track(event: "subscription_renewed", properties: BillingEventProps.marked(props))
            }
        }
    }

    private static func addIds(_ snapshot: SubSnapshot, to props: inout [String: Any]) {
        if let id = snapshot.transactionId, !id.isEmpty { props["transaction_id"] = id }
        if let original = snapshot.originalTransactionId, !original.isEmpty {
            props["original_transaction_id"] = original
        }
    }

    // MARK: - Auto-renew status

    /// Whether Apple will auto-renew this subscription — the same signal Play exposes as
    /// `Purchase.isAutoRenewing`, and the one that decides `renewal_failed` vs `canceled` when the
    /// product later vanishes. Unknown (offline, unresolvable product) defaults to `true`, which is what
    /// an active subscription normally is; the alternative would mis-label a billing-retry as a
    /// deliberate cancel.
    ///
    /// The same product lookup also yields the list price and currency (the renewal price's fallback).
    private static func productFacts(for productID: String) async -> (willAutoRenew: Bool, price: Decimal?, currency: String?) {
        do {
            let products = try await Product.products(for: [productID])
            let product = products.first
            let price = product?.price
            let currency = product?.priceFormatStyle.currencyCode
            guard let subscription = product?.subscription else { return (true, price, currency) }
            let statuses = try await subscription.status
            guard let status = statuses.first,
                  case .verified(let renewalInfo) = status.renewalInfo else { return (true, price, currency) }
            return (renewalInfo.willAutoRenew, price, currency)
        } catch {
            Log.debug("SubscriptionStatusObserver: could not resolve auto-renew status for \(productID): \(error)")
            return (true, nil, nil)
        }
    }

    // MARK: - Persistence

    func loadSnapshot() -> [String: SubSnapshot] {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SubSnapshot].self, from: data)) ?? [:]
    }

    func saveSnapshot(_ snapshot: [String: SubSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    /// Clear the persisted subscription snapshot. MUST be called on any identity change — sign-out
    /// (`reset()`) and sign-in to a DIFFERENT user (`identify()`). The snapshot is device-global but the
    /// reconcile filters entitlements to the currently-identified user. Without clearing, user B's first
    /// reconcile after A signs out diffs B's (filtered) entitlements against A's snapshot, sees A's
    /// product "vanish", and fabricates a phantom `subscription_canceled` / `subscription_renewal_failed`
    /// in B's session — corrupting churn/renewal analytics on every account switch. A fresh (empty)
    /// snapshot makes the next reconcile establish a clean baseline and emit nothing.
    static func clearPersistedSnapshot() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }
}
