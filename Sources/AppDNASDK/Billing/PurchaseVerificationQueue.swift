import Foundation

/// One App Store transaction waiting for server verification.
struct PendingVerification: Codable, Equatable {
    let transactionId: String
    let productId: String
    /// The signed transaction (`VerificationResult.jwsRepresentation`) — what `/billing/verify` takes.
    let signedTransaction: String
    /// `"subs"` / `"inapp"`.
    let productType: String?
    /// The user the purchase belongs to, captured when it was queued (a later retry must not send the
    /// purchase as whoever is signed in by then). Nil = anonymous.
    let appUserId: String?
    /// Epoch milliseconds.
    let queuedAt: Int64
    var attempts: Int = 0
}

/// Server verification of StoreKit 2 purchases — the iOS half of what Android's `PurchaseCompletion`
/// does with `/billing/verify`.
///
/// Before: `ReceiptVerifier` was never constructed, so an iOS purchase made through the SDK never reached
/// `/billing/verify`; the server learned of it only from App Store Server Notifications, if those were set
/// up at all.
///
/// Now every purchase the SDK owns (`billingProvider: .storeKit2`) — a completed `purchase()`, a late
/// purchase from `Transaction.updates` (interrupted / Ask-to-Buy / offer code) and every transaction a
/// restore grants — is queued here and sent to `/billing/verify` in the background:
///   - **Never on the purchase's critical path.** `submit` persists and returns; the network call runs
///     after. A verification failure never fails, delays or reverses the purchase — StoreKit already
///     verified the transaction locally, and the host was already told.
///   - **Durable.** The entry is written to UserDefaults BEFORE the first attempt, so a crash or an offline
///     launch loses nothing. A retryable failure (network, 401, 429, 5xx, unreadable reply) keeps the
///     entry for the next `retryPending()` — each `configure`, each foreground and each `Transaction.updates`
///     pass; a terminal one (any other 4xx, e.g. 422 `store_credentials_missing`, 409 `provider_owned`) is
///     logged and dropped.
///   - Bounded: 50 entries (oldest dropped), 30 days, 10 attempts.
///
/// It is a separate store from `PurchaseDeliveryQueue` on purpose: that queue's entries leave when the
/// host's DELEGATE has the purchase, these when the SERVER has it — two consumers, two lifetimes.
actor PurchaseVerificationQueue {

    static let shared = PurchaseVerificationQueue()

    static let storageKey = "appdna.pending_verifications_v1"
    static let cap = 50
    static let maxAttempts = 10
    static let maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    struct Environment {
        var defaults: UserDefaults
        var now: () -> Date
        /// The verifier to send with, or nil while the SDK has no API client (before `configure`) — the
        /// entry then stays queued.
        var verifier: () -> ReceiptVerifier?

        static var production: Environment {
            Environment(
                defaults: .standard,
                now: Date.init,
                verifier: { AppDNA.billingAPIClient.map { ReceiptVerifier(apiClient: $0) } }
            )
        }
    }

    private var env: Environment
    private var sending: Set<String> = []

    init(environment: Environment = .production) {
        self.env = environment
    }

    func setEnvironmentForTesting(_ environment: Environment) {
        env = environment
    }

    // MARK: - API

    /// Queue one transaction and try to send it. Returns when the attempt is over; callers on a purchase
    /// path call it from a detached `Task` so the purchase never waits for it.
    func submit(_ entry: PendingVerification) async {
        var entries = load()
        if !entries.contains(where: { $0.transactionId == entry.transactionId }) {
            entries.append(entry)
            if entries.count > Self.cap {
                let dropped = entries.prefix(entries.count - Self.cap).map(\.transactionId)
                entries.removeFirst(entries.count - Self.cap)
                Log.warning("PurchaseVerificationQueue: over \(Self.cap) unverified purchases — dropped the oldest \(dropped).")
            }
            save(entries)
        }
        await send(transactionId: entry.transactionId)
    }

    /// Retry every queued entry once (configure, foreground, `Transaction.updates`).
    func retryPending() async {
        purge()
        for id in load().map(\.transactionId) {
            await send(transactionId: id)
        }
    }

    /// The queued transaction ids (tests, diagnostics).
    func pendingIds() -> [String] {
        load().map(\.transactionId)
    }

    // MARK: - Send

    private func send(transactionId: String) async {
        guard !sending.contains(transactionId) else { return }
        guard let entry = load().first(where: { $0.transactionId == transactionId }) else { return }
        guard let verifier = env.verifier() else { return }   // not configured yet — stays queued
        sending.insert(transactionId)
        defer { sending.remove(transactionId) }
        do {
            let reply = try await verifier.verify(
                signedTransaction: entry.signedTransaction,
                productType: entry.productType,
                billingOwner: "sdk",
                appUserId: entry.appUserId
            )
            remove(transactionId)
            Log.debug("PurchaseVerificationQueue: \(transactionId) verified (entitled: \(reply.entitled), status: \(reply.status), environment: \(reply.environment ?? "-"))")
        } catch {
            switch VerifyFailureClass.classify(error) {
            case .terminal:
                remove(transactionId)
                Log.warning("PurchaseVerificationQueue: the server refused to verify \(transactionId) (\(error.localizedDescription)) — not retried. The purchase itself is unaffected.")
            case .retryable:
                var entries = load()
                guard let index = entries.firstIndex(where: { $0.transactionId == transactionId }) else { return }
                entries[index].attempts += 1
                if entries[index].attempts >= Self.maxAttempts {
                    entries.remove(at: index)
                    Log.warning("PurchaseVerificationQueue: gave up verifying \(transactionId) after \(Self.maxAttempts) attempts (\(error.localizedDescription)).")
                } else {
                    Log.info("PurchaseVerificationQueue: could not verify \(transactionId) yet (\(error.localizedDescription)) — will retry.")
                }
                save(entries)
            }
        }
    }

    // MARK: - Storage

    private func remove(_ transactionId: String) {
        var entries = load()
        entries.removeAll { $0.transactionId == transactionId }
        save(entries)
    }

    private func purge() {
        let cutoff = Int64(env.now().timeIntervalSince1970 * 1000) - Self.maxAgeMs
        var entries = load()
        let before = entries.count
        entries.removeAll { $0.queuedAt > 0 && $0.queuedAt < cutoff }
        if entries.count != before {
            Log.warning("PurchaseVerificationQueue: dropped \(before - entries.count) unverified purchase(s) older than 30 days.")
            save(entries)
        }
    }

    private func load() -> [PendingVerification] {
        guard let data = env.defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([PendingVerification].self, from: data)
        } catch {
            // Never silently treat an unreadable store as empty: keep a copy before the next write replaces it.
            CorruptStore.preserve(data, key: Self.storageKey, defaults: env.defaults, error: error)
            return []
        }
    }

    private func save(_ entries: [PendingVerification]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            Log.error("PurchaseVerificationQueue: could not encode the verification store")
            return
        }
        env.defaults.set(data, forKey: Self.storageKey)
    }
}

/// An undecodable persisted store is LOGGED and COPIED before the caller carries on with an empty one —
/// which its next write persists over the original. Without the copy the undelivered purchases in it were
/// lost without a trace.
///
/// Each copy is timestamped, `<key>.corrupt.<epoch-ms>`, and at most `maxCopies` are kept per key: the
/// oldest is removed when a fourth arrives. (There used to be one `<key>.corrupt`, so a second unreadable
/// payload overwrote the first.) A payload equal to the newest copy is not copied again. The copy keys,
/// oldest first, are listed under `<key>.corrupt.index`.
enum CorruptStore {
    static let maxCopies = 3

    static func indexKey(for key: String) -> String { key + ".corrupt.index" }

    /// The keys of the copies kept for `key`, oldest first.
    static func copyKeys(for key: String, defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: indexKey(for: key)) ?? []
    }

    static func preserve(_ data: Data, key: String, defaults: UserDefaults, error: Error, now: Date = Date()) {
        var copies = copyKeys(for: key, defaults: defaults)
        let copyKey: String
        if let newest = copies.last, defaults.data(forKey: newest) == data {
            copyKey = newest
        } else {
            var stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())
            // Two copies in the same millisecond still get distinct keys.
            while copies.contains("\(key).corrupt.\(stamp)") { stamp += 1 }
            copyKey = "\(key).corrupt.\(stamp)"
            defaults.set(data, forKey: copyKey)
            copies.append(copyKey)
            while copies.count > maxCopies {
                defaults.removeObject(forKey: copies.removeFirst())
            }
            defaults.set(copies, forKey: indexKey(for: key))
        }
        Log.error("AppDNA: the persisted store '\(key)' could not be decoded (\(error.localizedDescription)); a copy of the \(data.count)-byte payload was kept under '\(copyKey)' (the newest \(maxCopies) copies are kept) and the store starts empty.")
    }
}
