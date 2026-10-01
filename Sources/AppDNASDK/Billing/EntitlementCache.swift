import Foundation
import FirebaseFirestore

/// Caches entitlements locally and listens to Firestore for real-time updates.
class EntitlementCache {
    // Round-10 #10 — the Firestore snapshot callback and StoreKit `update()` mutate this cache from
    // different threads; the old in-place mutation of `entitlements` + append-while-iterating over
    // `changeHandlers` raced. All access to the two mutable stores now goes through `lock`. Handlers are
    // ALWAYS invoked OUTSIDE the lock (snapshot under lock, call out after) so a host callback that
    // re-enters the cache can't deadlock. Android uses CopyOnWriteArrayList + immutable-list swap.
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    private var _entitlements: [ServerEntitlement] = []
    private var _changeHandlers: [([ServerEntitlement]) -> Void] = []

    private(set) var entitlements: [ServerEntitlement] {
        get { locked { _entitlements } }
        set { locked { _entitlements = newValue } }
    }
    private var firestoreListener: ListenerRegistration?

    private let userDefaultsKey = "com.appdna.entitlements"

    // Round-10 #11 — remove the Firestore snapshot listener when the cache is deallocated (e.g. on
    // re-configure), mirroring the sibling WebEntitlementManager's teardown. Without this the old
    // listener leaked on every re-create.
    deinit {
        firestoreListener?.remove()
    }

    /// The single set of statuses that count as "entitled". Used by BOTH the global check and the
    /// per-product lookup so they can't disagree — matches Android's one `ACTIVE_STATUSES`. Previously
    /// `hasActiveSubscription` included `grace_period` but `entitlement(for:)` did not, so a grace-period
    /// subscriber reported subscribed globally yet had every per-product feature locked.
    /// `billing_retry` counts as entitled, as on the server (`entitlement.ts`) and on Android: Apple keeps
    /// access through billing retry (with its grace period) until the retry ends.
    static let activeStatuses: Set<String> = ["active", "trialing", "grace_period", "billing_retry"]

    /// The entitled statuses whose period end has ALREADY passed by definition: Apple keeps the access
    /// after `expirationDate` while it retries the payment, and the server writes these rows with a past
    /// `current_period_end`. An expiry check never applies to them (server `isEntitled` returns true for
    /// every active status; Android reads the status alone).
    static let pastExpiryStatuses: Set<String> = ["grace_period", "billing_retry"]

    var hasActiveSubscription: Bool {
        entitlements.contains { Self.activeStatuses.contains($0.status) }
    }

    func entitlement(for productId: String) -> ServerEntitlement? {
        entitlements.first { $0.productId == productId && Self.activeStatuses.contains($0.status) }
    }

    func update(_ entitlement: ServerEntitlement) {
        // Atomic read-modify-write under the lock (not two separate locked ops).
        locked {
            if let index = _entitlements.firstIndex(where: { $0.productId == entitlement.productId }) {
                _entitlements[index] = entitlement
            } else {
                _entitlements.append(entitlement)
            }
        }
        persistLocally()
        notifyHandlers()
    }

    func startObserving(orgId: String, appId: String, userId: String) {
        let path = "orgs/\(orgId)/apps/\(appId)/users/\(userId)/entitlements/current"
        guard let db = AppDNA.firestoreDB else { return }
        firestoreListener = db.document(path)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let data = snapshot?.data() else { return }
                self.parseFirestoreData(data)
                self.notifyHandlers()
            }
    }

    func stopObserving() {
        firestoreListener?.remove()
        firestoreListener = nil
    }

    func onEntitlementsChanged(_ handler: @escaping ([ServerEntitlement]) -> Void) {
        locked { _changeHandlers.append(handler) }
    }

    func persistLocally() {
        if let data = try? JSONEncoder().encode(entitlements) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func loadFromLocalCache() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let cached = try? JSONDecoder().decode([ServerEntitlement].self, from: data) {
            entitlements = cached
        }
    }

    private func parseFirestoreData(_ data: [String: Any]) {
        guard let subscriptions = data["subscriptions"] as? [[String: Any]] else { return }

        entitlements = subscriptions.compactMap { sub in
            guard let productId = sub["product_id"] as? String,
                  let store = sub["store"] as? String,
                  let status = sub["status"] as? String else { return nil }

            return ServerEntitlement(
                productId: productId,
                store: store,
                status: status,
                expiresAt: sub["expires_at"] as? String,
                isTrial: sub["is_trial"] as? Bool ?? false,
                offerType: sub["offer_type"] as? String
            )
        }
        persistLocally()
    }

    private func notifyHandlers() {
        // Snapshot state + handlers under the lock, then call OUT after releasing it — a host handler
        // that re-enters the cache (e.g. reads hasActiveSubscription) must not deadlock.
        let (current, handlers) = locked { (_entitlements, _changeHandlers) }
        for handler in handlers {
            handler(current)
        }
        NotificationCenter.default.post(name: .entitlementsChanged, object: nil, userInfo: ["entitlements": current])
    }
}

extension Notification.Name {
    static let entitlementsChanged = Notification.Name("com.appdna.entitlementsChanged")
}
