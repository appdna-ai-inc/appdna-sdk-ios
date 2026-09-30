import Foundation

// SPEC-497 §13a.2, D-R40-1 (b)+(c) — the durable delivery queue for `onPurchaseCompleted`.
//
// The model (the same rules as Android's `drainDeliveries`, R41/R60/R61):
//   1. What is queued: every report that did NOT resolve a live `purchase()` caller. On iOS that is the
//      late purchases of `Transaction.updates` (interrupted, Ask-to-Buy, offer codes) — `report` and
//      `deferToOwner`. A purchase whose caller is alive is delivered by its bridge, as before.
//   2. One write (Q1): the reported set and the queue entry are persisted in ONE UserDefaults write, and
//      the event is emitted after it. The queue entry is the only "not yet delivered" marker.
//   3. One delivery path (Q2): a queued report is delivered only by `drain()`.
//   4. Identity: a tagged entry goes only to the identity whose derived token equals its `ownerToken`;
//      an untagged one to an anonymous user or the device's first-identified user. `reset()` never
//      delivers across identities.
//   5. The drain (Q3): entry by entry — mark in-flight, call the delegate on the main actor, then remove
//      it (delivered = the delegate was non-nil). One pass over a snapshot of the queued ids.
//   6. Triggers: (i) after a report, (ii) a delivering delegate is set, (iii) `identify` completed,
//      (iv) the end of billing initialisation in `configure`. A drain is a no-op until `configure` has
//      activated the queue.
//   Cap 100 entries (oldest dropped, logged), purged after 30 days. Delivery is at-least-once: a crash
//   between the callback and the removal re-delivers once — hosts grant idempotently by `transactionId`.

/// One queued report. iOS keys and dedupes by the transaction id.
struct PendingDelivery: Codable {
    let transactionId: String
    let productId: String
    /// Epoch milliseconds.
    let purchaseTime: Int64
    var quantity: Int = 1
    /// The derived token (lowercase UUID) of the identity this entry belongs to; nil = untagged.
    let ownerToken: String?
    var queuedAt: Int64 = 0
    /// `deferToOwner`: the event has not been emitted yet — the drain emits it from `properties` when the
    /// owner identifies.
    var emitPending: Bool
    /// The stored `purchase_completed` envelope of a deferred entry.
    let properties: [String: AnyCodable]?
    let isSubscription: Bool

    init(
        transactionId: String,
        productId: String,
        purchaseTime: Int64,
        quantity: Int = 1,
        ownerToken: String?,
        queuedAt: Int64 = 0,
        emitPending: Bool,
        properties: [String: AnyCodable]?,
        isSubscription: Bool
    ) {
        self.transactionId = transactionId
        self.productId = productId
        self.purchaseTime = purchaseTime
        self.quantity = quantity
        self.ownerToken = ownerToken
        self.queuedAt = queuedAt
        self.emitPending = emitPending
        self.properties = properties
        self.isSubscription = isSubscription
    }
}

/// What is persisted under `appdna.pending_deliveries_v1`: the reported set AND the queue, so a report is
/// one write (Q1).
struct DeliveryStore: Codable {
    /// Transaction ids for which `purchase_completed` was emitted (purchase path or late path). Bounded,
    /// oldest evicted.
    var reported: [String] = []
    var entries: [PendingDelivery] = []
}

actor PurchaseDeliveryQueue {

    static let shared = PurchaseDeliveryQueue()

    static let storageKey = "appdna.pending_deliveries_v1"
    static let reportedCap = 500
    static let queueCap = 100
    static let maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// Everything the queue reads from outside. Production: `UserDefaults.standard`, the resolver, the
    /// billing module's delivering-delegate snapshot and its tracker. Tests inject their own.
    struct Environment {
        var defaults: UserDefaults
        var now: () -> Date
        var currentToken: () -> UUID?
        var firstIdentifiedToken: () -> UUID?
        /// The delegate the drain may call — nil unless one is set AND it delivers purchases. Called on
        /// the main actor, in the same turn as the delegate call.
        var deliveringDelegate: @MainActor () -> AppDNABillingDelegate?
        var tracker: () -> EventTracker?

        static var production: Environment {
            Environment(
                defaults: .standard,
                now: Date.init,
                currentToken: { AppAccountTokenResolver.tokenForCurrentUser() },
                firstIdentifiedToken: { AppAccountTokenResolver.firstIdentifiedToken() },
                deliveringDelegate: { AppDNA.billing.deliveringDelegate() },
                tracker: { AppDNA.billing.eventTracker }
            )
        }
    }

    private var env: Environment
    private var active = false
    private var activeSession = 0
    /// The newest configure epoch a `shutdown()` has deactivated. An `activate(session:)` for that epoch
    /// or an older one is ignored, so activate/deactivate cannot reorder across `shutdown()`: a
    /// `configure()` whose activation Task runs AFTER the `shutdown()` that ended it stays inactive.
    private var deactivatedThrough = 0
    /// The in-memory copy of the persisted store, loaded on first use. Dropped on every `activate` and
    /// `deactivate`, so each `configure()` starts from what is PERSISTED — an in-process restart
    /// (`shutdown()` → `configure()`) must see exactly what a cold launch would. Keeping it across the
    /// restart let a store that had since been cleared (a host wiping its defaults on sign-out) come back
    /// from memory: its reported ids silenced the next late purchase with a matching id —
    /// `finishSilently`, no `purchase_completed`, no queue entry — and the next write persisted it again.
    private var cached: DeliveryStore?
    /// Entries a drain is delivering right now (two concurrent drains deliver an entry once).
    private var inFlight: Set<String> = []
    /// Products with a purchase-path purchase in flight (the observer must not finish their updates).
    private var purchasesInFlight: [String: Int] = [:]
    private var purchaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(environment: Environment = .production) {
        self.env = environment
    }

    // MARK: - Lifecycle

    /// Called by `configure` once the identity is loaded (trigger (iv) follows). Until then `drain()` is a
    /// no-op. `session` is the configure epoch: an epoch a `shutdown()` already deactivated never
    /// activates (the two Tasks can run in either order). `nil` (tests) activates unconditionally.
    func activate(session: Int? = nil, environment: Environment? = nil) {
        if let environment { env = environment; cached = nil }
        if let session {
            guard session > deactivatedThrough else { return }
            activeSession = max(activeSession, session)
        }
        cached = nil          // this configure reads the PERSISTED store, never a previous run's memory
        active = true
        _ = purgeAndSave()
    }

    /// `shutdown()`: drains become no-ops again until the next `configure` — unless a newer session was
    /// already activated (`shutdown(); configure()` on one tick). `nil` (tests) deactivates unconditionally.
    func deactivate(session: Int? = nil) {
        guard let session else { active = false; cached = nil; return }
        deactivatedThrough = max(deactivatedThrough, session)
        guard session >= activeSession else { return }
        active = false
        cached = nil
    }

    /// Tests: swap the environment without activating.
    func setEnvironmentForTesting(_ environment: Environment) {
        env = environment
        cached = nil
    }

    var isActive: Bool { active }

    // MARK: - Reported set

    func isReported(_ transactionId: String) -> Bool {
        load().reported.contains(transactionId)
    }

    /// The purchase path writes the transaction id BEFORE `finish()` so the observer never re-reports it.
    func markReported(_ transactionId: String) {
        var store = load()
        addReported(transactionId, to: &store)
        save(store)
    }

    // MARK: - Writes

    /// `report` — the reported set and the queue entry in ONE write (Q1).
    func recordReport(_ entry: PendingDelivery) {
        var store = load()
        addReported(entry.transactionId, to: &store)
        enqueue(entry, into: &store)
        save(store)
    }

    /// `deferToOwner` — an owner-tagged entry whose emit is pending (not in the reported set yet).
    func recordDeferred(_ entry: PendingDelivery) {
        var store = load()
        enqueue(entry, into: &store)
        save(store)
    }

    /// Q5 — a revoked transaction leaves the queue (tagged, untagged or deferred) and emits nothing.
    func removeEntry(transactionId: String) {
        var store = load()
        let before = store.entries.count
        store.entries.removeAll { $0.transactionId == transactionId }
        if store.entries.count != before { save(store) }
    }

    /// One queued entry (tests, diagnostics).
    func entry(transactionId: String) -> PendingDelivery? {
        load().entries.first { $0.transactionId == transactionId }
    }

    /// The queued ids, in queue order (tests, diagnostics).
    func queuedIds() -> [String] {
        load().entries.map(\.transactionId)
    }

    // MARK: - Purchase-path in-flight tracking

    func beginPurchase(productId: String) {
        purchasesInFlight[productId, default: 0] += 1
    }

    func endPurchase(productId: String) {
        let remaining = (purchasesInFlight[productId] ?? 1) - 1
        if remaining > 0 {
            purchasesInFlight[productId] = remaining
            return
        }
        purchasesInFlight.removeValue(forKey: productId)
        let waiters = purchaseWaiters.removeValue(forKey: productId) ?? []
        waiters.forEach { $0.resume() }
    }

    func isPurchaseInFlight(productId: String) -> Bool {
        (purchasesInFlight[productId] ?? 0) > 0
    }

    /// The observer does not finish an update while a purchase of the same product is in flight; it
    /// waits here and re-checks once that purchase has ended.
    func waitForPurchaseToEnd(productId: String) async {
        guard isPurchaseInFlight(productId: productId) else { return }
        await withCheckedContinuation { continuation in
            purchaseWaiters[productId, default: []].append(continuation)
        }
    }

    // MARK: - Drain

    /// One pass over a snapshot of the queued ids. Returns the ids delivered in this pass.
    @discardableResult
    func drain() async -> [String] {
        guard active else { return [] }
        var delivered: [String] = []
        let snapshot = load().entries.map(\.transactionId)
        for id in snapshot {
            guard active else { break }
            // (a) lock (actor), skip in-flight, check the entry is still queued and deliverable.
            guard !inFlight.contains(id) else { continue }
            let store = load()
            guard let index = store.entries.firstIndex(where: { $0.transactionId == id }) else { continue }
            let entry = store.entries[index]
            guard isDeliverable(entry) else { continue }
            inFlight.insert(id)

            // Deferred emit (R46 (2)), from the stored envelope — regardless of the delegate. With no
            // tracker yet the entry is left untouched (emit still pending, not delivered ahead of it).
            // With one: persist `emitPending = false` and the reported id in ONE write, THEN emit, in the
            // same actor turn — at most once, never a double emit after a crash.
            if entry.emitPending {
                guard let tracker = env.tracker() else {
                    inFlight.remove(id)
                    continue          // stays queued with its emit pending; a later drain emits it
                }
                var after = store
                after.entries[index].emitPending = false
                let alreadyReported = after.reported.contains(id)
                addReported(id, to: &after)
                save(after)
                if !alreadyReported, let props = entry.properties {
                    PurchaseSuccessEvents.emit(
                        tracker: tracker,
                        properties: props.mapValues(\.value),
                        isSubscription: entry.isSubscription
                    )
                }
            }

            // (b) re-read the delegate and call it on the main actor, in the same turn — and re-check the
            // identity there too: an `identify` / `reset` that landed while this drain was suspended must
            // not receive another identity's purchase.
            let provider = env.deliveringDelegate
            let currentToken = env.currentToken
            let firstIdentifiedToken = env.firstIdentifiedToken
            let ownerToken = entry.ownerToken
            let info = TransactionInfo(
                transactionId: entry.transactionId,
                productId: entry.productId,
                purchaseDate: Date(timeIntervalSince1970: TimeInterval(entry.purchaseTime) / 1000),
                environment: "production"
            )
            let didDeliver: Bool = await MainActor.run {
                guard Self.isDeliverable(
                    ownerToken: ownerToken,
                    current: currentToken(),
                    firstIdentified: firstIdentifiedToken()
                ) else { return false }
                guard let delegate = provider() else { return false }
                delegate.onPurchaseCompleted(productId: entry.productId, transaction: info)
                return true
            }

            // (c) lock again: delivered → remove; otherwise it stays queued (not revisited this pass).
            inFlight.remove(id)
            if didDeliver {
                var after = load()
                after.entries.removeAll { $0.transactionId == id }
                save(after)
                delivered.append(id)
            }
        }
        return delivered
    }

    /// Queue rule 4 (EntitlementOwnerFilter semantics).
    private func isDeliverable(_ entry: PendingDelivery) -> Bool {
        Self.isDeliverable(ownerToken: entry.ownerToken, current: env.currentToken(), firstIdentified: env.firstIdentifiedToken())
    }

    /// Queue rule 4, pure: a tagged entry goes only to the identity whose derived token equals its owner
    /// token; an untagged one to an anonymous user or the device's first-identified user.
    static func isDeliverable(ownerToken: String?, current: UUID?, firstIdentified: UUID?) -> Bool {
        if let owner = ownerToken {
            guard let current else { return false }   // an anonymous identity never gets a tagged entry
            return current.uuidString.lowercased() == owner.lowercased()
        }
        guard let current else { return true }        // untagged → anonymous user
        return firstIdentified == current              // … or the device's first-identified user
    }

    // MARK: - Storage

    private func load() -> DeliveryStore {
        if let cached { return cached }
        var store = DeliveryStore()
        if let data = env.defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(DeliveryStore.self, from: data) {
            store = decoded
        }
        cached = store
        return store
    }

    private func save(_ store: DeliveryStore) {
        cached = store
        guard let data = try? JSONEncoder().encode(store) else {
            Log.error("PurchaseDeliveryQueue: could not encode the delivery store")
            return
        }
        env.defaults.set(data, forKey: Self.storageKey)
    }

    private func addReported(_ id: String, to store: inout DeliveryStore) {
        guard !store.reported.contains(id) else { return }
        store.reported.append(id)
        if store.reported.count > Self.reportedCap {
            store.reported.removeFirst(store.reported.count - Self.reportedCap)
        }
    }

    private func enqueue(_ entry: PendingDelivery, into store: inout DeliveryStore) {
        guard !store.entries.contains(where: { $0.transactionId == entry.transactionId }) else { return }
        var stamped = entry
        stamped.queuedAt = nowMs()
        store.entries.append(stamped)
        if store.entries.count > Self.queueCap {
            let dropped = store.entries.count - Self.queueCap
            let ids = store.entries.prefix(dropped).map(\.transactionId)
            store.entries.removeFirst(dropped)
            Log.warning("PurchaseDeliveryQueue: over \(Self.queueCap) undelivered purchases — dropped the oldest \(ids). Grant them from the dashboard.")
        }
    }

    private func purgeAndSave() -> Int {
        var store = load()
        let cutoff = nowMs() - Self.maxAgeMs
        let before = store.entries.count
        store.entries.removeAll { $0.queuedAt > 0 && $0.queuedAt < cutoff }
        let purged = before - store.entries.count
        if purged > 0 {
            Log.warning("PurchaseDeliveryQueue: purged \(purged) undelivered purchase(s) older than 30 days.")
            save(store)
        }
        return purged
    }

    private func nowMs() -> Int64 {
        Int64((env.now().timeIntervalSince1970 * 1000).rounded())
    }
}

/// SPEC-497 §13a.2 (R47–R50) — which user made the purchase that carried a given `appAccountToken`.
///
/// The purchase path records the token of EVERY purchase — SDK-derived or a host's custom
/// `PurchaseOptions.appAccountToken` — BEFORE the StoreKit purchase call, whatever the outcome (pending and
/// cancelled included). One device-wide map (500 entries, oldest evicted), never cleared by `reset()` or
/// `identify`. A purchase made while anonymous is not recorded (there is no user id). The late filter
/// resolves a transaction's owner through it.
enum PurchaseOwnerMap {
    static let storageKey = "appdna.purchase_owner_map_v1"
    static let cap = 500

    private struct Entry: Codable {
        let token: String
        let userId: String
    }

    private static let lock = NSLock()

    static func record(token: UUID, userId: String?, defaults: UserDefaults = .standard) {
        guard let userId, !userId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var entries = load(defaults)
        let key = token.uuidString.lowercased()
        entries.removeAll { $0.token == key }
        entries.append(Entry(token: key, userId: userId))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func owner(of token: UUID?, defaults: UserDefaults = .standard) -> String? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = token.uuidString.lowercased()
        return load(defaults).last(where: { $0.token == key })?.userId
    }

    /// The helper both purchase paths call right before `bridge.purchase(...)`.
    static func recordBeforePurchase(token: UUID?) {
        guard let token else { return }
        record(token: token, userId: AppDNA.identityManagerRef?.currentIdentity.userId)
    }

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }
}
