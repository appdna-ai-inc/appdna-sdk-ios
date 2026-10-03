import Foundation
import UIKit
import SwiftUI

extension Notification.Name {
    static let paywallPurchaseSuccess = Notification.Name("ai.appdna.paywallPurchaseSuccess")
    static let paywallPurchaseFailure = Notification.Name("ai.appdna.paywallPurchaseFailure")
    /// A paywall purchase ended and the paywall stays on screen: every non-success outcome
    /// (whatever `on_failure` says), and a success with no `on_success` config. The renderer re-enables
    /// its CTA (`isPurchasing = false`). Mirrors Android's `PaywallActivity.purchaseEndedSignal`.
    static let paywallPurchaseEnded = Notification.Name("ai.appdna.paywallPurchaseEnded")
}

/// SPEC-401 Fix 1C — per-presentation guard that prevents double-dismiss
/// races between the user tapping X (calls onDismiss) and the SDK's
/// auto-dismiss-on-restore-success path. First caller flips the flag;
/// subsequent callers no-op. Mirrors Android's `PaywallActivity.dispatchedDismiss`.
final class PaywallDismissGuard {
    var dispatched: Bool = false
    /// True if the host's `onPaywallRestoreCompleted` set this — used to
    /// suppress SDK auto-dismiss when the host wants to keep the paywall
    /// up after restore (e.g. a "Restored! Tap X when ready" overlay).
    var skipSDKAutoDismiss: Bool = false
}

/// Manages paywall presentation, purchase flow, and event tracking.
final class PaywallManager {
    private let remoteConfigManager: RemoteConfigManager
    private let billingBridge: BillingBridgeProtocol?
    /// The ownership policy `configure` chose. A tap the SDK cannot buy (no
    /// bridge, or `!sdkCanPurchase`) fails LOUDLY instead of silently.
    private let billingPolicy: BillingOwnershipPolicy
    /// Is billing configured right now? `configure` passes
    /// `{ AppDNA.billing.configured }`, so a tap after `shutdown()` (whose teardown resets it) fails with
    /// the `unknown` "not configured yet" error, as the direct `AppDNA.billing` API does — never with
    /// `providerNotAvailable`, and never through a bridge captured from the torn-down configure.
    private let billingConfigured: () -> Bool
    private let eventTracker: EventTracker
    /// SPEC-036-F §1.2 — consulted at present-time for a running paywall
    /// experiment targeting the entity being shown.
    private let experimentManager: ExperimentManager?

    init(
        remoteConfigManager: RemoteConfigManager,
        billingBridge: BillingBridgeProtocol?,
        billingPolicy: BillingOwnershipPolicy,
        billingConfigured: @escaping () -> Bool = { true },
        eventTracker: EventTracker,
        experimentManager: ExperimentManager? = nil
    ) {
        self.remoteConfigManager = remoteConfigManager
        self.billingBridge = billingBridge
        self.billingPolicy = billingPolicy
        self.billingConfigured = billingConfigured
        self.eventTracker = eventTracker
        self.experimentManager = experimentManager
    }

    /// Would `present(id:)` find something to show? The lookup, without the presentation.
    ///
    /// Exists so `AppDNA.presentPaywall` can answer its caller SYNCHRONOUSLY — the presentation runs
    /// on the main queue, long after the return value has been handed back, so "did it work" cannot be
    /// read out of it.
    func hasPaywall(id: String) -> Bool {
        remoteConfigManager.getPaywallConfig(id: id) != nil
    }

    /// Would `presentByPlacement` find something to show? Runs the SAME resolver the presentation runs
    /// — not a lookalike — so the two can never disagree about what "no paywall for this placement"
    /// means.
    func hasPaywall(placement: String) -> Bool {
        PaywallPlacementResolver.pick(
            from: Array(remoteConfigManager.getAllPaywalls().values),
            placement: placement,
            traits: AppDNA.getUserTraits()
        ) != nil
    }

    /// Present a paywall by placement — selects best match using audience rules.
    /// Falls back to first paywall with matching placement if no audience rules match.
    func presentByPlacement(
        placement: String,
        from viewController: UIViewController,
        context: PaywallContext?,
        delegate: AppDNAPaywallDelegate?
    ) {
        let allPaywalls = remoteConfigManager.getAllPaywalls()
        let userTraits = AppDNA.getUserTraits()

        guard let config = PaywallPlacementResolver.pick(
            from: Array(allPaywalls.values),
            placement: placement,
            traits: userTraits
        ) else {
            Log.warning("No paywall found for placement: \(placement)")
            return
        }

        present(id: config.id ?? "", from: viewController, context: context, delegate: delegate)
    }

    /// Present a paywall modally. Must be called on main thread.
    func present(
        id: String,
        from viewController: UIViewController,
        context: PaywallContext?,
        delegate: AppDNAPaywallDelegate?
    ) {
        guard let activeConfig = remoteConfigManager.getPaywallConfig(id: id) else {
            Log.error("Paywall config not found for id: \(id)")
            let error = NSError(
                domain: "ai.appdna.sdk",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Paywall config not found"]
            )
            // No config → no plan → no product was ever resolved. `productId: nil` says exactly that,
            // rather than inventing an empty string the host would have to special-case.
            delegate?.onPaywallPurchaseFailed(
                paywallId: id,
                error: error,
                errorType: billingErrorType(error),
                productId: nil
            )
            return
        }

        // SPEC-036-F §1.2 — experiment-aware presentation. If a `running`
        // paywall experiment targets this entity and the user buckets into the
        // treatment, render the treatment `payload` config instead of the
        // active one. Control / non-bucketed / old-doc → render the active
        // entity (cohort isolation §1.3 — treatment lives only in the doc).
        var config = activeConfig
        if let experimentManager,
           case let .renderTreatment(_, _, payload) = experimentManager.resolveSurfacePresentation(surfaceType: "paywall", entityId: id),
           let treatment = remoteConfigManager.decodePaywallPayload(payload) {
            Log.info("Paywall \(id) rendering experiment treatment variant")
            config = treatment
        }

        // Track view event. SPEC-070-B PN row 4 (D-s): `customData` is merged in here — this is its
        // only consumer, and a parameter with no consumer is a parameter that does nothing.
        var viewProps: [String: Any] = [
            "paywall_id": id,
            "placement": context?.placement ?? "unknown",
        ]
        if let customData = context?.customData {
            for (key, value) in customData {
                if PaywallContext.reservedEventKeys.contains(key) {
                    Log.warning("PaywallContext.customData key '\(key)' is reserved and was dropped")
                    continue
                }
                viewProps[key] = value
            }
        }
        eventTracker.track(event: "paywall_view", properties: viewProps)

        // SPEC-203 follow-up — prefetch remote images before presenting so
        // the paywall renders fully loaded, no AsyncImage placeholder flash
        // on background / hero / plan icons / testimonial avatars / feature
        // images / CTA icons. Bounded by a short timeout so a slow CDN
        // never delays the paywall by more than a blink; anything not
        // fetched in time falls back to AsyncImage's regular load path
        // (which populates from the now-warm URLCache, so second-paint
        // fills in instantly).
        let imageURLs = Self.collectImageURLs(from: config)
        // SPEC-401 Fix 1C — shared dismiss guard for this presentation.
        // Captured by both the onDismiss closure (user-tap X path) and the
        // auto-dismiss-on-restore-success path inside handleRestore. First
        // caller wins; the second is a no-op so dismiss never fires twice.
        let dismissGuard = PaywallDismissGuard()
        let buildAndPresent: () -> Void = { [weak self] in
            guard let self else { return }
            let paywallView = PaywallRenderer(
                config: config,
                onPlanSelected: { [weak self] plan, metadata in
                    self?.handlePurchase(paywallId: id, plan: plan, config: config, metadata: metadata, delegate: delegate, viewController: viewController)
                },
                onRestore: { [weak self] in
                    self?.handleRestore(paywallId: id, delegate: delegate, viewController: viewController, dismissGuard: dismissGuard)
                },
                onDismiss: { [weak self] reason in
                    self?.eventTracker.track(event: "paywall_close", properties: [
                        "paywall_id": id,
                        "dismiss_reason": reason.rawValue,
                    ])
                    guard !dismissGuard.dispatched else { return }
                    dismissGuard.dispatched = true
                    viewController.dismiss(animated: true) {
                        delegate?.onPaywallDismissed(paywallId: id)
                    }
                },
                onPromoCodeSubmit: delegate == nil ? nil : { code, completion in
                    delegate?.onPromoCodeSubmit(paywallId: id, code: code, completion: completion)
                }
            )
            let hostingController = UIHostingController(rootView: paywallView)
            hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen
            viewController.present(hostingController, animated: true) {
                delegate?.onPaywallPresented(paywallId: id)
            }
        }

        if imageURLs.isEmpty {
            buildAndPresent()
        } else {
            ImagePreloader.prefetch(urls: imageURLs, timeout: 1.5) {
                DispatchQueue.main.async { buildAndPresent() }
            }
        }
    }

    /// Walks the paywall config and extracts every raster image URL
    /// that should be prefetched. Skips Lottie / Rive / video URLs —
    /// those have their own loaders and progress indicators.
    static func collectImageURLs(from config: PaywallConfig) -> [URL] {
        var urls: [URL] = []

        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            urls.append(url)
        }

        // Background (top-level + inside layout)
        add(config.background?.image_url)
        add(config.layout?.background?.image_url)

        func walk(_ section: PaywallSection) {
            let d = section.data
            add(d?.imageUrl)
            add(d?.avatarUrl)
            // Plans inside a section
            for plan in d?.plans ?? [] {
                add(plan.image_url)
            }
            // Generic items (timeline / icon_grid / features) — only the
            // ones that carry a real URL (icons may be SF Symbol names).
            for item in d?.items ?? [] {
                add(item.image_url)
                if let icon = item.icon, icon.hasPrefix("http") { add(icon) }
            }
            // Carousel pages recurse into nested sections.
            for page in d?.pages ?? [] {
                for child in page.children ?? [] {
                    walk(child)
                }
            }
        }

        for section in config.sections {
            walk(section)
        }

        for plan in config.plans ?? [] {
            add(plan.image_url)
        }

        return urls
    }

    // MARK: - Purchase flow

    /// Internal (not private) so the shared fixtures drive the REAL tap path.
    func handlePurchase(paywallId: String, plan: PaywallPlan, config: PaywallConfig, metadata: [String: Any] = [:], delegate: AppDNAPaywallDelegate?, viewController: UIViewController) {
        // Evaluated BEFORE anything else in the handler. This used to be a bare
        // `Log.error("No billing bridge configured"); return`: a tap on a paywall plan did NOTHING — no
        // delegate call, no event. Now: exactly one `purchase_failed`, one `onPaywallPurchaseFailed`
        // (`providerNotAvailable`, with the tapped plan's product id — the documented recipe is to start
        // the purchase with the host's own provider from that callback), then the normal failure
        // routing. No `purchase_started` and no `onPaywallPurchaseStarted`: the purchase never started.
        // Before `configure` has wired billing, or after `shutdown()`: the `unknown` "not configured yet"
        // error, as Android's paywall tap and the direct API.
        let configured = billingConfigured()
        guard configured, let bridge = billingBridge, billingPolicy.sdkCanPurchase else {
            let error: Error = configured
                ? BillingError.providerNotAvailable(billingPolicy.refusalMessage)
                : AppDNA.BillingModule.notConfiguredError()
            let errorType = billingErrorType(error)
            Log.warning("Paywall \(paywallId): the SDK cannot buy under billingProvider '\(billingPolicy.provider)' — \(error.localizedDescription)")
            eventTracker.track(event: "purchase_failed", properties: PurchaseFailedProps.build(
                paywallId: paywallId,
                productId: plan.productId,
                error: error,
                errorType: errorType,
                reason: configured ? nil : "not_configured"
            ))
            DispatchQueue.main.async { [weak self] in
                delegate?.onPaywallPurchaseFailed(
                    paywallId: paywallId,
                    error: error,
                    errorType: errorType,
                    productId: plan.productId
                )
                self?.handlePostPurchaseFailure(
                    config: config.post_purchase?.on_failure,
                    paywallId: paywallId,
                    viewController: viewController
                )
            }
            return
        }

        delegate?.onPaywallPurchaseStarted(paywallId: paywallId, productId: plan.productId ?? "")
        // AC-038: Include toggle states and promo code in purchase event
        var purchaseProps: [String: Any] = [
            "paywall_id": paywallId,
            "product_id": plan.productId ?? "",
        ]
        for (key, value) in metadata {
            purchaseProps[key] = value
        }
        eventTracker.track(event: "purchase_started", properties: BillingEventProps.marked(purchaseProps))

        Task {
            do {
                // Cross-account-leak defence — bind the StoreKit transaction
                // to the currently-identified app user via `appAccountToken`.
                // See `AppAccountTokenResolver` for the derivation contract.
                let token = AppAccountTokenResolver.tokenForCurrentUser()
                // The owner map, BEFORE the StoreKit call, whatever the outcome.
                PurchaseOwnerMap.recordBeforePurchase(token: token)
                let result = try await bridge.purchase(
                    productId: plan.productId ?? "",
                    appAccountToken: token
                )
                // `purchase_completed` (unchanged) and — ONLY when the purchased product auto-renews —
                // `subscription_started`, the MTPU-metered event iOS never emitted. Both carry the same
                // envelope; the rule lives in `PurchaseSuccessEvents` so StoreKit2 / RevenueCat / Adapty
                // all obey it from the single result they each return. A re-buy of an owned item books
                // no revenue: one `purchase_restored{reason: item_already_owned}` and no
                // `onPaywallPurchaseCompleted`.
                let converted = !result.alreadyOwned
                if converted {
                    PurchaseSuccessEvents.emit(tracker: eventTracker, paywallId: paywallId, result: result)
                } else {
                    PurchaseSuccessEvents.emitAlreadyOwned(tracker: eventTracker, paywallId: paywallId, result: result)
                }
                // One snapshot pass after a subscription purchase (the right baseline
                // for its first renewal).
                if result.isSubscription { await AppDNA.reconcileSubscriptionStateNow() }
                // Round-34 — refresh entitlements so onEntitlementsChanged fires after a paywall
                // purchase too (matches Android + the direct billing.purchase path). Diff-guarded.
                // Queued, not awaited: the success callback, the post-purchase action and the
                // auto-dismiss must not wait on `/billing/entitlements` (`refreshInBackground`).
                AppDNA.billing.refreshInBackground()
                DispatchQueue.main.async { [weak self] in
                    if converted {
                        delegate?.onPaywallPurchaseCompleted(
                            paywallId: paywallId,
                            productId: result.productId,
                            transaction: TransactionInfo(
                                transactionId: result.transactionId,
                                productId: result.productId,
                                purchaseDate: Date(),
                                environment: result.environment ?? StoreKitEnvironment.fallback
                            )
                        )
                    }
                    // Post-purchase success action
                    self?.handlePostPurchaseSuccess(
                        config: config.post_purchase?.on_success,
                        paywallId: paywallId,
                        delegate: delegate,
                        viewController: viewController
                    )
                }
            } catch {
                // `error` is the localized human string — useless for branching, and different in every
                // locale. `error_type` is the stable discriminator that lets analytics separate a user
                // cancel from a real failure, and lets a host retry only what is retryable.
                let errorType = billingErrorType(error)
                // A user closing the App Store sheet is NOT a failure, and a Ask-to-Buy / SCA purchase
                // waiting for approval is not one either. Android has always split these into their own
                // events; on iOS the ONLY code that emitted them lived in the never-instantiated
                // `Billing/NativeBillingManager`, so the live path folded both into `purchase_failed` —
                // inflating the iOS failure rate with every cancel, and losing pending purchases
                // entirely. (`delegate_contracts/purchase_cancel_is_not_a_failure` pins this.)
                switch errorType {
                case "userCancelled":
                    eventTracker.track(event: "purchase_canceled", properties: BillingEventProps.marked([
                        "paywall_id": paywallId,
                        "product_id": plan.productId ?? "",
                    ]))
                case "pending":
                    eventTracker.track(event: "purchase_pending", properties: BillingEventProps.marked([
                        "paywall_id": paywallId,
                        "product_id": plan.productId ?? "",
                    ]))
                default:
                    eventTracker.track(event: "purchase_failed", properties: PurchaseFailedProps.build(
                        paywallId: paywallId,
                        productId: plan.productId,
                        error: error,
                        errorType: errorType
                    ))
                }
                DispatchQueue.main.async { [weak self] in
                    delegate?.onPaywallPurchaseFailed(
                        paywallId: paywallId,
                        error: error,
                        errorType: errorType,
                        productId: plan.productId
                    )
                    // Post-purchase failure action
                    self?.handlePostPurchaseFailure(
                        config: config.post_purchase?.on_failure,
                        paywallId: paywallId,
                        viewController: viewController
                    )
                }
            }
        }
    }

    // MARK: - Post-purchase actions

    private func handlePostPurchaseSuccess(config: PostPurchaseSuccessConfig?, paywallId: String, delegate: AppDNAPaywallDelegate?, viewController: UIViewController) {
        guard let config = config else {
            // No config = legacy behavior (delegate-only): the paywall stays up for the host to close,
            // so its CTA stops spinning (as Android).
            NotificationCenter.default.post(name: .paywallPurchaseEnded, object: nil)
            return
        }
        let delay = Double(config.delay_ms ?? 2000) / 1000.0

        switch config.action {
        case "dismiss":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                viewController.dismiss(animated: true)
            }

        case "show_message":
            // Show success overlay via notification (PaywallRenderer listens)
            NotificationCenter.default.post(name: .paywallPurchaseSuccess, object: nil, userInfo: [
                "message": config.message ?? "Welcome to Premium!",
                "confetti": config.confetti ?? false,
                "lottie_url": config.lottie_url ?? "",
                "delay_ms": config.delay_ms ?? 2000,
            ])
            // Auto-dismiss after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                viewController.dismiss(animated: true) {
                    delegate?.onPaywallDismissed(paywallId: paywallId)
                }
            }

        case "deep_link":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                viewController.dismiss(animated: true) {
                    delegate?.onPaywallDismissed(paywallId: paywallId)
                    if let url = config.deep_link_url {
                        delegate?.onPostPurchaseDeepLink(paywallId: paywallId, url: url)
                    }
                }
            }

        case "next_step":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                viewController.dismiss(animated: true) {
                    delegate?.onPaywallDismissed(paywallId: paywallId)
                    delegate?.onPostPurchaseNextStep(paywallId: paywallId)
                }
            }

        default:
            // An unknown action leaves the paywall up (nothing dismisses it), so re-enable
            // its CTA as the no-config branch does; it kept spinning before.
            NotificationCenter.default.post(name: .paywallPurchaseEnded, object: nil)
        }
    }

    private func handlePostPurchaseFailure(config: PostPurchaseFailureConfig?, paywallId: String, viewController: UIViewController) {
        // Every failed / cancelled / pending / refused purchase re-enables the paywall's CTA,
        // whatever `on_failure` says (with no config, nothing else ever did).
        NotificationCenter.default.post(name: .paywallPurchaseEnded, object: nil)
        guard let config = config else { return }

        switch config.action {
        case "dismiss":
            viewController.dismiss(animated: true)

        case "show_error", "retry":
            // Show error inline via notification (PaywallRenderer listens)
            NotificationCenter.default.post(name: .paywallPurchaseFailure, object: nil, userInfo: [
                "message": config.message ?? "Payment failed. Please try again.",
                "retry_text": config.retry_text ?? "Try Again",
                "allow_dismiss": config.allow_dismiss ?? true,
                "action": config.action,
            ])

        default:
            break
        }
    }

    func handleRestore(
        paywallId: String,
        delegate: AppDNAPaywallDelegate?,
        viewController: UIViewController,
        dismissGuard: PaywallDismissGuard,
    ) {
        let configured = billingConfigured()
        guard configured, let bridge = billingBridge, billingPolicy.sdkCanRestore else {
            // No billing bridge, or a provider that owns restoring — surface the failure
            // so hosts don't see silence, and emit it (event parity: it used to emit nothing).
            // Not configured (before `configure`, or after `shutdown()`): the `unknown` "not configured
            // yet" error, as the purchase tap in the same window.
            let error: Error = configured
                ? BillingError.providerNotAvailable(billingPolicy.refusalMessage)
                : AppDNA.BillingModule.notConfiguredError()
            var props: [String: Any] = [
                "paywall_id": paywallId,
                "error": error.localizedDescription,
                "error_type": billingErrorType(error),
            ]
            // As Android: a refusal before `configure` says why.
            if !configured { props["reason"] = "not_configured" }
            eventTracker.track(event: "purchase_restore_failed", properties: BillingEventProps.marked(props))
            DispatchQueue.main.async {
                delegate?.onPaywallRestoreFailed(
                    paywallId: paywallId,
                    error: error,
                )
                AppDNA.paywall.skipNextAutoDismissOnRestore = false
            }
            return
        }

        DispatchQueue.main.async {
            delegate?.onPaywallRestoreStarted(paywallId: paywallId)
        }

        Task {
            do {
                // Cross-account-leak defence — restored entitlements are
                // filtered by the currently-identified user's `appAccountToken`.
                let restored = try await bridge.restore(
                    appAccountToken: AppAccountTokenResolver.tokenForCurrentUser()
                )
                // Per-product purchase_restored, one per restored product id — matches Android
                // (NativeBillingManager emits N per-product + 1 aggregate). iOS previously emitted ONLY the
                // aggregate below, so a per-product restore funnel worked on Android and was empty on iOS.
                for productId in restored {
                    eventTracker.track(event: "purchase_restored", properties: BillingEventProps.marked(["product_id": productId]))
                }
                eventTracker.track(event: "purchase_restored", properties: BillingEventProps.marked([
                    "paywall_id": paywallId,
                    "restored_count": restored.count,
                ]))
                // Round-34 — refresh entitlements so onEntitlementsChanged fires after a paywall
                // restore too (matches Android + the direct restorePurchases path). Diff-guarded.
                // Queued, not awaited: `onPaywallRestoreCompleted` and the auto-dismiss must not
                // wait on `/billing/entitlements` (`refreshInBackground`).
                AppDNA.billing.refreshInBackground()
                // SPEC-401 Fix 1C — fire delegate forward FIRST so a host
                // that wants to handle dismiss itself can call dismiss
                // synchronously inside the delegate body (its dismiss flips
                // dispatchedDismiss before our auto-dismiss runs). Auto-
                // dismiss only fires when restore actually found
                // entitlements (productIds is non-empty) AND the host
                // didn't already dismiss AND didn't ask the SDK to skip.
                DispatchQueue.main.async {
                    delegate?.onPaywallRestoreCompleted(
                        paywallId: paywallId,
                        productIds: restored,
                    )
                    Log.info("Restore completed for paywall \(paywallId) with \(restored.count) products")

                    // Auto-dismiss the paywall on restore success. Empty
                    // restored array = "restore call worked but user has no
                    // entitlements to restore" — leave paywall up so user
                    // can either close manually or attempt a fresh purchase.
                    // SPEC-401 R3 audit Lens A/B — clear the public
                    // `skipNextAutoDismissOnRestore` flag on EVERY restore
                    // terminal event (success-with-products, empty-success,
                    // and the failure path below) so the one-shot flag
                    // can't leak from one paywall presentation into the
                    // next. Captured outside the early-return below.
                    let hostRequestedSkip = AppDNA.paywall.skipNextAutoDismissOnRestore
                    AppDNA.paywall.skipNextAutoDismissOnRestore = false

                    guard !restored.isEmpty else { return }
                    guard !dismissGuard.dispatched else { return }
                    // SPEC-401 R2 audit Lens B P0 — honor the public host
                    // opt-out flag we just snapshot+cleared above. Hosts
                    // set this synchronously inside their
                    // `onPaywallRestoreCompleted` delegate body when they
                    // want to keep the paywall up after a successful
                    // restore (e.g., for a custom "Restored — tap
                    // continue" overlay). Internal `skipSDKAutoDismiss`
                    // is an alternative path the SDK itself can flip; we
                    // honor either.
                    if hostRequestedSkip { return }
                    guard !dismissGuard.skipSDKAutoDismiss else { return }
                    dismissGuard.dispatched = true
                    self.eventTracker.track(event: "paywall_close", properties: [
                        "paywall_id": paywallId,
                        "dismiss_reason": "restore_success",
                    ])
                    viewController.dismiss(animated: true) {
                        delegate?.onPaywallDismissed(paywallId: paywallId)
                    }
                }
            } catch is CancellationError {
                // A cancelled restore is not a failed restore: untracked, no delegate
                // call (symmetry with Android `handleRestore`). The one-shot skip flag is still
                // cleared, as on every other terminal path.
                DispatchQueue.main.async { AppDNA.paywall.skipNextAutoDismissOnRestore = false }
                return
            } catch {
                // `error_type`, as Android.
                eventTracker.track(event: "purchase_restore_failed", properties: BillingEventProps.marked([
                    "paywall_id": paywallId,
                    "error": error.localizedDescription,
                    "error_type": billingErrorType(error),
                ]))
                DispatchQueue.main.async {
                    delegate?.onPaywallRestoreFailed(paywallId: paywallId, error: error)
                    Log.error("Restore failed: \(error.localizedDescription)")
                    // SPEC-401 R3 audit Lens A — clear the one-shot
                    // skipNextAutoDismissOnRestore flag on failure too,
                    // not just on success. Otherwise a host that set the
                    // flag for a restore that failed would carry the flag
                    // into the next paywall presentation, suppressing
                    // auto-dismiss for that unrelated restore. The flag
                    // semantics are "next restore", not "next successful
                    // restore" — clear unconditionally on either outcome.
                    AppDNA.paywall.skipNextAutoDismissOnRestore = false
                }
            }
        }
    }
}

// MARK: - Placement selection

/// Picks WHICH paywall a `placement` shows. Extracted from `PaywallManager.presentByPlacement`,
/// which read `audience_rules` only as a dictionary: when the console wrote the ARRAY shape, the
/// evaluator short-circuited to `true` (every paywall "matched") and `priority` read 0 for all of
/// them, so the winner was whatever order the config dictionary happened to iterate in.
/// `AudienceRuleEvaluator` now understands both shapes; this resolver is the seam that proves it.
enum PaywallPlacementResolver {
    static func pick(
        from paywalls: [PaywallConfig],
        placement: String,
        traits: [String: Any]
    ) -> PaywallConfig? {
        paywalls
            .filter { $0.placement == placement }
            .sorted {
                AudienceRuleEvaluator.priority(rules: $0.audience_rules)
                    > AudienceRuleEvaluator.priority(rules: $1.audience_rules)
            }
            .first { pw in
                guard pw.audience_rules != nil else { return true } // No rules = matches all
                return AudienceRuleEvaluator.evaluate(rules: pw.audience_rules, traits: traits)
            }
    }
}

// MARK: - purchase_failed event props

/// The `purchase_failed` analytics payload, built in one pure place so it is assertable.
///
/// `plan.productId` is `String?`, and an Optional dropped straight into a `[String: Any]` box stays
/// wrapped — a nil product then serialized as the literal string "nil" instead of an empty value.
/// `product_id` is the column that answers "WHICH product failed"; it has to be right.
enum PurchaseFailedProps {
    /// `paywallId` nil (a direct `AppDNA.billing.purchase`) omits the key rather than inventing one.
    /// Carries the `emitted_by` marker.
    /// `reason`: `"not_configured"` for a purchase refused before `configure`, as Android
    /// sends it; nil omits the key.
    static func build(
        paywallId: String?,
        productId: String?,
        error: Error,
        errorType: String,
        reason: String? = nil
    ) -> [String: Any] {
        var props: [String: Any] = [
            "product_id": productId ?? "",
            "error": error.localizedDescription,
            "error_type": errorType,
        ]
        if let paywallId { props["paywall_id"] = paywallId }
        if let reason { props["reason"] = reason }
        return BillingEventProps.marked(props)
    }
}
