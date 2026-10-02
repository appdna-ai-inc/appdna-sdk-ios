import Foundation
import UIKit
import StoreKit

// MARK: - Module Namespaces (v1.0)
// Provides `AppDNA.push.*`, `AppDNA.billing.*`, `AppDNA.onboarding.*`, etc.

extension AppDNA {

    // MARK: - Push Module

    /// Push notification module namespace.
    public final class PushModule: @unchecked Sendable {
        internal weak var manager: PushTokenManager?

        init(manager: PushTokenManager?) {
            self.manager = manager
        }

        /// Request push notification permission and register for remote notifications.
        @discardableResult
        public func requestPermission() async -> Bool {
            return await AppDNA.registerForPush()
        }

        /// Get the current push token string (hex-encoded).
        public var token: String? {
            manager?.currentTokenString
        }

        /// Get the current push token (spec-compliant method form).
        public func getToken() -> String? {
            return manager?.currentTokenString
        }

        /// Set a delegate for push notification events.
        public func setDelegate(_ delegate: AppDNAPushDelegate?) {
            AppDNA.pushDelegate = delegate
        }
    }

    // MARK: - Billing Module

    /// Billing module namespace.
    /// Delegates to the configured `BillingBridgeProtocol` (StoreKit2, RevenueCat, or Adapty).
    public final class BillingModule: @unchecked Sendable {
        /// 🔴 THE ONLY **STRONG** FACADE REFERENCE IN THE SDK — AND IT IS THE ONE THAT SPENDS MONEY.
        ///
        /// Every other module facade holds its manager `weak` (`PushModule.manager`,
        /// `SurveysModule.manager`, …), so when `shutdown()` nils `shared.<manager>` the facade's
        /// reference dies with it. This one was `internal var` — STRONG — so `shutdown()`'s
        /// `shared.billingBridge = nil` dropped only the SDK's copy and left the FACADE holding the
        /// bridge alive.
        ///
        /// Consequence: after `AppDNA.shutdown()`, `AppDNA.billing.purchase(...)` sailed past its
        /// `guard let bridge` and **executed a real StoreKit purchase** — charging the user — while
        /// `shared.eventTracker` was already nil, so the purchase was never reported to anyone.
        /// A host calling `shutdown()` on sign-out could still bill the signed-out user, silently.
        ///
        /// `subsystemsUp()` could not see it: it had no `billing` key, and read `shared.*` anyway —
        /// the shadow copy, not the variable the host actually calls through. The oracle and the bug
        /// were on opposite sides of the same name. `teardown()` below is what `shutdown()` now calls,
        /// and `isLive` is what `subsystemsUp()` now reads: both look at THIS object.
        internal var bridge: BillingBridgeProtocol? {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _bridge }
            set { stateLock.lock(); _bridge = newValue; stateLock.unlock() }
        }

        /// Guards `bridge`, `ownershipPolicy` and `configured`: `configure` writes them on the SDK queue,
        /// `shutdown()` on its teardown, and `purchase` / `restore` read them from any thread.
        private let stateLock = NSLock()
        private var _bridge: BillingBridgeProtocol?
        private var _ownershipPolicy: BillingOwnershipPolicy = BillingOwnership.unavailable
        private var _configured = false

        /// One consistent read of the four (a `purchase` must not see a bridge from one configure and a
        /// policy from another). The tracker is read under the SAME lock hold as `configured`: `wire` sets
        /// both and `teardown()` clears both in one hold, so a snapshot with `configured == false` has a
        /// nil tracker unless one was injected directly (tests). The returned tracker is a strong pin.
        private func snapshot() -> (configured: Bool, bridge: BillingBridgeProtocol?, policy: BillingOwnershipPolicy, tracker: EventTracker?) {
            stateLock.lock(); defer { stateLock.unlock() }
            return (_configured, _bridge, _ownershipPolicy, _eventTracker)
        }

        /// The tracker this facade emits purchase events with. Weak: `shared` owns it.
        ///
        /// A direct `AppDNA.billing.purchase(...)` — which is exactly what the React Native and Flutter
        /// wrappers call, and what any host with a JS/Dart-authored paywall calls — emitted NOTHING.
        /// See `purchase(_:options:)`.
        ///
        /// Under `stateLock` (impl audit round 2, I7): `wire` / `teardown` write it on the SDK queue while
        /// `purchase` and the delivery queue's drain read it from any thread.
        internal var eventTracker: EventTracker? {
            get { stateLock.lock(); defer { stateLock.unlock() }; return _eventTracker }
            set { stateLock.lock(); _eventTracker = newValue; stateLock.unlock() }
        }
        private weak var _eventTracker: EventTracker?

        /// Is billing actually usable right now? Read by `subsystemsUp()` so the diagnostic and the
        /// host see the same object.
        internal var isLive: Bool { bridge != nil }

        /// SPEC-497 §3.2 — the ownership policy `configure` chose (`BillingOwnership.policy`).
        internal var ownershipPolicy: BillingOwnershipPolicy {
            stateLock.lock(); defer { stateLock.unlock() }; return _ownershipPolicy
        }

        /// SPEC-497 §3.2 rule 3 (D-R39-1, R65–R67) — has `configure` wired billing yet? Until it has,
        /// `purchase` / `restore` fail with an `unknown` "not configured yet" error; once configured with no
        /// bridge (`none`) they throw `providerNotAvailable`. Reset by `teardown()`, so after `shutdown()`
        /// the not-configured error applies again.
        internal var configured: Bool {
            stateLock.lock(); defer { stateLock.unlock() }; return _configured
        }

        /// The message of the not-configured error (an `NSError` the mappers send to `unknown`).
        static let notConfiguredMessage = "AppDNA SDK not configured yet — call configure() first"

        /// `configure` wires the bridge, the tracker and the policy here — right after the bridge is built
        /// and BEFORE the observer starts, so the facade and the observer see the same bridge (R64/R65).
        internal func wire(bridge: BillingBridgeProtocol?, policy: BillingOwnershipPolicy, tracker: EventTracker?) {
            stateLock.lock()
            _bridge = bridge
            _ownershipPolicy = policy
            _configured = true
            _eventTracker = tracker
            stateLock.unlock()
        }

        /// Released by `AppDNA.shutdown()`. Nothing else may call this.
        internal func teardown() {
            stateLock.lock()
            _bridge = nil
            _configured = false
            _ownershipPolicy = BillingOwnership.unavailable
            _eventTracker = nil
            stateLock.unlock()
            cancelExpiryCheck()
            // A read still running belongs to the session that ended: the next session starts its own.
            entitlementHandlerLock.lock()
            inFlightServerRead = nil
            entitlementHandlerLock.unlock()
            // Entitlement handlers are dropped SYNCHRONOUSLY by `AppDNA.shutdown()`, before this async
            // teardown is even queued. Clearing them again here would remove a handler the caller
            // legitimately registered after `shutdown()` returned — the `shutdown(); configure()`
            // one-tick sequence every wrapper uses. See the note at the top of `AppDNA.shutdown()`.
        }
        /// SPEC-070-B PN row 3 (E3): keyed by token so a handler can be removed. An append-only array
        /// had no removal method anywhere in the SDK, so a wrapper that re-`configure()`s (a React
        /// Native reload does exactly that) accumulated handlers and delivered every change N-fold.
        private var entitlementChangeHandlers: [UUID: ([Entitlement]) -> Void] = [:]
        private let entitlementHandlerLock = NSLock()
        private var entitlementObserverToken: NSObjectProtocol?
        /// The fingerprint (`EntitlementFingerprint`) of the entitlements at the last refresh. Used to post
        /// `.entitlementsChanged` only on a REAL change. Nil until the first refresh, which SEEDS it from
        /// the persisted copy (`EntitlementFingerprint.storageKey`) — before, it started as an empty set,
        /// so the first refresh after every launch reported any non-empty entitlement set as a change.
        /// Guarded by `entitlementHandlerLock`.
        private var lastKnownFingerprint: [String]?
        /// The server-only entitlements (`/billing/entitlements` rows StoreKit on this device does not
        /// hold, e.g. a purchase made on another platform) of the last successful server read, and whose
        /// they were — reused when the server is unreachable, so going offline is not an entitlement
        /// change. Persisted beside the fingerprint (`ServerOnlyEntitlementCache`, the same defaults):
        /// the fingerprint survives a relaunch, so the server-only rows must too — an offline relaunch
        /// used to drop them and report the cross-platform purchase as gone. Nil until first read, which
        /// seeds it from the persisted copy. Guarded by `entitlementHandlerLock`.
        private var cachedServerOnly: (userId: String, items: [ServerEntitlement])?
        /// Bumped by every sign-out (`clearServerOnlyEntitlementCache`). A refresh pass records it before its
        /// awaits and keeps the server's answer only if it is unchanged: a refresh in flight across `reset()`
        /// otherwise saved the signed-out user's server-only rows again, after the reset had cleared them.
        /// Guarded by `entitlementHandlerLock`.
        private var resetGeneration = 0
        /// The number of the last `/billing/entitlements` request a pass started, and of the last one whose
        /// answer was applied (`serverOnlyEntitlements`). Guarded by `entitlementHandlerLock`.
        private var serverRequestSequence = 0
        private var appliedServerSequence = 0
        /// The `/billing/entitlements` request in flight, if any (`joinOrStartServerRead`). A pass that
        /// would start a read while one for the same user and sign-out count is still running shares it
        /// instead: each timed-out pass used to leave its own request running (up to ~2 minutes with
        /// `APIClient`'s retries), so on a degraded network every trigger added one more parallel read.
        /// Guarded by `entitlementHandlerLock`.
        private var inFlightServerRead: InFlightServerRead?
        /// The observer that delivers `.entitlementsChanged` to the billing delegate.
        private var delegateObserverToken: NSObjectProtocol?
        /// The tail of the refresh chain: refreshes run one after another, so an older read can never
        /// land after a newer one and report a change back. Guarded by `refreshLock`.
        private var refreshChain: Task<Void, Never>?
        private let refreshLock = NSLock()
        /// The pending expiry re-check (the earliest future `expiresAt`). Guarded by `refreshLock`.
        private var expiryTask: Task<Void, Never>?

        /// Where a refresh reads entitlements from. Production reads StoreKit and `/billing/entitlements`;
        /// tests inject their own. Set before use.
        internal var entitlementSources = EntitlementSources.production
        /// Added to the earliest expiry before the re-check runs, so StoreKit has dropped the expired
        /// transaction from `currentEntitlements` by then. Tests shorten it.
        internal var expiryRecheckLeeway: TimeInterval = 1

        internal init() {
            // 🔴 `AppDNABillingDelegate.onEntitlementsChanged` WAS NEVER CALLED. Only the closure API
            // (`onEntitlementsChanged {}`) listened to `.entitlementsChanged`; the typed delegate — the
            // documented surface — had no caller anywhere in the SDK. Now the delegate hears every post
            // the closures hear: same notification, same conversion, on the main queue, once per post.
            delegateObserverToken = NotificationCenter.default.addObserver(
                forName: .entitlementsChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let entitlements = notification.userInfo?["entitlements"] as? [ServerEntitlement],
                      let delegate = self.currentDelegate else { return }
                delegate.onEntitlementsChanged(entitlements: Self.publicEntitlements(entitlements))
            }
        }

        deinit {
            if let token = entitlementObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = delegateObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
            expiryTask?.cancel()
        }

        /// Fetch localized product information from the App Store.
        /// Uses StoreKit 2 `Product.products(for:)` directly.
        public func getProducts(_ ids: [String]) async throws -> [ProductInfo] {
            guard bridge != nil else {
                Log.warning("BillingModule: No billing provider configured")
                return []
            }
            let products = try await _fetchStoreKitProducts(ids)
            return products
        }

        /// Initiate a purchase for the given product ID.
        /// Delegates to the configured billing bridge.
        ///
        /// Cross-account-leak defence (`PurchaseOptions.appAccountToken`):
        ///   - Explicit `options.appAccountToken` wins (host controls binding).
        ///   - Otherwise the SDK derives a deterministic token from the
        ///     currently-identified user (`AppDNA.identify(userId:)`).
        ///   - If no user has identified yet, the purchase still proceeds
        ///     untagged (the bridge logs a warning). This preserves
        ///     pre-identify first-launch flows; hosts SHOULD call
        ///     `AppDNA.identify(...)` before letting the user purchase.
        /// 🔴 EVERY PURCHASE MADE OUTSIDE A NATIVE PAYWALL WAS ANALYTICALLY SILENT.
        ///
        /// `purchase_completed` / `subscription_started` / `subscription_renewed` are the three events
        /// the MTPU billing query counts (`COUNT(DISTINCT user)`). Emission of the first two was
        /// scattered across BOTH layers — some bridges emitted, some expected their caller to — which
        /// produced a matrix that was wrong in three of six cells:
        ///
        /// |                              | StoreKit2   | Adapty        | RevenueCat  |
        /// |------------------------------|-------------|---------------|-------------|
        /// | native paywall               | 1 ✅        | **2** ❌       | 1 ✅        |
        /// | `AppDNA.billing.purchase()`  | **0** ❌    | 1 ✅          | **0** ❌    |
        ///
        /// The double-emit inflated purchase counts and revenue sums. The ZERO-emit cell cost real
        /// money: a React Native / Flutter host — or any native host with its own JS/SwiftUI paywall —
        /// on the DEFAULT provider (StoreKit2) reported no metered event at all, so those subscribers
        /// were never counted, in our billing OR in the customer's own revenue dashboard.
        ///
        /// The invariant, now enforced by `check-purchase-emit-chokepoint.ts`:
        /// **the CALLER of `bridge.purchase(...)` emits; a bridge NEVER does.** There are exactly two
        /// callers — this one and `PaywallManager` — so every purchase, on every provider, through
        /// every entry point, emits exactly once. `PurchaseSuccessEvents.emit`'s own doc always said
        /// "exactly one of each, from the one site that observed the purchase"; now it is true.
        public func purchase(_ productId: String, options: PurchaseOptions? = nil) async throws -> TransactionInfo {
            // 🔴 CAPTURE THE TRACKER STRONGLY BEFORE ANY AWAIT — OR A PURCHASE CAN CHARGE AND EMIT NOTHING.
            //
            // `eventTracker` is `weak`, and `teardown()` nils it — so if `shutdown()` lands mid-purchase,
            // the charge goes through and `if let eventTracker` reads nil: money taken, ZERO metered
            // events. Pin the tracker to the purchase the instant we commit to it.
            let state = snapshot()
            let tracker = state.tracker
            let ownershipPolicy = state.policy
            guard state.configured else {
                // SPEC-497 §3.2 rule 3 (R65) — no new error type: an NSError the mappers send to `unknown`.
                // ⚠️ SPEC-497 I3 m1 — in production this emit never happens: `tracker` and `configured` come
                // from ONE locked snapshot, and `wire` sets / `teardown()` clears both in one lock hold, so
                // whenever billing is not configured `tracker` is nil and `trackPurchaseFailed` is a no-op
                // (a `shutdown()` racing this call cannot split them). The `reason` is kept for parity with
                // Android and is only observable with an injected tracker (BillingModuleNoProviderTests) —
                // not proof of what a device emits.
                let error = Self.notConfiguredError()
                trackPurchaseFailed(tracker, productId: productId, error: error, reason: "not_configured")
                throw error
            }
            guard let bridge = state.bridge else {
                // SPEC-497 §3.4 (SDK minor 10) — was `BillingModuleError.noBillingProvider`.
                Log.warning("BillingModule: No billing provider configured")
                let error = BillingError.providerNotAvailable(ownershipPolicy.refusalMessage)
                trackPurchaseFailed(tracker, productId: productId, error: error)
                throw error
            }
            let token = options?.appAccountToken ?? AppAccountTokenResolver.tokenForCurrentUser()
            // SPEC-497 §13a.2 (R40) — a direct purchase emits `purchase_started` like Android. A non-owning
            // bridge refuses without starting anything, so it gets no `purchase_started` (R64).
            if ownershipPolicy.sdkCanPurchase, let tracker {
                tracker.track(event: "purchase_started", properties: BillingEventProps.marked([
                    "product_id": productId,
                ]))
            }
            // The owner map (R47–R50): recorded BEFORE the StoreKit call, whatever the outcome.
            PurchaseOwnerMap.recordBeforePurchase(token: token)
            let result: PurchaseResult
            do {
                result = try await bridge.purchase(productId: productId, appAccountToken: token)
            } catch let cancellation as CancellationError {
                // The host cancelled its own Task: not a failed purchase. Rethrown as-is and not tracked —
                // the same rule as `restorePurchases` (Android rethrows `CancellationException`). It used
                // to be tracked as `purchase_failed{error_type: unknown}`.
                throw cancellation
            } catch {
                trackPurchaseFailed(tracker, productId: productId, error: error)
                throw error
            }
            // No `paywall_id`: this purchase did not come from an AppDNA-rendered paywall. Fabricating
            // one would misattribute revenue to a paywall that was never shown. A re-buy of an owned item
            // books no revenue (`purchase_restored{reason: item_already_owned}`, R40/R41).
            if let tracker {
                if result.alreadyOwned {
                    PurchaseSuccessEvents.emitAlreadyOwned(tracker: tracker, paywallId: nil, result: result)
                } else {
                    PurchaseSuccessEvents.emit(tracker: tracker, paywallId: nil, result: result)
                }
            }
            // SPEC-497 §13a.2 — after a subscription purchase, one snapshot pass, so its first renewal
            // diffs against the right baseline.
            if result.isSubscription { await AppDNA.reconcileSubscriptionStateNow() }
            // Round-34 — refresh the entitlement cache so onEntitlementsChanged fires after a purchase,
            // matching Android. Diff-guarded inside the refresh pass.
            // 🔴 QUEUED, NOT AWAITED. The pass reads `GET /billing/entitlements` for an identified user
            // (30 s timeout, 3 retries) and waits behind every earlier pass on the serial chain; awaiting it
            // held the purchase result for up to ~2 minutes on a degraded network although StoreKit had
            // already answered. Android returns after its local cache update. See `refreshInBackground`.
            refreshInBackground()
            return TransactionInfo(
                transactionId: result.transactionId,
                productId: result.productId,
                purchaseDate: Date(),
                environment: result.environment ?? StoreKitEnvironment.fallback
            )
        }

        /// The terminal event of a failed direct purchase — split exactly as the paywall path splits it:
        /// a user cancel is `purchase_canceled`, a pending approval `purchase_pending`, anything else one
        /// `purchase_failed` (no `paywall_id`). Only when a tracker exists (none before `configure`).
        private func trackPurchaseFailed(_ tracker: EventTracker?, productId: String, error: Error, reason: String? = nil) {
            guard let tracker else { return }
            let errorType = billingErrorType(error)
            switch errorType {
            case "userCancelled":
                tracker.track(event: "purchase_canceled", properties: BillingEventProps.marked(["product_id": productId]))
            case "pending":
                tracker.track(event: "purchase_pending", properties: BillingEventProps.marked(["product_id": productId]))
            default:
                tracker.track(event: "purchase_failed", properties: PurchaseFailedProps.build(
                    paywallId: nil,
                    productId: productId,
                    error: error,
                    errorType: errorType,
                    reason: reason
                ))
            }
        }

        /// SPEC-497 §3.2 rule 3 (R65) — the not-configured error. `billingErrorType` sends it to `unknown`.
        static func notConfiguredError() -> NSError {
            NSError(domain: "AppDNA", code: -1, userInfo: [NSLocalizedDescriptionKey: notConfiguredMessage])
        }

        /// Restore previously purchased products.
        /// Returns an array of restored product IDs.
        ///
        /// Cross-account-leak defence: restored products are filtered to the
        /// currently-identified user's `appAccountToken` (the bridge filters). The iOS SDK makes no
        /// server restore call: StoreKit2 reads `Transaction.currentEntitlements` locally, and a
        /// linked provider restores through its own SDK.
        ///
        /// SPEC-497 §13b.2 (R37/R38/R39) — a direct call that fails tracks exactly ONE
        /// `purchase_restore_failed` (`error`, `error_type`, no `paywall_id`) and rethrows: the `none`
        /// setup, a non-owning bridge (RevenueCat / Adapty not linked) and a failing `bridge.restore`
        /// alike. Before `configure` there is no tracker, so the not-configured error tracks nothing
        /// (as in `purchase`). The paywall restore calls `bridge.restore` itself (`PaywallManager`) and
        /// tracks its own event, so it never passes through here and is never counted twice. A Swift
        /// `CancellationError` (the host cancelled its Task) is not a failure: rethrown as-is, untracked.
        public func restorePurchases() async throws -> [String] {
            // Pinned before any await, as in `purchase` — `teardown()` nils the weak tracker.
            let state = snapshot()
            let tracker = state.tracker
            guard state.configured else { throw Self.notConfiguredError() }
            do {
                guard let bridge = state.bridge else {
                    // SPEC-497 §3.4 — was `BillingModuleError.noBillingProvider`. A non-owning bridge throws
                    // `providerNotAvailable` itself (§3.2 rule 2).
                    Log.warning("BillingModule: No billing provider configured")
                    throw BillingError.providerNotAvailable(state.policy.refusalMessage)
                }
                let restored = try await bridge.restore(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
                // Round-34 — refresh entitlements so onEntitlementsChanged fires after a restore, matching
                // Android (restorePurchases → replaceAll → notifyBillingDelegate). Diff-guarded. Queued, not
                // awaited: the restore's answer is StoreKit's and must not wait on the network
                // (`refreshInBackground`).
                refreshInBackground()
                return restored
            } catch let cancellation as CancellationError {
                // The host cancelled its own Task: not a failed restore. Rethrown as-is and not tracked,
                // matching Android (`NativeBillingManager` rethrows `CancellationException`) — §13b.2 R37.
                throw cancellation
            } catch {
                trackRestoreFailed(tracker, error: error)
                throw error
            }
        }

        /// The one `purchase_restore_failed` of a failed direct restore (no `paywall_id`).
        private func trackRestoreFailed(_ tracker: EventTracker?, error: Error) {
            guard let tracker else { return }
            tracker.track(event: "purchase_restore_failed", properties: BillingEventProps.marked([
                "error": error.localizedDescription,
                "error_type": billingErrorType(error),
            ]))
        }

        /// Get current entitlements as `Entitlement` objects.
        ///
        /// Read from the bridge (StoreKit `Transaction.currentEntitlements`, or the provider's customer
        /// info), with each product's StoreKit `expirationDate` as `expiresAt` — nil for a product without
        /// one (a non-consumable, a lifetime unlock) or one StoreKit on this device does not hold. It used to
        /// be nil always. `isActive` is always true: every product the bridge returns is one the store
        /// still entitles, and `Transaction.currentEntitlements` keeps a subscription in its billing grace
        /// period although its `expirationDate` has passed (`localEntitlement`). Local only —
        /// `refreshEntitlementCache` is the path that also reads the server.
        public func getEntitlements() async -> [Entitlement] {
            guard let bridge = bridge else {
                Log.warning("BillingModule: No billing provider configured")
                return []
            }
            let productIds = await bridge.getEntitlements(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
            let expirations = await entitlementSources.localExpirations(productIds, Self.expiryOwnerFiltered(ownershipPolicy))
            let now = entitlementSources.now()
            return Self.publicEntitlements(productIds.map { Self.localEntitlement($0, expiresAt: expirations[$0], now: now) },
                                           now: now)
        }

        /// Check if the user has any active subscription.
        public func hasActiveSubscription() async -> Bool {
            guard let bridge = bridge else { return false }
            let entitlements = await bridge.getEntitlements(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
            return !entitlements.isEmpty
        }

        /// SPEC-401 Fix 1D — silently refresh cached entitlement state.
        ///
        /// Calls into the configured billing bridge to re-read the user's
        /// current entitlements (StoreKit `Transaction.currentEntitlements`,
        /// RevenueCat / Adapty `customerInfo`, etc.) and primes any
        /// internal cache the bridge maintains. Designed for two callers:
        ///   1. `AppDNA.identify` — auto-refresh after host signs in a user
        ///      so the next paywall_trigger entitlement gate (Fix 1A)
        ///      reflects that user's subscriptions, not the previous
        ///      anonymous user's empty entitlements.
        ///   2. Hosts that complete auth out-of-band (SSO callbacks, deep
        ///      links, OAuth web flows) and need to flush stale cache
        ///      without firing user-visible restore events.
        ///
        /// Side effects: no analytics events, no restore callbacks, no UI. When the entitlements REALLY
        /// changed since the last refresh (product set, `isActive` or `expiresAt`), the
        /// `onEntitlementsChanged` closures and `AppDNABillingDelegate.onEntitlementsChanged` fire once, on
        /// the main thread. Errors are swallowed and logged — the method returns normally so callers can
        /// chain without try/catch.
        ///
        /// Performance: one StoreKit read plus, for an identified user, one `GET /billing/entitlements`
        /// awaited for at most `serverReadDeadline` (2.5 s). A failed or slower read goes on with the last
        /// server answer of the same user; a slower one that then succeeds is applied by one more pass when
        /// it arrives (`deliverLateServerAnswer`). Identify hook should not be blocked on completion.
        public func refreshEntitlementCache() async {
            // Serialized: each refresh awaits the one before it (see `refreshChain`).
            await enqueueEntitlementRefresh().value
        }

        /// SPEC-497 round 28 — queue one refresh and return at once: what a purchase, a restore and the
        /// paywall's purchase / restore do after StoreKit has answered. Their result (the `TransactionInfo`,
        /// the restored ids, `onPaywallPurchaseCompleted`, the restore auto-dismiss) never waits on the
        /// network; `onEntitlementsChanged` reports the new state when the queued pass finishes — after the
        /// passes ahead of it, each of which waits at most `serverReadDeadline` for the server.
        @discardableResult
        internal func refreshInBackground() -> Task<Void, Never> {
            enqueueEntitlementRefresh()
        }

        /// How long a pass waits for `GET /billing/entitlements` (`APIClient`: 30 s per attempt, 3 retries)
        /// before it goes on with the cached server-only rows of the same user, as if the server were
        /// unreachable. The read itself keeps going; its answer, if it arrives and is still current, is
        /// applied by one more pass (`deliverLateServerAnswer`) — one more change when it adds or removes a
        /// row, none when it matches the cache. While it runs, the next passes of the same user wait on it
        /// (each for at most this long) instead of starting another (`joinOrStartServerRead`). Bounds how
        /// long a pass holds the serial chain. Tests shorten it.
        internal var serverReadDeadline: TimeInterval = 2.5

        /// A `/billing/entitlements` answer that arrived after its pass's `serverReadDeadline`, with what the
        /// pass knew when it asked: the user, the sign-out count and the request's place in the order of
        /// server requests (`serverRequestSequence`).
        struct LateServerAnswer {
            let userId: String
            let rows: [ServerEntitlement]
            let generation: Int
            let sequence: Int
        }

        /// Append one refresh to the serial chain (synchronous: the lock is never held across an await).
        /// `late`: apply that late server answer instead of reading the server again.
        @discardableResult
        private func enqueueEntitlementRefresh(late: LateServerAnswer? = nil) -> Task<Void, Never> {
            refreshLock.lock()
            defer { refreshLock.unlock() }
            let previous = refreshChain
            let task = Task { [weak self] in
                await previous?.value
                await self?.performEntitlementRefresh(late: late)
            }
            refreshChain = task
            return task
        }

        /// The outcome of a pass's server read (`readServer`).
        enum ServerReadOutcome {
            /// The read finished in time: its rows, or nil when it failed.
            case answered([ServerEntitlement]?)
            /// `serverReadDeadline` passed first.
            case timedOut
        }

        /// Whichever comes first: `request`'s answer, or `deadline`. The request is never cancelled — a
        /// late answer is still wanted (`readServer`).
        ///
        /// Exactly one side resumes the continuation (`Once`), and the answer CLAIMS before it cancels the
        /// timer: it used to cancel first, and the cancelled sleep's error was swallowed (`try?`), so the
        /// timer could wake and claim in between — `.timedOut` although the answer was in, and that answer
        /// then reported a second time as a late one. The timer also gives up when it was cancelled, whatever
        /// its sleep returned. `afterTimerCancel` is a test seam: it runs on the answer's side right after
        /// `timer.cancel()`, so a test can hold that side there and prove the timer cannot win.
        static func firstOf(_ request: Task<[ServerEntitlement]?, Never>, deadline: TimeInterval,
                            afterTimerCancel: @escaping @Sendable () -> Void = {}) async -> ServerReadOutcome {
            final class Once: @unchecked Sendable {
                private let lock = NSLock(); private var done = false
                func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
            }
            let once = Once()
            return await withCheckedContinuation { (continuation: CheckedContinuation<ServerReadOutcome, Never>) in
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000)) } catch { return }
                    guard !Task.isCancelled else { return }
                    if once.claim() { continuation.resume(returning: .timedOut) }
                }
                Task {
                    let rows = await request.value
                    guard once.claim() else { return }
                    timer.cancel()
                    afterTimerCancel()
                    continuation.resume(returning: .answered(rows))
                }
            }
        }

        /// One `/billing/entitlements` request and what it was started for. Shared by every pass that reads
        /// for the same user and sign-out count while it runs (`joinOrStartServerRead`).
        final class InFlightServerRead: @unchecked Sendable {
            let userId: String
            let generation: Int
            let sequence: Int
            let task: Task<[ServerEntitlement]?, Never>
            private let lock = NSLock()
            private var lateDeliveryClaimed = false

            init(userId: String, generation: Int, sequence: Int, task: Task<[ServerEntitlement]?, Never>) {
                self.userId = userId; self.generation = generation; self.sequence = sequence; self.task = task
            }

            /// True for the first pass that missed the deadline on this request: only that one queues the
            /// late answer, so a request shared by N timed-out passes is applied once, not N times.
            func claimLateDelivery() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if lateDeliveryClaimed { return false }
                lateDeliveryClaimed = true
                return true
            }
        }

        /// The request in flight for `userId` and `generation`, or a new one. A new request gets the next
        /// sequence number and leaves the slot when it finishes, before its answer is read, so a pass that
        /// starts after that reads the server again.
        private func joinOrStartServerRead(_ userId: String, sources: EntitlementSources, generation: Int) -> InFlightServerRead {
            entitlementHandlerLock.lock()
            defer { entitlementHandlerLock.unlock() }
            if let flight = inFlightServerRead, flight.userId == userId, flight.generation == generation {
                return flight
            }
            serverRequestSequence += 1
            let sequence = serverRequestSequence
            let task = Task { [weak self] () -> [ServerEntitlement]? in
                let rows = await sources.server(userId)
                self?.endServerRead(sequence: sequence)
                return rows
            }
            let flight = InFlightServerRead(userId: userId, generation: generation, sequence: sequence, task: task)
            inFlightServerRead = flight
            return flight
        }

        private func endServerRead(sequence: Int) {
            entitlementHandlerLock.lock()
            if inFlightServerRead?.sequence == sequence { inFlightServerRead = nil }
            entitlementHandlerLock.unlock()
        }

        /// The pass's server read: the request in flight for this user (or a new one), awaited for at most
        /// `serverReadDeadline`. Returns the rows (nil: failed or too slow — the caller falls back to the
        /// cache) and the request's sequence number. A read that misses the deadline keeps running; when it
        /// succeeds, its answer is queued as one more pass (`deliverLateServerAnswer`) — once per request.
        private func readServer(_ userId: String, sources: EntitlementSources, generation: Int) async -> (rows: [ServerEntitlement]?, sequence: Int) {
            let flight = joinOrStartServerRead(userId, sources: sources, generation: generation)
            switch await Self.firstOf(flight.task, deadline: serverReadDeadline) {
            case .answered(let rows):
                return (rows, flight.sequence)
            case .timedOut:
                Log.debug("BillingModule.refreshEntitlementCache: /billing/entitlements is slow; using the cached rows until it answers")
                if flight.claimLateDelivery() {
                    Task { [weak self] in
                        guard let rows = await flight.task.value else { return } // failed late: the cache stands
                        self?.deliverLateServerAnswer(LateServerAnswer(userId: flight.userId, rows: rows,
                                                                       generation: flight.generation, sequence: flight.sequence))
                    }
                }
                return (nil, flight.sequence)
            }
        }

        /// Queue a pass that applies a late server answer — unless billing has been torn down since.
        /// Whether the answer is still current (same user, no sign-out, no newer answer applied) is decided
        /// by that pass, on the chain. Internal: a test queues an older answer directly, which the shared
        /// request (`joinOrStartServerRead`) no longer lets two passes of one user produce.
        @discardableResult
        internal func deliverLateServerAnswer(_ answer: LateServerAnswer) -> Task<Void, Never>? {
            guard bridge != nil else { return nil }
            return enqueueEntitlementRefresh(late: answer)
        }

        /// The server-only rows for this pass: a fresh answer replaces the cache; a failed call reuses the
        /// cache of the same user; otherwise none. A pass that a sign-out overtook (`resetGeneration` moved
        /// since the pass began) or whose user is no longer the current one saves nothing here: its answer is
        /// the signed-out (or previous) user's, and `reset()` has already cleared their rows. Such a pass is
        /// stale, and `performEntitlementRefresh` then stops at `commitRefresh` without publishing anything.
        /// `currentUserId` is read while `entitlementHandlerLock` is held (see `commitRefresh` for what that
        /// does and does not make atomic).
        ///
        /// `sequence` orders the answers: one older than the last applied answer (a late answer overtaken by
        /// a newer read) is not applied — the cache is used instead — so a slow read can never report an
        /// older state back over a newer one.
        private func serverOnlyEntitlements(userId: String, server: [ServerEntitlement]?, sequence: Int, localIds: Set<String>,
                                            defaults: UserDefaults, generation: Int,
                                            currentUserId: () -> String?) -> [ServerEntitlement] {
            entitlementHandlerLock.lock()
            defer { entitlementHandlerLock.unlock() }
            guard generation == resetGeneration, Self.passUser(currentUserId()) == userId else { return [] }
            if let server, sequence > appliedServerSequence {
                appliedServerSequence = sequence
                let serverOnly = server.filter { !localIds.contains($0.productId) }
                cachedServerOnly = (userId, serverOnly)
                ServerOnlyEntitlementCache.save(userId: userId, items: serverOnly, defaults)
                return serverOnly
            }
            if cachedServerOnly == nil { cachedServerOnly = ServerOnlyEntitlementCache.load(defaults) }
            if let cached = cachedServerOnly, cached.userId == userId {
                return cached.items.filter { !localIds.contains($0.productId) }
            }
            return []
        }

        /// Whether a product's StoreKit expiry is read through `EntitlementOwnerFilter` — exactly when the
        /// product ids were: when the SDK reads the device's StoreKit set itself
        /// (`policy.sdkReadsStoreKitEntitlements`). That is `storeKit2` (`StoreKit2Bridge`) and RevenueCat /
        /// Adapty NOT linked into this build (`ExternalProviderBridge`, every published channel): both read
        /// the ids through `StoreKitEntitlementReader.productIds`, which applies the filter, so the expiry of
        /// a product must come from a transaction that passed the same filter — never from another user's
        /// transaction of the same product.
        ///
        /// Unfiltered only when a LINKED provider SDK answers (`RevenueCatBridge` / `AdaptyBridge`, source
        /// builds): the ids are the provider's answer for its current user and the provider's purchases do
        /// not carry the SDK's token, so the filter would drop every one and `expiresAt` would always be nil.
        static func expiryOwnerFiltered(_ policy: BillingOwnershipPolicy) -> Bool {
            policy.sdkReadsStoreKitEntitlements
        }

        /// Sign-out (`AppDNA.reset()`): forget the signed-out user's server-only rows, then queue one refresh
        /// so the host hears the signed-out state. Without that refresh nothing reported the sign-out: the
        /// cleared rows simply stopped appearing at the NEXT trigger (a foreground, a purchase), long after
        /// the user had gone. The refresh is the ordinary diff-guarded pass, appended to the serial chain
        /// synchronously here, so it runs before the refresh of any `identify` that follows:
        ///   - sign-out with no sign-in: one `onEntitlementsChanged` with the anonymous state — on iOS the
        ///     device's StoreKit set (`Transaction.currentEntitlements`, which belongs to the Apple ID, not
        ///     to the app's user) WITHOUT the signed-out user's server-only rows; nothing when that is
        ///     already the last-known state;
        ///   - sign-out then `identify` before the pass reads: the pass reads the signed-in user, or is
        ///     stale (`commitRefresh`); either way the sign-in is one change, not two — while the server
        ///     answers the signed-in user's read within `serverReadDeadline`. When it is slower, the pass
        ///     reports the signed-in user's state without their server-only rows (the sign-out cleared the
        ///     cache), and the late answer follows as one more change if it holds rows this device does not
        ///     (`deliverLateServerAnswer`).
        ///
        /// The refresh is queued only when the SDK reads StoreKit itself — `storeKit2`, or a RevenueCat /
        /// Adapty request whose SDK is not linked into this build (`ExternalProviderBridge`) — see
        /// `signOutRefreshes`.
        internal func signOut() {
            clearServerOnlyEntitlementCache()
            guard Self.signOutRefreshes(hasProvider: bridge != nil, policy: ownershipPolicy) else { return }
            _ = enqueueEntitlementRefresh()
        }

        /// Whether a sign-out queues its own entitlement refresh. It follows the bridge that READS the
        /// entitlements, not the provider that was requested.
        ///
        /// - No billing provider configured: no. There is nothing to read, and the pass only logged
        ///   "no billing provider configured" on every `reset()`.
        /// - RevenueCat / Adapty LINKED into this build (a source build; `RevenueCatBridge` /
        ///   `AdaptyBridge`): no. Their entitlements are the provider's answer for the provider's CURRENT
        ///   user, and `reset()` does not sign the provider out — the host does, with `Purchases.logOut()` /
        ///   `Adapty.logout()`, before or after `reset()`. A pass queued here would report whichever user
        ///   the provider held at that moment, often the one who just signed out. RevenueCat's logout
        ///   delivers its `receivedUpdated` callback, whose reconcile pass runs this same refresh for the
        ///   provider's new (anonymous) user; under Adapty the next pass reports it — the next app
        ///   foreground, `identify`, or a `refreshEntitlementCache()` the host calls after `Adapty.logout()`.
        /// - RevenueCat / Adapty NOT linked (every published channel — `ExternalProviderBridge`): yes. The
        ///   entitlements are the device's StoreKit set, read by the SDK exactly as under StoreKit 2, and
        ///   no provider SDK is there to deliver an update — without this pass nothing reported the
        ///   sign-out until the next trigger.
        /// - StoreKit 2 (the SDK owns StoreKit): yes — the device's set is read for the now-anonymous user.
        static func signOutRefreshes(hasProvider: Bool, policy: BillingOwnershipPolicy) -> Bool {
            hasProvider && policy.sdkReadsStoreKitEntitlements
        }

        /// The billing half of a sign-out without the refresh (`signOut()` is what `reset()` calls): forget
        /// the server-only rows of the signed-out user, in memory and persisted. They were reused only for
        /// the same user id, but they are that user's purchase data and must not outlive the sign-out on the
        /// device.
        internal func clearServerOnlyEntitlementCache() {
            entitlementHandlerLock.lock()
            resetGeneration += 1
            cachedServerOnly = nil
            ServerOnlyEntitlementCache.clear(entitlementSources.defaults)
            entitlementHandlerLock.unlock()
        }

        /// The sign-out count a refresh pass records before its awaits (see `resetGeneration`).
        private func currentResetGeneration() -> Int {
            entitlementHandlerLock.lock()
            defer { entitlementHandlerLock.unlock() }
            return resetGeneration
        }

        /// What a finished refresh pass may do with its answer (`commitRefresh`).
        enum RefreshCommit: Equatable {
            /// A sign-out happened, or the current user changed, while the pass was awaiting: its answer is
            /// the previous user's. It changes nothing and publishes nothing.
            case stale
            /// The answer is the last-known state.
            case unchanged
            /// The answer differs from the last-known state, which it now is.
            case changed
        }

        /// Record `fingerprint` as the last-known state, unless the pass is stale: a sign-out since it began
        /// (`generation` is not `resetGeneration`) or a current user other than the one it read for
        /// (`currentUserId()` is not `passUserId`). Seeded from the persisted copy on the first call.
        ///
        /// What is atomic: the generation check, the call to `currentUserId()` and the fingerprint swap all run
        /// inside one hold of `entitlementHandlerLock`. `clearServerOnlyEntitlementCache` (the billing half of
        /// `reset()`) bumps `resetGeneration` under the same lock, so a sign-out lands either before the check
        /// (this pass is stale) or after the swap (and the refresh `signOut()` queues behind this pass reports
        /// the signed-out state).
        ///
        /// What is NOT atomic: the identity. The user id lives in `IdentityManager`, behind its own serial
        /// queue, not this lock; `identify` can change it the instant after `currentUserId()` returns. This
        /// pass then commits what it read for the previous user — a state that was true when it was read —
        /// and the switch is still reported: `identify` queues its own refresh behind this one on the serial
        /// chain, and that pass reads the new user.
        private func commitRefresh(_ fingerprint: [String], defaults: UserDefaults, generation: Int,
                                   passUserId: String?, currentUserId: () -> String?) -> RefreshCommit {
            entitlementHandlerLock.lock()
            defer { entitlementHandlerLock.unlock() }
            guard generation == resetGeneration, passUserId == Self.passUser(currentUserId()) else { return .stale }
            let before = lastKnownFingerprint ?? EntitlementFingerprint.load(defaults)
            lastKnownFingerprint = fingerprint
            return fingerprint != before ? .changed : .unchanged
        }

        /// A user id as a pass compares it: nil or empty is anonymous.
        private static func passUser(_ id: String?) -> String? {
            guard let id, !id.isEmpty else { return nil }
            return id
        }

        /// One refresh pass. What it reads:
        ///   1. the bridge's entitlements for the current user (StoreKit `Transaction.currentEntitlements`,
        ///      or the provider's customer info) — the device's own truth, with each product's StoreKit
        ///      `expirationDate`;
        ///   2. `GET /billing/entitlements?app_user_id=` for an identified user — the server's rows that
        ///      this device does NOT hold (a purchase made on another platform or device) are added. The
        ///      server call never gates the device's answer: when it fails, the last server-only rows of the
        ///      same user are reused (so going offline is not an entitlement change), else none.
        ///
        /// 🔴 POST `.entitlementsChanged` on a REAL change only — the product set, `isActive` or `expiresAt`
        /// of any entitlement. A renewal moves the expiry, so it IS a change; a refresh that finds the same
        /// state (every identify, every foreground) is not. The fingerprint is persisted, so the first refresh
        /// after a launch compares against the last one the app saw, not against "nothing".
        ///
        /// Triggers (each diff-guarded here): a purchase, a restore, `identify`, a sign-out (`reset()` →
        /// `signOut()`), every
        /// `SubscriptionStatusObserver` pass (launch, app foreground, `Transaction.updates` — renewals,
        /// refunds / revocations, late purchases — and a provider's subscriber-state callback), and the
        /// expiry re-check scheduled below at the earliest future `expiresAt`.
        ///
        /// 🔴 A STALE pass returns before any of that. A pass awaits StoreKit and the server; when a sign-out
        /// (`reset()`) or a user switch lands meanwhile, everything it read is the previous user's — the
        /// StoreKit set under their `appAccountToken`, their server rows. It used to record that as the
        /// last-known state, post it, and schedule an expiry re-check for it: after `reset()` + `identify` the
        /// app saw the signed-out user's set, then the new session's — two changes, one of them wrong. Now it
        /// returns with no fingerprint swap, no post and no re-check; the sign-in's own refresh (queued behind
        /// it) reports the new user's state once.
        ///
        /// The server read waits at most `serverReadDeadline` (`readServer`); a pass queued for a late answer
        /// (`late`) uses that answer instead of reading again, and is dropped when a sign-out or a user switch
        /// happened since the read began.
        private func performEntitlementRefresh(late: LateServerAnswer? = nil) async {
            guard let bridge = bridge else {
                Log.warning("BillingModule.refreshEntitlementCache: no billing provider configured")
                return
            }
            let sources = entitlementSources
            // Before any await: a sign-out or user switch after this point makes the pass stale.
            let generation = currentResetGeneration()
            let passUserId = Self.passUser(sources.currentUserId())
            if let late, late.generation != generation || late.userId != passUserId {
                Log.debug("BillingModule.refreshEntitlementCache: a late server answer for a signed-out or previous user; dropped")
                return
            }
            // The token filters out the previous user's transactions — this runs on every `identify`.
            let productIds = await bridge.getEntitlements(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
            var seen = Set<String>()
            let localIds = productIds.filter { seen.insert($0).inserted }
            let expirations = await sources.localExpirations(localIds, Self.expiryOwnerFiltered(ownershipPolicy))
            let now = sources.now()
            var entitlements: [ServerEntitlement] = localIds.map { id in
                Self.localEntitlement(id, expiresAt: expirations[id], now: now)
            }

            if let userId = passUserId {
                let read: (rows: [ServerEntitlement]?, sequence: Int)
                if let late {
                    read = (late.rows, late.sequence)
                } else {
                    read = await readServer(userId, sources: sources, generation: generation)
                }
                entitlements += serverOnlyEntitlements(userId: userId, server: read.rows, sequence: read.sequence,
                                                       localIds: seen, defaults: sources.defaults,
                                                       generation: generation, currentUserId: sources.currentUserId)
            }

            let fingerprint = EntitlementFingerprint.make(entitlements, now: now)
            let commit = commitRefresh(fingerprint, defaults: sources.defaults, generation: generation,
                                       passUserId: passUserId, currentUserId: sources.currentUserId)
            guard commit != .stale else {
                Log.debug("BillingModule.refreshEntitlementCache: a sign-out or user switch overtook this pass; dropped")
                return
            }

            scheduleExpiryCheck(entitlements, now: now)
            guard commit == .changed else { return }
            EntitlementFingerprint.save(fingerprint, sources.defaults)
            NotificationCenter.default.post(name: .entitlementsChanged, object: nil,
                                            userInfo: ["entitlements": entitlements])
        }

        /// Re-check once the earliest future expiry has passed (plus `expiryRecheckLeeway`), so an expiry
        /// with no transaction and no foreground still reports. At most one pending check; each refresh
        /// replaces it. Capped at 24 h (a later refresh schedules the next one).
        private func scheduleExpiryCheck(_ entitlements: [ServerEntitlement], now: Date) {
            let next = entitlements
                .compactMap { $0.expiresAt.flatMap(ISO8601.date(from:)) }
                .filter { $0 > now }
                .min()
            let leeway = expiryRecheckLeeway
            refreshLock.lock()
            expiryTask?.cancel()
            expiryTask = nil
            if let next {
                let delay = min(next.timeIntervalSince(now) + leeway, 24 * 60 * 60)
                expiryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.refreshEntitlementCache()
                }
            }
            refreshLock.unlock()
        }

        private func cancelExpiryCheck() {
            refreshLock.lock()
            expiryTask?.cancel()
            expiryTask = nil
            refreshLock.unlock()
        }

        /// The public `Entitlement` of each posted `ServerEntitlement` — ONE conversion for the closure
        /// handlers and the delegate, so the two can never disagree. `isActive` is `isActive(status:…)`.
        static func publicEntitlements(_ entitlements: [ServerEntitlement], now: Date = Date()) -> [Entitlement] {
            entitlements.map { e in
                let expiresAt = e.expiresAt.flatMap(ISO8601.date(from:))
                return Entitlement(
                    identifier: e.productId,
                    isActive: isActive(status: e.status, expiresAt: expiresAt, now: now),
                    expiresAt: expiresAt,
                    productId: e.productId
                )
            }
        }

        /// An entitled status (`EntitlementCache.activeStatuses` — `active` / `trialing` / `grace_period` /
        /// `billing_retry`, the server's and Android's set). `grace_period` / `billing_retry` are active
        /// whatever their expiry: the period end has passed by definition while the store retries the
        /// payment (server `entitlement.ts` `isEntitled`, Android `EntitlementCache`). `active` /
        /// `trialing` additionally need an expiry that, when known, has not passed — a canceled-but-paid
        /// row the server reported as `active` stops at its period end even while the device is offline.
        static func isActive(status: String, expiresAt: Date?, now: Date) -> Bool {
            guard EntitlementCache.activeStatuses.contains(status) else { return false }
            if EntitlementCache.pastExpiryStatuses.contains(status) { return true }
            return expiresAt.map { $0 > now } ?? true
        }

        /// The row of a product the bridge returned (StoreKit `Transaction.currentEntitlements`, or the
        /// provider's active set). The store still entitles it, so it is active. StoreKit keeps a
        /// subscription in `currentEntitlements` during its billing grace period although its
        /// `expirationDate` has passed: such a row is `grace_period`, never an expired `active` row, so the
        /// scheduled expiry re-check that finds it still held reports no change.
        static func localEntitlement(_ productId: String, expiresAt: Date?, now: Date) -> ServerEntitlement {
            let pastExpiry = expiresAt.map { $0 <= now } ?? false
            return ServerEntitlement(productId: productId, store: "app_store",
                                     status: pastExpiry ? "grace_period" : "active",
                                     expiresAt: expiresAt.map(ISO8601.string(from:)),
                                     isTrial: false, offerType: nil)
        }

        /// Register a callback that fires when entitlements change.
        /// Listens to the internal `entitlementsChanged` notification.
        /// Only one NotificationCenter observer is registered; all callbacks are dispatched from it.
        /// - Returns: a token for `removeEntitlementsChangedHandler`. Discardable, so existing
        ///   native call sites keep compiling unchanged.
        @discardableResult
        public func onEntitlementsChanged(_ callback: @escaping ([Entitlement]) -> Void) -> UUID {
            let token = UUID()
            entitlementHandlerLock.lock()
            defer { entitlementHandlerLock.unlock() }
            entitlementChangeHandlers[token] = callback

            // Register the observer only once (first callback registration). The check and the
            // assignment stay under the same lock — otherwise two concurrent first registrations both
            // observe nil and each add an observer, and every change is then delivered twice.
            guard entitlementObserverToken == nil else { return token }
            entitlementObserverToken = NotificationCenter.default.addObserver(
                forName: .entitlementsChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                if let entitlements = notification.userInfo?["entitlements"] as? [ServerEntitlement] {
                    let infos = Self.publicEntitlements(entitlements)
                    self.entitlementHandlerLock.lock()
                    let handlers = Array(self.entitlementChangeHandlers.values)
                    self.entitlementHandlerLock.unlock()
                    for handler in handlers {
                        handler(infos)
                    }
                }
            }
            return token
        }

        /// Remove a handler registered by `onEntitlementsChanged`. Removing the last one also tears
        /// down the NotificationCenter observer, so nothing is retained after a wrapper invalidates.
        public func removeEntitlementsChangedHandler(_ token: UUID) {
            entitlementHandlerLock.lock()
            entitlementChangeHandlers.removeValue(forKey: token)
            let isEmpty = entitlementChangeHandlers.isEmpty
            let observer = entitlementObserverToken
            if isEmpty { entitlementObserverToken = nil }
            entitlementHandlerLock.unlock()
            if isEmpty, let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Drop EVERY entitlements handler and the backing observer.
        ///
        /// Called from `AppDNA.shutdown()`, which already does exactly this for the web-entitlement
        /// handlers. Without it, `shutdown()` left the entitlement handlers of the previous run
        /// attached to the process-global singleton: a wrapper that re-registers on `configure()`
        /// then had TWO live handlers, and every entitlement change — every purchase, every restore —
        /// was delivered twice. After N shutdown→configure cycles, N duplicate grants.
        public func removeAllEntitlementsChangedHandlers() {
            entitlementHandlerLock.lock()
            entitlementChangeHandlers.removeAll()
            let observer = entitlementObserverToken
            entitlementObserverToken = nil
            entitlementHandlerLock.unlock()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        // MARK: Billing delegate (SPEC-497 §13a.2 rule 6, R42/R43)

        private let delegateLock = NSLock()
        private weak var storedDelegate: AppDNABillingDelegate?
        private var storedDelegateDelivers = true

        /// Set a delegate to receive billing lifecycle callbacks.
        ///
        /// - Parameter deliversPurchases: `true` (the default) makes this delegate the one the delivery
        ///   queue delivers queued purchases to (`onPurchaseCompleted` for a purchase that completed
        ///   outside a live `purchase()` call — an interrupted or Ask-to-Buy purchase). Setting such a
        ///   delegate delivers anything already queued. Any billing delegate drains the queue, so
        ///   implement `onPurchaseCompleted` — or pass `false` if this delegate must never receive queued
        ///   purchases. Grant idempotently by `transactionId`: delivery is at least once.
        public func setDelegate(_ delegate: AppDNABillingDelegate?, deliversPurchases: Bool = true) {
            assignBillingDelegate(delegate, delivers: deliversPurchases)
        }

        /// The ONE entry point that writes the delegate storage and its `delivers` flag (R42/R43). The flag
        /// is set BEFORE the delegate, and the drain is triggered here — only for a delivering delegate —
        /// never by a bare `didSet`.
        internal func assignBillingDelegate(_ delegate: AppDNABillingDelegate?, delivers: Bool) {
            delegateLock.lock()
            storedDelegateDelivers = delivers
            storedDelegate = delegate
            delegateLock.unlock()
            if delegate != nil && delivers {
                Task { await PurchaseDeliveryQueue.shared.drain() }   // trigger (ii)
            }
        }

        /// Whether the current delegate delivers queued purchases (tests restore it with the delegate).
        internal var currentDelegateDelivers: Bool {
            delegateLock.lock(); defer { delegateLock.unlock() }
            return storedDelegateDelivers
        }

        /// The last-known entitlement fingerprint, for tests that borrow the process-wide module and must
        /// leave it as they found it.
        internal var lastKnownFingerprintForTesting: [String]? {
            get { entitlementHandlerLock.lock(); defer { entitlementHandlerLock.unlock() }; return lastKnownFingerprint }
            set { entitlementHandlerLock.lock(); lastKnownFingerprint = newValue; entitlementHandlerLock.unlock() }
        }

        /// The current delegate (the public `AppDNA.billingDelegate` getter).
        internal var currentDelegate: AppDNABillingDelegate? {
            delegateLock.lock(); defer { delegateLock.unlock() }
            return storedDelegate
        }

        /// The delegate the drain may deliver to: nil unless one is set AND it delivers purchases.
        internal func deliveringDelegate() -> AppDNABillingDelegate? {
            delegateLock.lock(); defer { delegateLock.unlock() }
            return storedDelegateDelivers ? storedDelegate : nil
        }

        /// Internal: Fetch products via StoreKit 2.
        private func _fetchStoreKitProducts(_ ids: [String]) async throws -> [ProductInfo] {
            #if canImport(StoreKit)
            let products = try await StoreKit.Product.products(for: Set(ids))
            var result: [ProductInfo] = []
            for product in products {
                var subInfo: SubscriptionInfo?
                if let sub = product.subscription {
                    let eligible = await sub.isEligibleForIntroOffer
                    subInfo = SubscriptionInfo(
                        period: sub.subscriptionPeriod,
                        introOffer: sub.introductoryOffer,
                        isEligibleForIntroOffer: eligible
                    )
                }
                result.append(ProductInfo(
                    id: product.id,
                    displayName: product.displayName,
                    description: product.description,
                    price: product.price,
                    displayPrice: product.displayPrice,
                    subscription: subInfo
                ))
            }
            return result
            #else
            return []
            #endif
        }
    }

    // MARK: - Onboarding Module

    /// Onboarding module namespace.
    public final class OnboardingModule: @unchecked Sendable {
        internal weak var manager: OnboardingFlowManager?
        internal var delegate: AppDNAOnboardingDelegate?

        init(manager: OnboardingFlowManager?) {
            self.manager = manager
        }

        /// Present an onboarding flow.
        @discardableResult
        public func present(
            flowId: String? = nil,
            from viewController: UIViewController? = nil,
            context: OnboardingContext? = nil
        ) -> Bool {
            return AppDNA.presentOnboarding(flowId: flowId, from: viewController, delegate: delegate)
        }

        /// Set a delegate for onboarding events.
        public func setDelegate(_ delegate: AppDNAOnboardingDelegate?) {
            self.delegate = delegate
        }
    }

    // MARK: - Paywall Module

    /// Paywall module namespace.
    public final class PaywallModule: @unchecked Sendable {
        internal weak var paywallManager: PaywallManager?
        internal var delegate: AppDNAPaywallDelegate?

        /// SPEC-401 Fix 1C — host opt-out for SDK auto-dismiss-on-restore-success.
        ///
        /// When set to `true`, the next successful Restore tap on a presented
        /// paywall will fire `onPaywallRestoreCompleted` to the delegate as
        /// usual, but the SDK will NOT auto-dismiss the paywall surface. The
        /// host owns dismissal in this case (typical pattern: show a
        /// "Restored — tap continue when ready" overlay, then call
        /// `viewController.dismiss(...)` from a button tap).
        ///
        /// One-shot: PaywallManager.handleRestore reads + clears this flag
        /// each time it processes a restore. After the next restore (success
        /// or failure), the flag resets to `false` so subsequent paywall
        /// presentations get the default auto-dismiss behavior.
        ///
        /// Thread-safety: read/written on the main thread (set inside the
        /// host's `onPaywallRestoreCompleted` body before returning, read
        /// from PaywallManager.handleRestore's main-thread completion).
        public var skipNextAutoDismissOnRestore: Bool = false

        init(manager: PaywallManager?) {
            self.paywallManager = manager
        }

        /// Present a paywall.
        /// 🔴 THIS DISCARDED THE ANSWER — ON THE SURFACE THAT TAKES THE MONEY.
        ///
        /// `AppDNA.presentPaywall(...)` returns a Bool: false when the id is not in the published
        /// config, when the SDK is not configured, or when it is runtime-locked. This facade — the one
        /// the docs tell hosts to call, and the one both wrappers route through — threw it away and
        /// returned `Void`. So `AppDNA.paywall.present("typo_id")` looked like a success to every
        /// caller, native and wrapper alike, and no paywall ever appeared.
        ///
        /// `OnboardingModule.present` has always returned Bool. The paywall — where the revenue is —
        /// was the one that did not.
        ///
        /// Returns false if nothing was presented.
        @discardableResult
        public func present(
            _ paywallId: String,
            from viewController: UIViewController? = nil,
            context: PaywallContext? = nil
        ) -> Bool {
            guard let vc = viewController ?? AppDNA.topViewController() else {
                Log.warning("PaywallModule.present: no view controller to present from")
                return false
            }
            return AppDNA.presentPaywall(id: paywallId, from: vc, context: context, delegate: delegate)
        }

        /// Set a delegate for paywall events.
        public func setDelegate(_ delegate: AppDNAPaywallDelegate?) {
            self.delegate = delegate
        }
    }

    // MARK: - Remote Config Module

    /// Remote configuration module namespace.
    public final class RemoteConfigModule: @unchecked Sendable {
        internal weak var manager: RemoteConfigManager?
        private var configObserverToken: NSObjectProtocol?
        private var configChangeHandlers: [() -> Void] = []

        init(manager: RemoteConfigManager?) {
            self.manager = manager
        }

        deinit {
            if let token = configObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
        }

        /// Get a remote config value.
        public func get(_ key: String) -> Any? {
            return manager?.getConfig(key: key)
        }

        /// Get all remote config values.
        public func getAll() -> [String: Any] {
            return manager?.getAllConfig() ?? [:]
        }

        /// Force refresh config from server.
        public func refresh() {
            manager?.fetchConfigs()
        }

        /// Listen for config changes.
        /// Only one NotificationCenter observer is registered; all handlers are dispatched from it.
        public func onChanged(_ handler: @escaping () -> Void) {
            configChangeHandlers.append(handler)

            // Register the observer only once (first handler registration)
            guard configObserverToken == nil else { return }
            configObserverToken = NotificationCenter.default.addObserver(
                forName: AppDNA.configUpdated,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                for h in self.configChangeHandlers {
                    h()
                }
            }
        }
    }

    // MARK: - Feature Flags Module

    /// Feature flags module namespace.
    public final class FeaturesModule: @unchecked Sendable {
        internal weak var manager: FeatureFlagManager?
        private var flagObserverToken: NSObjectProtocol?
        private var flagChangeHandlers: [() -> Void] = []

        init(manager: FeatureFlagManager?) {
            self.manager = manager
        }

        deinit {
            if let token = flagObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
        }

        /// Check if a feature flag is enabled.
        public func isEnabled(_ flag: String) -> Bool {
            return manager?.isEnabled(flag: flag) ?? false
        }

        /// Get feature flag variant value.
        public func getVariant(_ flag: String) -> Any? {
            return manager?.getValue(flag: flag)
        }

        /// Listen for flag changes.
        /// Only one NotificationCenter observer is registered; all handlers are dispatched from it.
        public func onChanged(_ handler: @escaping () -> Void) {
            flagChangeHandlers.append(handler)

            // Register the observer only once (first handler registration)
            guard flagObserverToken == nil else { return }
            flagObserverToken = NotificationCenter.default.addObserver(
                forName: AppDNA.configUpdated,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                for h in self.flagChangeHandlers {
                    h()
                }
            }
        }
    }

    // MARK: - In-App Messages Module

    /// In-app messaging module namespace.
    public final class InAppMessagesModule: @unchecked Sendable {
        internal weak var manager: MessageManager?
        internal var delegate: AppDNAInAppMessageDelegate?

        /// SPEC-070-C D10 — OPTIONAL async wrapper-veto. Set by a cross-platform
        /// wrapper (e.g. the Flutter plugin) that must round-trip to answer a
        /// veto. Consulted by `MessageManager.present(...)` in ADDITION to the
        /// synchronous `delegate.shouldShowMessage`; both can suppress. Nil for
        /// native hosts (no behavior change). Default-allow on nil/timeout is
        /// the wrapper's responsibility.
        public var asyncShouldShowMessage: ((String) async -> Bool)?

        init(manager: MessageManager?) {
            self.manager = manager
        }

        /// Set a delegate for in-app message events.
        public func setDelegate(_ delegate: AppDNAInAppMessageDelegate?) {
            self.delegate = delegate
        }

        /// Temporarily suppress in-app message display.
        public func suppressDisplay(_ suppress: Bool) {
            manager?.suppressDisplay = suppress
        }
    }

    // MARK: - Surveys Module

    /// Survey module namespace.
    public final class SurveysModule: @unchecked Sendable {
        internal weak var manager: SurveyManager?
        internal var delegate: AppDNASurveyDelegate?

        init(manager: SurveyManager?) {
            self.manager = manager
        }

        /// Present a specific survey.
        public func present(_ surveyId: String) {
            manager?.present(surveyId: surveyId)
        }

        /// Set a delegate for survey events.
        public func setDelegate(_ delegate: AppDNASurveyDelegate?) {
            self.delegate = delegate
        }
    }

    // MARK: - Deep Links Module

    /// Deep links module namespace.
    public final class DeepLinksModule: @unchecked Sendable {
        internal var delegate: AppDNADeepLinkDelegate?

        /// SPEC-070-C D10 — OPTIONAL async `shouldOpen` wrapper-veto. This is a
        /// NET-NEW decision point (no native veto existed for deep links). When
        /// set (Flutter plugin), `handleURL(_:)` awaits it before dispatching
        /// `onDeepLinkReceived`; a `false` reply skips processing. Nil for
        /// native hosts → dispatch synchronously exactly as before.
        public var asyncShouldOpen: ((URL, [String: String]) async -> Bool)?

        /// Analytics sink. A seam, not a feature: `AppDNA.track` needs a configured SDK, so without
        /// this the `deep_link_handled` emission below could not be asserted without standing up the
        /// whole SDK — which is exactly why iOS shipped for months without emitting it at all.
        internal var trackEvent: (String, [String: Any]) -> Void = { name, props in
            AppDNA.track(event: name, properties: props)
        }

        init() {}

        /// Handle an incoming URL.
        ///
        /// Emits `deep_link_handled` — iOS never did, while Android always has
        /// (`AppDNAModules.kt:676`), so every deep-link-attributed session was invisible in iOS
        /// analytics. Event name and props (`{"url": <absolute string>}`) are Android's, verbatim.
        /// A vetoed URL (`asyncShouldOpen` → false) emits nothing, exactly as on Android.
        public func handleURL(_ url: URL) {
            let params = url.queryParameters
            if let asyncVeto = asyncShouldOpen {
                Task { @MainActor [weak self] in
                    let allow = await asyncVeto(url, params)
                    guard allow else { return }
                    self?.delegate?.onDeepLinkReceived(url: url, params: params)
                    self?.trackEvent(DeepLinkAnalytics.event, DeepLinkAnalytics.props(url: url))
                }
                return
            }
            delegate?.onDeepLinkReceived(url: url, params: params)
            trackEvent(DeepLinkAnalytics.event, DeepLinkAnalytics.props(url: url))
        }

        /// Set a delegate for deep link events.
        public func setDelegate(_ delegate: AppDNADeepLinkDelegate?) {
            self.delegate = delegate
        }
    }

    // MARK: - Experiments Module

    /// Experiments module namespace.
    public final class ExperimentsModule: @unchecked Sendable {
        internal weak var manager: ExperimentManager?

        init(manager: ExperimentManager?) {
            self.manager = manager
        }

        /// Get the assigned variant for an experiment.
        public func getVariant(_ experimentId: String) -> String? {
            return manager?.getVariant(experimentId: experimentId)
        }

        /// Get all active experiment exposures.
        public func getExposures() -> [(experimentId: String, variant: String)] {
            return manager?.getExposures() ?? []
        }
    }
}

// MARK: - Onboarding Context

/// Context passed to onboarding flows for dynamic branching.
public struct OnboardingContext {
    public let source: String?
    public let campaign: String?
    public let referrer: String?
    public let userProperties: [String: Any]?
    public let experimentOverrides: [String: String]?

    public init(
        source: String? = nil,
        campaign: String? = nil,
        referrer: String? = nil,
        userProperties: [String: Any]? = nil,
        experimentOverrides: [String: String]? = nil
    ) {
        self.source = source
        self.campaign = campaign
        self.referrer = referrer
        self.userProperties = userProperties
        self.experimentOverrides = experimentOverrides
    }
}

// MARK: - Purchase Options

/// Options for a billing purchase operation.
public struct PurchaseOptions {
    /// Promotional offer payload, if applicable.
    public let promotionalOffer: PromotionalOfferPayload?
    /// Application-specific account token for fraud detection.
    public let appAccountToken: UUID?

    public init(
        promotionalOffer: PromotionalOfferPayload? = nil,
        appAccountToken: UUID? = nil
    ) {
        self.promotionalOffer = promotionalOffer
        self.appAccountToken = appAccountToken
    }
}

// MARK: - Billing Module Errors

/// Errors specific to the BillingModule namespace.
public enum BillingModuleError: LocalizedError {
    /// Deprecated and unused since SPEC-497: `AppDNA.billing.purchase` / `restorePurchases` with no
    /// billing provider throw `BillingError.providerNotAvailable` (and, before `configure`, an `unknown`
    /// "not configured yet" error). Kept so host code that names it still compiles.
    @available(*, deprecated, message: "No longer thrown — catch BillingError.providerNotAvailable instead.")
    case noBillingProvider

    public var errorDescription: String? {
        switch self {
        case .noBillingProvider:
            return "No billing provider configured. Set billingProvider in AppDNAOptions."
        }
    }
}

// MARK: - URL Query Parameters Helper

private extension URL {
    var queryParameters: [String: String] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        var params: [String: String] = [:]
        for item in items {
            params[item.name] = item.value ?? ""
        }
        return params
    }
}

// MARK: - Deep link analytics

/// The `deep_link_handled` contract, pinned in one place so iOS and Android cannot drift again.
///
/// Read from Android `AppDNAModules.kt:676` — `AppDNA.track("deep_link_handled", mapOf("url" to url))`.
/// Same event name, same single `url` prop. A divergent prop name here would be the same bug in a new
/// place: the BigQuery column would split in two and neither platform's number would be right.
enum DeepLinkAnalytics {
    static let event = "deep_link_handled"

    static func props(url: URL) -> [String: Any] {
        ["url": url.absoluteString]
    }
}

// MARK: - Entitlement refresh sources

/// Where `BillingModule.refreshEntitlementCache` reads from. Production: StoreKit for the expiries,
/// `/billing/entitlements` for the server's rows. Tests inject their own.
struct EntitlementSources {
    /// The server's entitlements for `appUserId`; nil when the call failed or no client exists.
    var server: (_ appUserId: String) async -> [ServerEntitlement]?
    /// StoreKit's expiry per product id (`StoreKitEntitlementReader.expirations`); `ownerFiltered` is
    /// `BillingModule.expiryOwnerFiltered(policy)`.
    var localExpirations: (_ productIds: [String], _ ownerFiltered: Bool) async -> [String: Date]
    var currentUserId: () -> String?
    var defaults: UserDefaults
    var now: () -> Date

    static var production: EntitlementSources {
        EntitlementSources(
            server: { userId in
                guard let client = AppDNA.billingAPIClient else { return nil }
                return await ReceiptVerifier(apiClient: client).fetchEntitlements(appUserId: userId)
            },
            localExpirations: { productIds, ownerFiltered in
                await StoreKitEntitlementReader.expirations(for: productIds, appAccountToken: AppAccountTokenResolver.tokenForCurrentUser(),
                                                            applyOwnerFilter: ownerFiltered)
            },
            currentUserId: { AppDNA.identityManagerRef?.currentIdentity.userId },
            defaults: .standard,
            now: Date.init
        )
    }
}

/// The persisted copy of `BillingModule.cachedServerOnly`: the server-only rows of the last successful
/// `/billing/entitlements` read and the user they belong to. Stored in the same defaults as the
/// fingerprint and read back only for the same user.
enum ServerOnlyEntitlementCache {
    static let storageKey = "appdna.billing.server_only_entitlements_v1"

    private struct Stored: Codable {
        let userId: String
        let items: [ServerEntitlement]
    }

    static func load(_ defaults: UserDefaults) -> (userId: String, items: [ServerEntitlement])? {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return (stored.userId, stored.items)
    }

    static func save(userId: String, items: [ServerEntitlement], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Stored(userId: userId, items: items)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// What "the entitlements changed" compares: per entitlement its product id, whether it is active, and its
/// expiry to the second — sorted, so order never counts. Persisted so a relaunch compares against the
/// last state the app saw.
enum EntitlementFingerprint {
    static let storageKey = "appdna.billing.last_entitlements_v1"

    static func make(_ entitlements: [ServerEntitlement], now: Date) -> [String] {
        AppDNA.BillingModule.publicEntitlements(entitlements, now: now).map { e in
            let expiry = e.expiresAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
            return "\(e.productId)|\(e.isActive ? 1 : 0)|\(expiry)"
        }.sorted()
    }

    static func load(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    static func save(_ fingerprint: [String], _ defaults: UserDefaults) {
        defaults.set(fingerprint, forKey: storageKey)
    }
}
