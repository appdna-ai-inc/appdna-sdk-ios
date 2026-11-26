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
    /**
     A purchase SUCCEEDED and an authored `particle_effect` should now celebrate it.

     🔴 IT IS ITS OWN SIGNAL, and the four branches of `on_success` are why. The effect used to start
     in `handleCTATap`, which reads `trigger == "on_purchase"` and fires on the one moment that is
     definitely NOT a purchase: a user who cancelled the sheet or had a card declined watched a
     congratulatory animation, and nothing ever stopped it.

     Celebrating from the existing `.paywallPurchaseSuccess` instead would have covered only
     `on_success.action == "show_message"`, because that is the sole branch that posts it — and
     `dismiss`, `deep_link` and `next_step` are exactly the branches where a celebration during
     `delay_ms` is the point. Posting `.paywallPurchaseSuccess` from those would have raised the
     success OVERLAY too, which a `dismiss` branch never asked for. Hence one more name, posted once
     before the switch, carrying nothing: the renderer already knows what effect was authored.
    */
    static let paywallPurchaseCelebrate = Notification.Name("ai.appdna.paywallPurchaseCelebrate")
}

/// Per-presentation guard that prevents double-dismiss
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

/// the presented paywall, held weakly so the SDK can dismiss IT rather than its presenter.
final class PresentedPaywallRef {
    weak var controller: UIViewController?
}

enum PaywallDismissal {
    /**
     DISMISS THE PAYWALL, NEVER THE PRESENTER.

     Every SDK dismiss used to be `presenter.dismiss(animated:)`. UIKit reads that call on a controller that
     presents NOTHING as "dismiss this controller itself". So when a host had already closed the paywall from
     `onPaywallPurchaseCompleted` (what the docs told hosts to do), the post-purchase dismiss `delay_ms` later
     closed the host's OWN screen if that screen was presented modally. Measured on iOS 1.0.91 in the simulator:
     the host's modal was gone 6 s after a purchase with `next_step`, and still there with no `on_success`.

     Now: the paywall's own presenter dismisses the paywall, and only while it is still presented. If it is
     already gone, nothing is dismissed and `completion` still runs, so `onPaywallDismissed` (and an
     onboarding flow's route) still fires once.
     */
    /// Still on screen: presented, and not already on its way out (a host's own dismiss in flight).
    static func isStillPresented(_ paywall: UIViewController) -> Bool {
        paywall.presentingViewController != nil && !paywall.isBeingDismissed
    }

    static func dismiss(paywall: UIViewController?, presenter: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        if let paywall {
            if isStillPresented(paywall), let presenting = paywall.presentingViewController {
                presenting.dismiss(animated: animated, completion: completion)
            } else {
                completion?()
            }
            return
        }
        // No paywall reference (a path that did not go through `present`): dismiss only what the presenter presented.
        if presenter.presentedViewController != nil {
            presenter.dismiss(animated: animated, completion: completion)
        } else {
            completion?()
        }
    }
}

/**
 WHAT A SUCCESSFUL PURCHASE DOES TO THE PAYWALL WHEN NO `on_success` IS AUTHORED (since SDK 1.0.93).

 Before 1.0.93 a paywall with no `on_success` stayed open after a purchase, so a host that did not close it from
 `onPaywallPurchaseCompleted` left a paying user on the paywall. Now the SDK closes it after `defaultCloseDelayMs` —
 but only while it is still presented, and through its own presenter (`PaywallDismissal`). A host that closed it
 itself keeps its screen and gets no extra callback; otherwise `onPaywallDismissed` fires, which is also what moves an
 onboarding flow on to its `on_success_target`. An AUTHORED action keeps its own branch. Shared fixture
 `billing/paywall_success_absent_closes_if_presented`.
 */
struct PostPurchaseSuccessPlan: Equatable {
    let closes: Bool
    let delayMs: Int
    let reportsDismissed: Bool

    static let defaultCloseDelayMs = 2000

    /// The plan for a paywall with NO authored `on_success`, decided when the delay has run.
    static func absentOnSuccess(paywallStillPresented: Bool) -> PostPurchaseSuccessPlan {
        paywallStillPresented
            ? PostPurchaseSuccessPlan(closes: true, delayMs: defaultCloseDelayMs, reportsDismissed: true)
            : PostPurchaseSuccessPlan(closes: false, delayMs: defaultCloseDelayMs, reportsDismissed: false)
    }
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
    /// each presented paywall, by id, so a later dismiss targets it and not its presenter.
    private var presentedPaywalls: [String: PresentedPaywallRef] = [:]
    private func paywallController(_ id: String) -> UIViewController? { presentedPaywalls[id]?.controller }
    /// Consulted at present-time for a running paywall
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

        // Experiment-aware presentation. If a `running`
        // paywall experiment targets this entity and the user buckets into the
        // treatment, render the treatment `payload` config instead of the
        // active one. Control / non-bucketed / old-doc → render the active
        // entity (cohort isolation — treatment lives only in the doc).
        // The content on screen, from the SERVED paywall: an experiment treatment is told
        // apart by `context.experiment_exposures`, not by these keys (D6). Purchases started here
        // carry the same keys, so a conversion is credited to the content that sold it (D4).
        let contentStamp = ContentStamp.props(for: activeConfig)
        var config = activeConfig
        if let experimentManager,
           case let .renderTreatment(_, _, payload) = experimentManager.resolveSurfacePresentation(surfaceType: "paywall", entityId: id),
           let treatment = remoteConfigManager.decodePaywallPayload(payload) {
            Log.info("Paywall \(id) rendering experiment treatment variant")
            config = treatment
        }

        // Track view event. `customData` is merged in here — this is its
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
        /*
         The view event fires AFTER the store lookup, not before, so it describes the
         screen the user actually saw. It carries `price_source` per plan: `store`, or one of
         `authored_opt_out` / `authored_no_product` / `authored_lookup_failed`. That is what
         answers "why is my paywall showing the old price" — without it the question has no answer
         in the data at all, and the three authored reasons are indistinguishable from outside.

         The delay is the lookup's own bound (1.5s) and no more, and the event still fires exactly
         once per presentation.
        */

        // Prefetch remote images before presenting so
        // the paywall renders fully loaded, no AsyncImage placeholder flash
        // on background / hero / plan icons / testimonial avatars / feature
        // images / CTA icons. Bounded by a short timeout so a slow CDN
        // never delays the paywall by more than a blink; anything not
        // fetched in time falls back to AsyncImage's regular load path
        // (which populates from the now-warm URLCache, so second-paint
        // fills in instantly).
        let imageURLs = Self.collectImageURLs(from: config)
        // Shared dismiss guard for this presentation.
        // Captured by both the onDismiss closure (user-tap X path) and the
        // auto-dismiss-on-restore-success path inside handleRestore. First
        // caller wins; the second is a no-op so dismiss never fires twice.
        let dismissGuard = PaywallDismissGuard()
        let buildAndPresent: () -> Void = { [weak self] in
            guard let self else { return }
            let paywallView = PaywallRenderer(
                config: config,
                onPlanSelected: { [weak self] plan, metadata in
                    self?.handlePurchase(paywallId: id, plan: plan, config: config, metadata: metadata, delegate: delegate, viewController: viewController, contentStamp: contentStamp)
                },
                onRestore: { [weak self] in
                    self?.handleRestore(paywallId: id, delegate: delegate, viewController: viewController, dismissGuard: dismissGuard, contentStamp: contentStamp)
                },
                onDismiss: { [weak self] reason in
                    self?.eventTracker.track(event: "paywall_close", properties: ContentStamp.stamped([
                        "paywall_id": id,
                        "dismiss_reason": reason.rawValue,
                    ], contentStamp))
                    guard !dismissGuard.dispatched else { return }
                    dismissGuard.dispatched = true
                    PaywallDismissal.dismiss(paywall: self?.paywallController(id), presenter: viewController) {
                        delegate?.onPaywallDismissed(paywallId: id)
                    }
                },
                onPromoCodeSubmit: delegate == nil ? nil : { code, completion in
                    delegate?.onPromoCodeSubmit(paywallId: id, code: code, completion: completion)
                },
                // The one wire that was missing. Android has emitted CTA_TAPPED since its
                // manager was written; iOS declared the callback and called it from nowhere.
                onAction: { action in
                    delegate?.onPaywallAction(paywallId: id, action: action)
                }
            )
            let hostingController = UIHostingController(rootView: paywallView)
            hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen
            let ref = PresentedPaywallRef(); ref.controller = hostingController
            self.presentedPaywalls[id] = ref

            /*
             * 🔴 THE HOST IS CHOSEN HERE, AT PRESENT TIME, NOT WHERE THE CALL CAME FROM.
             *
             * `AppDNA.showPaywall` resolves `topViewController()` synchronously and then
             * `presentPaywall` dispatches this block onto the main queue. In between, that
             * controller can begin dismissing or start presenting something else — and UIKit then
             * REFUSES the call by logging and doing nothing. The completion never runs, so
             * `onPaywallPresented` never fires, and the caller was already told `true` because
             * `presentPaywall` returns `hasPaywall(id:)` resolved before the dispatch.
             *
             * Measured in 2 of 2 stress runs of the plan-selection walk: twelve taps over sixty
             * seconds with no paywall, in a process that had already presented the same paywall
             * about twenty times and whose StoreKit probe answered `store:2` seconds earlier.
             *
             * So the captured controller is used only if it can still present; otherwise the one
             * that can is found NOW.
             */
            let host = Self.presentableHost(preferring: viewController)
            host.present(hostingController, animated: true) {
                delegate?.onPaywallPresented(paywallId: id)
            }

            /*
             * 🔴 AND A PRESENTATION THAT DID NOT TAKE IS REPORTED. `present(_:animated:)` returns
             * nothing and its completion simply never runs when UIKit refuses, so the only way to
             * know is to look afterwards. A paywall that does not appear earns nothing, and until
             * now nobody was told: no delegate call, no event, no log.
             *
             * One second, because the modal transition is ~0.35s — long enough that a presentation
             * which took has set `presentingViewController`, short enough to be useless to nobody.
             */
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak hostingController] in
                guard let hostingController, hostingController.presentingViewController == nil else { return }
                let detail = "UIKit refused the presentation — the host controller "
                    + "(\(type(of: host))) could not present at the moment it was asked"
                Log.warning("Paywall \(id): \(detail)")
                /*
                 * 🔴 NO NEW TRACKED EVENT HERE, and the gates are why. A `paywall_present_failed`
                 * event is a CROSS-PLATFORM CONTRACT: `check:event-name-parity` requires Android
                 * to emit it too, and the module registry has to declare it — and Android has no
                 * equivalent failure, because it presents by `startActivity` rather than by asking
                 * a view controller that might refuse. Inventing a one-platform event to carry a
                 * one-platform fault would buy a metric that means different things on each side.
                 *
                 * `onConfigurationIssue` is the channel that already exists for "this surface
                 * could not do its job", on both platforms, and it reaches the host without
                 * claiming to be analytics.
                 */
                AppDNA.lifecycleDelegate?.onConfigurationIssue(surface: "paywall", id: id, detail: detail)
            }
        }

        /*
         ASK THE STORE WHAT THESE PRODUCTS COST, before the screen is built.

         Until this, `price_display` was a free-text field and the only thing a user ever saw: a
         price change in App Store Connect did not reach the paywall, so the store charged the new
         price while the screen showed the old one, in the author's currency whatever the user's
         own was. `PriceResolver` could do the lookup all along and had no callers.

         🔴 IN PARALLEL WITH THE IMAGE PREFETCH, on the same 1.5s budget, so it costs no extra
         latency. Both bound themselves and both always finish; whichever is slower decides when
         the paywall appears, exactly as the prefetch alone decided before. A product the store
         does not know, a lookup that throws and a lookup that outlives the deadline are the same
         outcome — absent — and every plan then falls back to its authored price.
         */
        let productIds = (config.plans ?? []).compactMap { $0.productId }
        let group = DispatchGroup()
        var storeFacts: [String: StorePriceLookup.StoreFacts] = [:]

        group.enter()
        // ONE round-trip for every fact. The period comes off the same `Product` as the
        // price, and a second lookup could disagree with the price it sits beside.
        StorePriceLookup.facts(for: productIds, timeout: 1.5) { facts in
            storeFacts = facts
            group.leave()
        }
        if !imageURLs.isEmpty {
            group.enter()
            ImagePreloader.prefetch(urls: imageURLs, timeout: 1.5) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Every place plans live, not only the root array — see `applyingStorePrices`. The
            // savings figure is filled LAST, over the prices actually drawn (`applyingStoreFacts`).
            config = config.applyingStoreFacts(storeFacts)
            var props = viewProps
            let sources = (config.plans ?? []).map { $0.priceSource }
            if !sources.isEmpty {
                props["price_source"] = sources.joined(separator: ",")
                props["store_prices_resolved"] = sources.filter { $0 == "store" }.count
            }
            // Last, so neither `customData` nor anything above can overwrite the content keys.
            self.eventTracker.track(event: "paywall_view", properties: ContentStamp.stamped(props, contentStamp))
            buildAndPresent()
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
    /**
     The controller a modal can actually be presented on, chosen at the moment of presenting.

     A controller that is already presenting something, is being dismissed, or is not in a window
     cannot present — UIKit refuses and does nothing. `topViewController()` walks to the deepest
     presented controller, which is the one that can.

     Prefers the caller's own controller when it is usable, so a host that passes a specific
     controller still gets it.
     */
    static func presentableHost(preferring viewController: UIViewController) -> UIViewController {
        /*
         * Descend through whatever it is ALREADY presenting first. A controller with a modal up
         * cannot present a second one, and the deepest modal is the one that can — so this is the
         * answer in the common case, and it needs no scene lookup, which matters because
         * `topViewController()` finds nothing in a test process that has no connected window
         * scene.
         */
        var vc = viewController
        while let presented = vc.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        if vc.view.window != nil, !vc.isBeingDismissed { return vc }
        // Detached or mid-dismissal: fall back to whatever the app currently has on screen.
        return AppDNA.topViewController() ?? vc
    }

    func handlePurchase(paywallId: String, plan: PaywallPlan, config: PaywallConfig, metadata: [String: Any] = [:], delegate: AppDNAPaywallDelegate?, viewController: UIViewController, contentStamp: [String: Any] = [:]) {
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
            eventTracker.track(event: "purchase_failed", properties: ContentStamp.stamped(PurchaseFailedProps.build(
                paywallId: paywallId,
                productId: plan.productId,
                error: error,
                errorType: errorType,
                reason: configured ? nil : "not_configured"
            ), contentStamp))
            DispatchQueue.main.async { [weak self] in
                delegate?.onPaywallPurchaseFailed(
                    paywallId: paywallId,
                    error: error,
                    errorType: errorType,
                    productId: plan.productId
                )
                self?.handlePostPurchaseFailure(
                    config: PostPurchaseFailureConfig.effective(authored: config.post_purchase?.on_failure, errorType: errorType),
                    paywallId: paywallId,
                    viewController: viewController
                )
            }
            return
        }

        delegate?.onPaywallPurchaseStarted(paywallId: paywallId, productId: plan.productId ?? "")
        // Include toggle states and promo code in purchase event
        var purchaseProps: [String: Any] = [
            "paywall_id": paywallId,
            "product_id": plan.productId ?? "",
        ]
        for (key, value) in metadata {
            purchaseProps[key] = value
        }
        eventTracker.track(event: "purchase_started", properties: BillingEventProps.marked(ContentStamp.stamped(purchaseProps, contentStamp)))

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
                // no revenue: one `purchase_restored{reason: item_already_owned}` and no billing-level
                // `onPurchaseCompleted` — but the paywall's own completion still fires (below), as on Android.
                let converted = !result.alreadyOwned
                if converted {
                    PurchaseSuccessEvents.emit(tracker: eventTracker, paywallId: paywallId, result: result, extra: contentStamp)
                } else {
                    PurchaseSuccessEvents.emitAlreadyOwned(tracker: eventTracker, paywallId: paywallId, result: result)
                }
                // One snapshot pass after a subscription purchase (the right baseline
                // for its first renewal).
                if result.isSubscription { await AppDNA.reconcileSubscriptionStateNow() }
                // Refresh entitlements so onEntitlementsChanged fires after a paywall
                // purchase too (matches Android + the direct billing.purchase path). Diff-guarded.
                // Queued, not awaited: the success callback, the post-purchase action and the
                // auto-dismiss must not wait on `/billing/entitlements` (`refreshInBackground`).
                AppDNA.billing.refreshInBackground()
                DispatchQueue.main.async { [weak self] in
                    Self.reportPaywallPurchaseCompleted(paywallId: paywallId, result: result, delegate: delegate)
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
                    eventTracker.track(event: "purchase_canceled", properties: BillingEventProps.marked(ContentStamp.stamped([
                        "paywall_id": paywallId,
                        "product_id": plan.productId ?? "",
                    ], contentStamp)))
                case "pending":
                    eventTracker.track(event: "purchase_pending", properties: BillingEventProps.marked(ContentStamp.stamped([
                        "paywall_id": paywallId,
                        "product_id": plan.productId ?? "",
                    ], contentStamp)))
                default:
                    eventTracker.track(event: "purchase_failed", properties: ContentStamp.stamped(PurchaseFailedProps.build(
                        paywallId: paywallId,
                        productId: plan.productId,
                        error: error,
                        errorType: errorType
                    ), contentStamp))
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
                        config: PostPurchaseFailureConfig.effective(authored: config.post_purchase?.on_failure, errorType: errorType),
                        paywallId: paywallId,
                        viewController: viewController
                    )
                }
            }
        }
    }

    // MARK: - Post-purchase actions

    private func handlePostPurchaseSuccess(config: PostPurchaseSuccessConfig?, paywallId: String, delegate: AppDNAPaywallDelegate?, viewController: UIViewController) {
        // The purchase really did succeed, so an authored `on_purchase` effect fires HERE,
        // before any branch. Every branch reaches this line; only one of them posts
        // `.paywallPurchaseSuccess`, which is why this is a signal of its own.
        NotificationCenter.default.post(name: .paywallPurchaseCelebrate, object: nil)
        // the paywall itself, weakly: by the time the delay runs the host may have closed it.
        weak var paywall = paywallController(paywallId)
        guard let config = config else {
            // The CTA stops spinning now (as Android), whatever happens next.
            NotificationCenter.default.post(name: .paywallPurchaseEnded, object: nil)
            // no `on_success`: close it after the default delay, only if the app has not closed it itself.
            let delayMs = PostPurchaseSuccessPlan.defaultCloseDelayMs
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000.0) {
                let plan = PostPurchaseSuccessPlan.absentOnSuccess(
                    paywallStillPresented: paywall.map(PaywallDismissal.isStillPresented) ?? false
                )
                guard plan.closes else {
                    Log.info("Paywall \(paywallId): no on_success and the app already closed it — nothing to close")
                    return
                }
                PaywallDismissal.dismiss(paywall: paywall, presenter: viewController) {
                    if plan.reportsDismissed { delegate?.onPaywallDismissed(paywallId: paywallId) }
                }
            }
            return
        }
        let delay = Double(config.delay_ms ?? 2000) / 1000.0

        switch config.action {
        case "dismiss":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PaywallDismissal.dismiss(paywall: paywall, presenter: viewController)
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
                PaywallDismissal.dismiss(paywall: paywall, presenter: viewController) {
                    delegate?.onPaywallDismissed(paywallId: paywallId)
                }
            }

        case "deep_link":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PaywallDismissal.dismiss(paywall: paywall, presenter: viewController) {
                    delegate?.onPaywallDismissed(paywallId: paywallId)
                    if let url = config.deep_link_url {
                        delegate?.onPostPurchaseDeepLink(paywallId: paywallId, url: url)
                    }
                }
            }

        case "next_step":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PaywallDismissal.dismiss(paywall: paywall, presenter: viewController) {
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
            PaywallDismissal.dismiss(paywall: paywallController(paywallId), presenter: viewController)

        case "show_error", "retry":
            // Show error inline via notification (PaywallRenderer listens)
            // An EMPTY message or retry text falls back to the default, as on Android and in
            // the console preview. `??` alone kept "" and drew an empty red banner here, while Android
            // drew no banner at all for the same document.
            NotificationCenter.default.post(name: .paywallPurchaseFailure, object: nil, userInfo: [
                "message": config.message.flatMap { $0.isEmpty ? nil : $0 } ?? "Payment failed. Please try again.",
                "retry_text": config.retry_text.flatMap { $0.isEmpty ? nil : $0 } ?? "Try Again",
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
        contentStamp: [String: Any] = [:]
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
                // Refresh entitlements so onEntitlementsChanged fires after a paywall
                // restore too (matches Android + the direct restorePurchases path). Diff-guarded.
                // Queued, not awaited: `onPaywallRestoreCompleted` and the auto-dismiss must not
                // wait on `/billing/entitlements` (`refreshInBackground`).
                AppDNA.billing.refreshInBackground()
                // Fire delegate forward FIRST so a host
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
                    // /B — clear the public
                    // `skipNextAutoDismissOnRestore` flag on EVERY restore
                    // terminal event (success-with-products, empty-success,
                    // and the failure path below) so the one-shot flag
                    // can't leak from one paywall presentation into the
                    // next. Captured outside the early-return below.
                    let hostRequestedSkip = AppDNA.paywall.skipNextAutoDismissOnRestore
                    AppDNA.paywall.skipNextAutoDismissOnRestore = false

                    guard !restored.isEmpty else { return }
                    guard !dismissGuard.dispatched else { return }
                    // Honor the public host
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
                    self.eventTracker.track(event: "paywall_close", properties: ContentStamp.stamped([
                        "paywall_id": paywallId,
                        "dismiss_reason": "restore_success",
                    ], contentStamp))
                    PaywallDismissal.dismiss(paywall: self.paywallController(paywallId), presenter: viewController) {
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
                    // Clear the one-shot
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
            .sorted(by: isTriedBefore)
            .first { pw in
                guard pw.audience_rules != nil else { return true } // No rules = matches all
                return AudienceRuleEvaluator.evaluate(rules: pw.audience_rules, traits: traits)
            }
    }

    /// Several paywalls may answer one placement. They are tried in a fixed order, the same on every
    /// launch and on both platforms: higher priority, then a paywall with audience conditions before
    /// a catch-all, then lowest `id`. `getAllPaywalls()` is a dictionary, so without the last two the
    /// winner of a tie could change between launches.
    private static func isTriedBefore(_ a: PaywallConfig, _ b: PaywallConfig) -> Bool {
        let (pa, pb) = (AudienceRuleEvaluator.priority(rules: a.audience_rules), AudienceRuleEvaluator.priority(rules: b.audience_rules))
        if pa != pb { return pa > pb }
        let (ca, cb) = (AudienceRuleEvaluator.hasConditions(rules: a.audience_rules), AudienceRuleEvaluator.hasConditions(rules: b.audience_rules))
        if ca != cb { return ca }
        return (a.id ?? "") < (b.id ?? "")
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

extension PaywallManager {
    /// The paywall delegate's purchase success, for every purchase that leaves the user owning the plan — a re-buy of
    /// one they already own (`alreadyOwned`) included, as Android does. The user owns it either way, and a host closes
    /// its paywall on this callback. Revenue is a separate matter: an owned re-buy emits `purchase_restored`, not
    /// `purchase_completed`, and the billing delegate's `onPurchaseCompleted` stays silent for it.
    static func reportPaywallPurchaseCompleted(paywallId: String, result: PurchaseResult, delegate: AppDNAPaywallDelegate?) {
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
}
