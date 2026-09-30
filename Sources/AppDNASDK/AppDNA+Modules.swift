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
        internal var bridge: BillingBridgeProtocol?

        /// The tracker this facade emits purchase events with. Weak: `shared` owns it.
        ///
        /// A direct `AppDNA.billing.purchase(...)` — which is exactly what the React Native and Flutter
        /// wrappers call, and what any host with a JS/Dart-authored paywall calls — emitted NOTHING.
        /// See `purchase(_:options:)`.
        internal weak var eventTracker: EventTracker?

        /// Is billing actually usable right now? Read by `subsystemsUp()` so the diagnostic and the
        /// host see the same object.
        internal var isLive: Bool { bridge != nil }

        /// SPEC-497 §3.2 — the ownership policy `configure` chose (`BillingOwnership.policy`).
        internal private(set) var ownershipPolicy: BillingOwnershipPolicy = BillingOwnership.unavailable

        /// SPEC-497 §3.2 rule 3 (D-R39-1, R65–R67) — has `configure` wired billing yet? Until it has,
        /// `purchase` / `restore` fail with an `unknown` "not configured yet" error; once configured with no
        /// bridge (`none`) they throw `providerNotAvailable`. Reset by `teardown()`, so after `shutdown()`
        /// the not-configured error applies again.
        internal private(set) var configured = false

        /// The message of the not-configured error (an `NSError` the mappers send to `unknown`).
        static let notConfiguredMessage = "AppDNA SDK not configured yet — call configure() first"

        /// `configure` wires the bridge, the tracker and the policy here — right after the bridge is built
        /// and BEFORE the observer starts, so the facade and the observer see the same bridge (R64/R65).
        internal func wire(bridge: BillingBridgeProtocol?, policy: BillingOwnershipPolicy, tracker: EventTracker?) {
            self.bridge = bridge
            self.ownershipPolicy = policy
            self.eventTracker = tracker
            self.configured = true
        }

        /// Released by `AppDNA.shutdown()`. Nothing else may call this.
        internal func teardown() {
            bridge = nil
            eventTracker = nil
            configured = false
            ownershipPolicy = BillingOwnership.unavailable
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
        /// The active product-id set at the last `refreshEntitlementCache`. Used to post
        /// `.entitlementsChanged` only on a REAL change. Guarded by `entitlementHandlerLock`.
        private var lastKnownEntitlementIds: Set<String> = []

        internal init() {}

        deinit {
            if let token = entitlementObserverToken {
                NotificationCenter.default.removeObserver(token)
            }
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
            let tracker = eventTracker
            guard configured else {
                // SPEC-497 §3.2 rule 3 (R65) — no new error type: an NSError the mappers send to `unknown`.
                let error = Self.notConfiguredError()
                trackPurchaseFailed(tracker, productId: productId, error: error)
                throw error
            }
            guard let bridge = bridge else {
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
            } catch {
                trackPurchaseFailed(tracker, productId: productId, error: error)
                throw error
            }
            // No `paywall_id`: this purchase did not come from an AppDNA-rendered paywall. Fabricating
            // one would misattribute revenue to a paywall that was never shown. A re-buy of an owned item
            // books no revenue (`purchase_restored{reason: item_already_owned}`, R40/R41).
            if let tracker {
                PurchaseSuccessEvents.report(tracker: tracker, paywallId: nil, result: result)
            }
            // SPEC-497 §13a.2 — after a subscription purchase, one snapshot pass, so its first renewal
            // diffs against the right baseline.
            if result.isSubscription { await AppDNA.reconcileSubscriptionStateNow() }
            // Round-34 — refresh the entitlement cache so onEntitlementsChanged fires after a purchase,
            // matching Android. Diff-guarded inside refreshEntitlementCache.
            await refreshEntitlementCache()
            return TransactionInfo(
                transactionId: result.transactionId,
                productId: result.productId,
                purchaseDate: Date(),
                environment: "production"
            )
        }

        /// The terminal event of a failed direct purchase — split exactly as the paywall path splits it:
        /// a user cancel is `purchase_canceled`, a pending approval `purchase_pending`, anything else one
        /// `purchase_failed` (no `paywall_id`). Only when a tracker exists (none before `configure`).
        private func trackPurchaseFailed(_ tracker: EventTracker?, productId: String, error: Error) {
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
                    errorType: errorType
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
        /// currently-identified user's `appAccountToken`. Untagged historical
        /// transactions are surfaced under the migration-tolerant policy and
        /// the server claims ownership via `receiptVerifier.restore(...)`.
        public func restorePurchases() async throws -> [String] {
            guard configured else { throw Self.notConfiguredError() }
            guard let bridge = bridge else {
                // SPEC-497 §3.4 — was `BillingModuleError.noBillingProvider`. A non-owning bridge throws
                // `providerNotAvailable` itself (§3.2 rule 2).
                Log.warning("BillingModule: No billing provider configured")
                throw BillingError.providerNotAvailable(ownershipPolicy.refusalMessage)
            }
            let restored = try await bridge.restore(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
            // Round-34 — refresh entitlements so onEntitlementsChanged fires after a restore, matching
            // Android (restorePurchases → replaceAll → notifyBillingDelegate). Diff-guarded.
            await refreshEntitlementCache()
            return restored
        }

        /// Get current entitlements as `Entitlement` objects.
        ///
        /// ⚠️ `expiresAt` IS ALWAYS `nil` HERE, AND THAT IS THE HONEST ANSWER — BUT ONLY JUST.
        ///
        /// `BillingBridgeProtocol.getEntitlements` returns `[String]`: product IDs and nothing else. No
        /// bridge has an expiry to give, so this cannot invent one, and per ADR-002 N11 `expiresAt` is
        /// OPTIONAL precisely because "this platform does not know" is a better answer than a fabricated
        /// date. Synthesising one here would be the `isTrial: false`-for-a-trialing-user mistake again.
        ///
        /// What was NOT honest: the OTHER path — the server-entitlement observer below — had a real
        /// expiry in hand and threw it away on every single parse, because a bare `ISO8601DateFormatter`
        /// cannot read the fractional-second timestamps our server sends. Between a field that is always
        /// nil here and a field that never parses there, `Entitlement.expiresAt` was a public property
        /// of a public type that could not hold a value. See `ISO8601` in `EntitlementCache.swift`.
        ///
        /// Making the expiry reachable HERE means widening the bridge protocol to carry it (StoreKit's
        /// `Transaction.currentEntitlements` does expose `expirationDate`) across all three bridges and
        /// both wrapper DTOs. That is a real change, not a one-liner, and it is recorded rather than
        /// faked.
        public func getEntitlements() async -> [Entitlement] {
            guard let bridge = bridge else {
                Log.warning("BillingModule: No billing provider configured")
                return []
            }
            let productIds = await bridge.getEntitlements(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())
            return productIds.map { productId in
                Entitlement(
                    identifier: productId,
                    isActive: true,
                    expiresAt: nil,
                    productId: productId
                )
            }
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
        /// Side effects: ZERO. No analytics events, no delegate callbacks,
        /// no UI. Errors are swallowed and logged at warning level — the
        /// method returns normally so callers can chain without try/catch.
        ///
        /// Performance: cheap when StoreKit cache is warm (one verified
        /// transaction read), bounded by the bridge's network behavior on
        /// cold start. Identify hook should not be blocked on completion.
        public func refreshEntitlementCache() async {
            guard let bridge = bridge else {
                Log.warning("BillingModule.refreshEntitlementCache: no billing provider configured")
                return
            }
            // Calling getEntitlements() reads `Transaction.currentEntitlements`
            // (or RC/Adapty customerInfo) without firing restore events. Token is
            // critical here: this method is auto-called by `identify`, and
            // the whole point of that call is to make the cache reflect the
            // *newly-identified* user — passing the freshly-resolved token
            // is what filters out the previous user's transactions.
            let productIds = await bridge.getEntitlements(appAccountToken: AppAccountTokenResolver.tokenForCurrentUser())

            // 🔴 POST `.entitlementsChanged` on a real change — this is what makes `onEntitlementsChanged`
            // fire on iOS AT ALL. The result USED TO BE DISCARDED: the only poster of that notification is
            // `EntitlementCache`, which is NEVER constructed anywhere in the iOS SDK, so the host's
            // entitlement-change callback (and the typed billing delegate) were dead on iOS while Android
            // drove them live (`AppDNA.kt` constructs `EntitlementCache`). Diff against the last-known
            // active set so we don't fire a spurious callback on every identify with unchanged
            // entitlements. (Real-time renewal/expiry without a refresh still needs a Firestore-listener
            // wiring — the `EntitlementCache.startObserving` design — tracked separately.)
            let newIds = Set(productIds)
            entitlementHandlerLock.lock()
            let changed = newIds != lastKnownEntitlementIds
            lastKnownEntitlementIds = newIds
            entitlementHandlerLock.unlock()
            guard changed else { return }
            let entitlements = productIds.map {
                ServerEntitlement(productId: $0, store: "app_store", status: "active",
                                  expiresAt: nil, isTrial: false, offerType: nil)
            }
            NotificationCenter.default.post(name: .entitlementsChanged, object: nil,
                                            userInfo: ["entitlements": entitlements])
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
                    let infos = entitlements.map { e in
                        Entitlement(
                            identifier: e.productId,
                            isActive: e.status == "active" || e.status == "trialing" || e.status == "grace_period",
                            expiresAt: e.expiresAt.flatMap(ISO8601.date(from:)),
                            productId: e.productId
                        )
                    }
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
