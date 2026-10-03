import Foundation
#if SWIFT_PACKAGE
@_spi(AppDNAInternal) import AppDNANotificationExtension
#endif
import UIKit
import SwiftUI
import UserNotifications
import os
import FirebaseCore
import FirebaseFirestore

/// Main entry point for the AppDNA SDK.
/// All public methods are thread-safe.
public final class AppDNA: @unchecked Sendable {

    /// SDK version string.
    public static let sdkVersion = "1.0.82"

    /// Firestore instance used by the SDK.
    /// Uses a secondary Firebase app ("appdna") if GoogleService-Info-AppDNA.plist is found,
    /// otherwise falls back to the default Firebase app's Firestore instance.
    /// NOTE: Must NOT have a default value — Swift evaluates the default on first access
    /// (even writes), and Firestore.firestore() crashes if no default Firebase app exists.
    internal static var firestoreDB: Firestore?

    /// SPEC-419 brand-threading — the app's brand accent hex (from `/settings/brand`,
    /// served via Firestore `config/brand`). When set, SDK render defaults use it
    /// instead of the hardcoded #6366F1 brand indigo for accent/link/badge/selected
    /// colors. Per-element authored colors still take precedence over this.
    /// nil until the brand config loads (then defaults fall back to #6366F1).
    public internal(set) static var brandAccentHex: String?

    /// Notification posted when remote config is refreshed.
    public static let configUpdated = Notification.Name("AppDNA.configUpdated")

    /// Observer token for web entitlement changes (registered at most once).
    private static var webEntitlementObserverToken: NSObjectProtocol?
    /// Callbacks registered via `onWebEntitlementChanged`, keyed by their removal token.
    private static var webEntitlementChangeHandlers: [UUID: (WebEntitlement?) -> Void] = [:]

    // SPEC-428 CL-10/D7: bounded pre-init buffer at the STATIC facade — captures track() calls made
    // before configure() (when `shared.eventTracker` is still nil, so they'd otherwise no-op at the
    // facade and be dropped) and drains them in order once the pipeline is wired. Overflow is
    // drop-oldest + counted (CL-1). Mirrors Android's preInitBuffer.
    private static let preInitLock = NSLock()
    // SPEC-428 STEP-9/§4.E: each pre-init event STAMPS its client_seq at facade track() time (below) and
    // carries it through the drain — buildEnvelope uses it verbatim, never re-minting. Preserves the true
    // tracking order across configure() (a post-configure event minting during the drain window can no
    // longer get a lower seq than an earlier pre-init event drained after it).
    private static var preInitBuffer: [(event: String, properties: [String: Any]?, seq: Int64)] = []
    private static let preInitBufferCap = 200

    private static func drainPreInitBuffer() {
        preInitLock.lock()
        let buffered = preInitBuffer
        preInitBuffer.removeAll()
        preInitLock.unlock()
        guard !buffered.isEmpty else { return }
        Log.info("Draining \(buffered.count) pre-init events")
        for item in buffered {
            // Carry the seq stamped at track() time — do NOT re-mint at drain.
            shared.eventTracker?.track(event: item.event, properties: item.properties, clientSeq: item.seq)
        }
    }

    // MARK: - Delegates

    /// Delegate for push notification events (taps, receives).
    public static weak var pushDelegate: AppDNAPushDelegate?

    /// Delegate for billing/purchase events.
    ///
    /// Still a weak reference. Since it is stored by `AppDNA.billing` (with the
    /// `deliversPurchases` flag of `billing.setDelegate(_:deliversPurchases:)`); setting it here is
    /// `billing.setDelegate(newValue, deliversPurchases: true)`, which also delivers any purchase queued
    /// while no delegate was set.
    public static var billingDelegate: AppDNABillingDelegate? {
        get { billing.currentDelegate }
        set { billing.setDelegate(newValue, deliversPurchases: true) }
    }

    /// Delegate for server-driven screen events (SPEC-089c).
    public static weak var screenDelegate: AppDNAScreenDelegate?

    /// SPEC-070-C D10 — OPTIONAL async `onScreenAction` wrapper-veto. Set by a
    /// cross-platform wrapper (Flutter plugin) that must round-trip to answer a
    /// veto. Consulted by `ScreenManager.handleAction(...)` in ADDITION to the
    /// synchronous `screenDelegate.onScreenAction`; either can veto. Nil for
    /// native hosts → the action is performed synchronously exactly as before.
    /// (Held strongly — unlike `screenDelegate`, a closure has no other owner.)
    public static var asyncOnScreenAction: ((String, SectionAction) async -> Bool)?

    /// SPEC-404 — lifecycle delegate. Fires `onSdkRuntimeLocked` once when
    /// the bootstrap response carries a `runtime_lock`, and
    /// `onSdkRuntimeUnlocked` once when a subsequent bootstrap returns
    /// without one. Hosts use this to surface a custom "service unavailable"
    /// banner and to trigger a one-shot event-queue retry on unlock.
    public static weak var lifecycleDelegate: AppDNALifecycleDelegate?

    /// SPEC-404 — current backend-driven SDK lock state. `nil` when active;
    /// a non-nil value means the SDK is in locked mode and UI render paths
    /// (paywall_trigger, messages, surveys) should pause. Set by the
    /// bootstrap completion handler; cleared by the next bootstrap that
    /// returns without `runtime_lock`. Synchronised via the internal `queue`.
    public private(set) static var runtimeLock: BootstrapRuntimeLock?

    /// Internal accessor for the push token manager (legacy).
    static var push: PushTokenManager? { shared.pushTokenManager }
    static var geocodeClient: APIClient? { shared.apiClient }
    /// SPEC-448 — the Option Set store's client. Same accessor shape as `geocodeClient`;
    /// nil before `configure()`, which the store treats as "no refresh possible" rather than
    /// an error, so the fallback ladder still renders.
    static var optionSetClient: APIClient? { shared.apiClient }
    /// The client billing's server calls (`/billing/verify`, `/billing/entitlements`) use. Nil before
    /// `configure()` and after `shutdown()`: a verification then stays queued, and an entitlement
    /// refresh falls back to local StoreKit state.
    static var billingAPIClient: APIClient? { shared.apiClient }

    // MARK: - Module Namespaces (v1.0)

    /// Push notification module.
    public static let pushModule = PushModule(manager: nil)
    /// Billing module.
    public static let billing = BillingModule()
    /// Onboarding module.
    public static let onboarding = OnboardingModule(manager: nil)
    /// Paywall module.
    public static let paywall = PaywallModule(manager: nil)
    /// Remote config module.
    public static let remoteConfig = RemoteConfigModule(manager: nil)
    /// Feature flags module.
    public static let features = FeaturesModule(manager: nil)
    /// In-app messages module.
    public static let inAppMessages = InAppMessagesModule(manager: nil)
    /// Surveys module.
    public static let surveys = SurveysModule(manager: nil)
    /// Deep links module.
    public static let deepLinks = DeepLinksModule()
    /// Experiments module.
    public static let experiments = ExperimentsModule(manager: nil)

    // MARK: - Custom View Registry (SPEC-089d AC-026)

    /// Registry of developer-provided custom views keyed by `view_key`.
    /// Used by the `custom_view` content block to render developer escape-hatch views.
    public static var registeredCustomViews: [String: () -> AnyView] = [:]

    /// Register a custom SwiftUI view factory for use in onboarding content blocks.
    /// - Parameters:
    ///   - key: The `view_key` value from the block config.
    ///   - factory: A closure returning an `AnyView`.
    public static func registerCustomView(_ key: String, factory: @escaping () -> AnyView) {
        registeredCustomViews[key] = factory
    }

    // MARK: - Map View Registry (SPEC-451)

    /// Host-provided interactive map views, keyed by the map block's `map_view_key`
    /// (or `"default"` when the block names none).
    public static var registeredMapViews: [String: ([String: Any]) -> AnyView] = [:]

    /// Register an interactive map for the `map` content block.
    ///
    /// 🔴 The factory RECEIVES THE AUTHORED CONFIG — stops, route styling, mode, zoom — which is
    /// the whole reason this exists rather than pointing hosts at `registerCustomView`. With an
    /// opaque view the growth team can place a map and change nothing about it without an app
    /// release; here they keep control of the content and the developer supplies only the canvas.
    ///
    /// Registering nothing is a supported state, not a failure: the block falls back to a static
    /// map image, which needs no native dependency and no key in the binary.
    ///
    /// - Parameters:
    ///   - key: matches the block's `map_view_key`; use `"default"` for every map block.
    ///   - factory: builds the view from the block's resolved config. Keys are documented in
    ///     SPEC-451 §4 and mirror what the console writes.
    public static func registerMapView(_ key: String = "default", factory: @escaping ([String: Any]) -> AnyView) {
        registeredMapViews[key] = factory
    }

    /// The Mapbox access token the `map` block's static images are fetched with.
    ///
    /// Normally the customer sets this once in the console and it arrives on every bootstrap — no
    /// host code at all. Setting it here overrides that, for hosts who would rather keep the token
    /// out of a network response and in their own binary.
    ///
    /// 🔴 It is always the CUSTOMER's token, never ours. Mapbox's terms forbid us proxying or
    /// caching the imagery, so the device fetches it directly and the request bills to whoever
    /// owns the token (SPEC-451 §5). A host token set here wins over the bootstrap value forever —
    /// an explicit choice beats a remote default.
    public static var mapboxToken: String? {
        get { hostMapboxToken ?? remoteMapboxToken ?? UserDefaults.standard.string(forKey: mapboxTokenDefaultsKey) }
        set { hostMapboxToken = newValue }
    }

    private static var hostMapboxToken: String?
    private static var remoteMapboxToken: String?
    /// SPEC-495 §B — the customer's Google Maps key, delivered exactly like the Mapbox token.
    ///
    /// 🔴 Always the CUSTOMER's key, never ours: Google bills per static request and per interactive
    /// session, so the device fetches directly and the request bills to whoever owns the key. A host
    /// key set here wins over the bootstrap value forever, matching `mapboxToken`.
    ///
    /// Server-delivered rather than host-set is what lets a Flutter or React Native app use Google
    /// maps with no extra wiring: the wrapper never has to expose a setter.
    public static var googleMapsApiKey: String? {
        get { hostGoogleKey ?? remoteGoogleKey ?? UserDefaults.standard.string(forKey: googleKeyDefaultsKey) }
        set { hostGoogleKey = newValue }
    }

    private static var hostGoogleKey: String?
    private static var remoteGoogleKey: String?
    private static let googleKeyDefaultsKey = "appdna.google_maps_api_key"

    internal static func applyRemoteGoogleMapsKey(_ key: String?) {
        remoteGoogleKey = key
        if let key, !key.isEmpty { UserDefaults.standard.set(key, forKey: googleKeyDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: googleKeyDefaultsKey) }
    }

    /**
     SPEC-495 — the app's map engine (`mapbox` | `google`), delivered with the keys it selects
     between.

     🔴 App-level, and that is a correction. The provider began as a per-block field, which let an
     author choose an engine their app had no key for and get a silent placeholder on device. It is
     set once in the console beside the credentials, and arrives here the same way they do. A block
     that still names a provider wins, so flows published before this keep rendering unchanged.

     Cached in `UserDefaults` for the same reason the tokens are: the FIRST render after a cold
     launch happens before the bootstrap round-trip returns, and a map that flips engine a second
     later is worse than one that starts on the engine it ended on.
     */
    public static var mapProvider: String? {
        get { hostMapProvider ?? remoteMapProvider ?? UserDefaults.standard.string(forKey: mapProviderDefaultsKey) }
        set { hostMapProvider = newValue }
    }

    private static var hostMapProvider: String?
    private static var remoteMapProvider: String?
    private static let mapProviderDefaultsKey = "appdna.map_provider"

    internal static func applyRemoteMapProvider(_ provider: String?) {
        remoteMapProvider = provider
        if let provider, !provider.isEmpty { UserDefaults.standard.set(provider, forKey: mapProviderDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: mapProviderDefaultsKey) }
    }

    private static let mapboxTokenDefaultsKey = "appdna.mapbox_token"

    /// Cached across launches so the very first onboarding of a cold, offline start still draws a
    /// map rather than the fallback text. Bootstrap has not answered yet at that point.
    internal static func applyRemoteMapboxToken(_ token: String?) {
        remoteMapboxToken = token
        if let token, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: mapboxTokenDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: mapboxTokenDefaultsKey)
        }
    }

    // MARK: - Config Bundle (v1.0)

    /// Current config bundle version reported by events.
    internal static var currentBundleVersion: Int = 0

    /// SPEC-070-C D4 — the configured SDK-wrapper framework tag (native|flutter|
    /// react_native); tagged on every event's device context. Defaults to "native".
    internal static var framework: String { shared.options.framework }

    /// SPEC-070-B §7 rule 4 — the WRAPPER's own version (e.g. the npm package's `1.0.7`), injected by
    /// the bridge, tagged on every event's device context as `framework_version`.
    ///
    /// `device.sdk_version` is always this NATIVE core's version, so before this field existed a
    /// React Native app was indistinguishable from a native one in the warehouse on every version
    /// column: all 79 `react_native` rows in `raw.sdk_events` carried `sdk_version = 1.0.70`, the core
    /// they wrap. Which meant the question support actually asks — "is the fix in the version they are
    /// running?" — had no answer, because the artifact an RN developer INSTALLS is the npm package and
    /// nothing reported it. The value was already carried all the way into `options.frameworkVersion`
    /// and then read by exactly one thing, `diagnose()`, which prints to the developer's own console.
    ///
    /// Nil for a native host (there is no wrapper to name); the envelope omits it in that case.
    internal static var frameworkVersion: String? {
        shared.options.framework == "native" ? nil : shared.options.frameworkVersion
    }

    // MARK: - Screen attribution (SPEC-070-B PN row 1 / D-h)

    /// The most recent screen name announced by `notifyScreenAppeared`, surfaced into every event
    /// envelope as `context.screen`. Android has carried this since SPEC-070-A G.17; iOS never did,
    /// so `context.screen` was hardcoded nil on every iOS event.
    /// Written from any thread (a host may announce from a background task), read on the event queue.
    private static let screenNameLock = NSLock()
    private static var _lastScreenName: String?
    internal static var lastScreenName: String? {
        get { screenNameLock.lock(); defer { screenNameLock.unlock() }; return _lastScreenName }
        set { screenNameLock.lock(); _lastScreenName = newValue; screenNameLock.unlock() }
    }

    /// Notify the SDK that a screen has appeared. UIKit hosts get this automatically once
    /// `enableNavigationInterception()` is called; SwiftUI-only and React Native hosts must call it
    /// themselves from the screen's `onAppear`.
    public static func notifyScreenAppeared(_ screenName: String) {
        lastScreenName = screenName
        ScreenManager.shared.evaluateInterceptions(screenName: screenName, timing: "after")
    }

    // MARK: - Degraded init (SPEC-070-B PN row 2 / D-k)

    /// The most recent non-fatal error raised during `configure()` or bootstrap. Non-nil means the
    /// SDK started, but some subsystem did not. Analytics are the floor guarantee and keep working
    /// (AC-31(b)); a host reads this to decide whether, say, remote config is trustworthy.
    /// Mirrors Android's `AppDNA.lastInitError` (`AppDNA.kt:78`).
    private static let initErrorLock = NSLock()
    private static var _lastInitError: Error?
    public static var lastInitError: Error? {
        initErrorLock.lock(); defer { initErrorLock.unlock() }; return _lastInitError
    }

    private static var _initDelegate: AppDNAInitDelegate?
    /// Register a delegate for `onInitDegraded`. If the SDK is already degraded when the delegate
    /// registers, the pending error is delivered once — a late-binding host never misses it.
    public static var initDelegate: AppDNAInitDelegate? {
        get { initErrorLock.lock(); defer { initErrorLock.unlock() }; return _initDelegate }
        set {
            initErrorLock.lock()
            _initDelegate = newValue
            let pending = _lastInitError
            initErrorLock.unlock()
            if let pending, let newValue {
                DispatchQueue.main.async { newValue.onInitDegraded(reason: pending) }
            }
        }
    }

    /// Clear the degraded-init state. Test seam — `shutdown()` does this too, but a test that only
    /// wants a clean `lastInitError` should not have to tear the whole SDK down.
    internal static func resetInitStateForTesting() {
        initErrorLock.lock()
        _lastInitError = nil
        _initDelegate = nil
        initErrorLock.unlock()
    }

    /// Record a non-fatal init error and notify the delegate on the main thread. Idempotent per
    /// error: the delegate fires on every report, matching Android's `reportInitDegraded`.
    internal static func reportInitDegraded(_ error: Error) {
        initErrorLock.lock()
        _lastInitError = error
        let delegate = _initDelegate
        initErrorLock.unlock()
        Log.warning("AppDNA init degraded: \(error.localizedDescription)")
        guard let delegate else { return }
        DispatchQueue.main.async { delegate.onInitDegraded(reason: error) }
    }

    // MARK: - Veto-timeout accounting (SPEC-070-B PN row 16 / W12)

    /// Record that a host veto timed out and fell back to its default.
    ///
    /// The counter is internal to this module, and the only code that can observe a veto timing out
    /// lives in a wrapper — the SDK itself awaits a veto forever. So the counter shipped with a
    /// reader (`diagnose()`) and no writer, and its line read `timed out 0 time(s)` no matter what.
    /// This is the writer.
    public static func recordVetoTimeout() {
        VetoTimeoutCounter.increment()
    }

    // MARK: - Subsystem init isolation (SPEC-070-B PN row 17 / W13 / AC-31(b))

    /// Names of subsystems to fail on purpose. Test-only: AC-31(b) has to inject a failure to prove
    /// the isolation holds, and a reporting seam that is never exercised is not isolation.
    internal static var subsystemInitFailures: Set<String> = []

    /// Build one subsystem in isolation. A subsystem that fails to start is reported as degraded and
    /// left nil; the event pipeline — wired earlier, in `performConfigure` — keeps running either way.
    /// Analytics is the floor guarantee, exactly as at Amplitude and Firebase.
    ///
    /// 🔴 `internal`, not `private`. While it was private, the test that claimed to prove this
    /// isolation could not call it — so it RE-IMPLEMENTED the do/catch inline and asserted on its own
    /// copy. Deleting this function left that test green. A test that cannot fail when the code it
    /// covers is deleted is not a test.
    internal static func initSubsystem<T>(_ name: String, _ make: () throws -> T) -> T? {
        do {
            if subsystemInitFailures.contains(name) {
                throw AppDNAInitError.subsystemFailed(name: name, message: "injected failure")
            }
            return try make()
        } catch {
            reportInitDegraded(AppDNAInitError.subsystemFailed(name: name, message: error.localizedDescription))
            return nil
        }
    }

    /// Which subsystems came up on the last `configure()`. Mirrors Android's `AppDNA.subsystemsUp()`.
    ///
    /// AC-31(b) is *"a failing subsystem leaves ANALYTICS WORKING"*, and AC-31(a) — the error is
    /// surfaced — is explicitly **not** that: a reporting seam says nothing about what survived. The
    /// claim needs an observer for what came up and what did not, and until now iOS had none, so the
    /// only iOS test of `initSubsystem` called it in isolation and never ran a `configure()` at all.
    ///
    /// `events` is the floor guarantee: the tracker and the queue are both wired in `performConfigure`,
    /// BEFORE any subsystem is constructed, and no subsystem failure can unwire them.
    internal static func subsystemsUp() -> [String: Bool] {
        [
            "events": shared.eventTracker != nil && shared.eventQueue != nil,
            "paywall": shared.paywallManager != nil,
            "onboarding": shared.onboardingFlowManager != nil,
            "in_app_messages": shared.messageManager != nil,
            "surveys": shared.surveyManager != nil,
            "web_entitlements": shared.webEntitlementManager != nil,
            // Reads the FACADE, not `shared.billingBridge`. Those are two different references, and the
            // shadow one is not the one a host buys through: `AppDNA.billing.purchase()` goes through
            // `AppDNA.billing.bridge`. `shutdown()` used to nil only `shared.billingBridge`, so an
            // oracle reading `shared` would have reported billing DOWN while the facade was still
            // charging real money. An oracle must read the variable the caller actually uses.
            "billing": AppDNA.billing.isLive,
        ]
    }

    /// The live `EventTracker`, so a test can observe an event actually reaching the pipeline rather
    /// than merely observing that `track()` did not throw. Its `eventSink` fires on every enqueue.
    internal static var eventTrackerForTesting: EventTracker? { shared.eventTracker }

    /// Test-only: install a capturing tracker as the SDK's event tracker (under the same
    /// lock `configure` publishes it under), so a test can drive the PUBLIC `AppDNA.track`. Mirrors
    /// Android `installEventTrackerForTest`. Pass nil to uninstall.
    internal static func installEventTrackerForTest(_ tracker: EventTracker?) {
        preInitLock.lock()
        shared.eventTracker = tracker
        preInitLock.unlock()
    }

    /// Test-only: drain the pre-init buffer into the installed tracker (what `configure` does).
    internal static func drainPreInitBufferForTesting() {
        drainPreInitBuffer()
    }

    /// Test-only: wait until everything already enqueued on the SDK's serial queue has run.
    internal static func drainSDKQueueForTesting() {
        shared.queue.sync {}
    }

    /// Test-only: how many times `performConfigure` actually built the SDK (i.e. was NOT superseded
    /// by a later configure()/shutdown()). A `configure(); shutdown(); configure()` on one tick must
    /// leave this at 1 — the first, superseded build must be a no-op. See `configureEpoch`.
    private static let performConfigureCountLock = NSLock()
    private static var _performConfigureCount = 0
    internal static var performConfigureCountForTesting: Int {
        performConfigureCountLock.lock(); defer { performConfigureCountLock.unlock() }
        return _performConfigureCount
    }
    internal static func resetPerformConfigureCountForTesting() {
        performConfigureCountLock.lock(); _performConfigureCount = 0; performConfigureCountLock.unlock()
    }

    // MARK: - Singleton

    private static let shared = AppDNA()
    private let queue = DispatchQueue(label: "ai.appdna.sdk.main", qos: .utility)

    // MARK: - Internal managers

    private var apiKey: String?
    private var environment: Environment = .production
    private var options: AppDNAOptions = AppDNAOptions()

    internal var apiClient: APIClient?
    private var identityManager: IdentityManager?
    private var sessionManager: SessionManager?
    private var eventTracker: EventTracker?
    private var eventQueue: EventQueue?
    private var remoteConfigManager: RemoteConfigManager?
    private var featureFlagManager: FeatureFlagManager?
    private var experimentManager: ExperimentManager?
    private var paywallManager: PaywallManager?
    private var billingBridge: BillingBridgeProtocol?
    /// Emits `subscription_renewed` / `subscription_canceled` / `subscription_renewal_failed` — the ONLY
    /// emitter of those three in the whole SDK, under EVERY billing provider (the RevenueCat and Adapty
    /// bridges emit purchase events only). Without it, iOS emitted no subscription-lifecycle event at all
    /// and every renewal was invisible to analytics. See `Billing/SubscriptionStatusObserver.swift`.
    private var subscriptionObserver: SubscriptionStatusObserver?
    private var onboardingFlowManager: OnboardingFlowManager?
    private var messageManager: MessageManager?
    private var pendingMessageListener: PendingMessageListener?
    private var pushTokenManager: PushTokenManager?
    private var surveyManager: SurveyManager?
    private var webEntitlementManager: WebEntitlementManager?
    private var deferredDeepLinkManager: DeferredDeepLinkManager?
    private var screenManager: ScreenManager?

    private var bootstrapData: BootstrapData?
    /// The runtime settings in force (`RuntimeSettings`): resolved at configure, re-resolved when a bootstrap
    /// answer is applied. On `queue`.
    private var runtimeSettings: RuntimeSettings.Resolved?
    /// The config cache of the current configure, so a recovered bootstrap can change its TTL. On `queue`.
    private var runtimeConfigCache: ConfigCache?

    /// Double-`configure()` guard. Set the INSTANT `configure()` is entered, long before the SDK can
    /// do anything — so it must never be used to answer "is the SDK usable yet".
    private var isConfigured = false

    /// Monotonic configure generation, bumped under `initLock` on every accepted `configure()` AND on
    /// every `shutdown()`. `performConfigure` captures the value it was scheduled with and bails if a
    /// newer configure has since superseded it; `performBootstrap` carries the same value and drops its
    /// result when the epoch has moved on (see `isCurrentConfigure(_:)`). Without this, `configure(); shutdown(); configure()` on one tick
    /// schedules the FIRST configure's `performConfigure` (which `shutdown` no longer no-ops away,
    /// now that isConfigured is cleared synchronously) to run right before the second's — building
    /// the pipeline, observers and timers twice with no teardown between. The epoch makes the stale
    /// build a no-op so exactly the latest configure wins.
    private var configureEpoch = 0

    /// True while `epoch` is still the live configure: no `shutdown()` and no later `configure()` has
    /// happened since it was accepted. Read under the lock `configure()` / `shutdown()` write under.
    private func isCurrentConfigure(_ epoch: Int) -> Bool {
        initLock.lock(); defer { initLock.unlock() }
        return isConfigured && configureEpoch == epoch
    }

    /// Test-only: how many bootstrap results were applied (managers built, ready) and how many were
    /// dropped as stale. Every `performBootstrap` ends in exactly one of the two, on `queue`.
    private static let bootstrapOutcomeLock = NSLock()
    private static var _bootstrapsApplied = 0
    private static var _bootstrapsDropped = 0
    internal static var bootstrapOutcomesForTesting: (applied: Int, dropped: Int) {
        bootstrapOutcomeLock.lock(); defer { bootstrapOutcomeLock.unlock() }
        return (_bootstrapsApplied, _bootstrapsDropped)
    }
    private static func recordBootstrapOutcome(applied: Bool) {
        bootstrapOutcomeLock.lock()
        if applied { _bootstrapsApplied += 1 } else { _bootstrapsDropped += 1 }
        bootstrapOutcomeLock.unlock()
    }
    /// Test-only: the ready flag and the org id of the bootstrap that was applied, read on `queue`.
    internal static var isReadyForTesting: Bool { shared.queue.sync { shared.isReady } }
    internal static var bootstrapOrgIdForTesting: String? { shared.queue.sync { shared.bootstrapData?.orgId } }
    /// Test reader: the event queue of the current configure.
    internal static var eventQueueForTesting: EventQueue? { shared.queue.sync { shared.eventQueue } }
    /// Test reader: the runtime settings last resolved (at configure, then at each applied bootstrap).
    internal static var runtimeSettingsForTesting: RuntimeSettings.Resolved? { shared.queue.sync { shared.runtimeSettings } }

    /// What `onReady` actually waits for: bootstrap has settled and the managers are wired.
    ///
    /// This used to be `isConfigured`, and one flag doing both jobs is why `onReady` fired
    /// immediately: the guard is set before `performConfigure` even runs. A host that did
    /// `await onReady(); getRemoteConfig(k)` got `nil` — the config had not been fetched yet — and
    /// nothing failed loudly, so it read as "that key isn't set". Android already keeps the two
    /// separate and fires ready inside its bootstrap; iOS now matches it.
    private var isReady = false

    private var readyCallbacks: [() -> Void] = []

    private init() {}

    // MARK: - Public API: Initialization

    /// Register the SDK's BGTaskScheduler identifiers with the system.
    ///
    /// **Call this from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// BEFORE the method returns — and before `AppDNA.configure()`.**
    ///
    /// Apple requires `BGTaskScheduler.register(...)` to happen during app launch.
    /// Calling it later (from `SceneDelegate`, `SwiftUI.onAppear`, or an async block)
    /// crashes with: *"All launch handlers must be registered before application
    /// finishes launching"*.
    ///
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    /// ) -> Bool {
    ///     AppDNA.registerBackgroundTasks()   // MUST be first, synchronously
    ///     AppDNA.configure(apiKey: "your-api-key")
    ///     return true
    /// }
    /// ```
    ///
    /// This call is idempotent — multiple calls are no-ops.
    /// If you don't call this, the SDK logs a warning and background event
    /// uploads are disabled (the app still works normally, events upload on
    /// next foreground session).
    public static func registerBackgroundTasks() {
        BackgroundUploader.registerBackgroundTaskIdentifier()
    }

    /// Configure the SDK. Call once at app launch. Subsequent calls are ignored.
    /// Firebase is initialized on the main thread first, then the rest runs on a background queue.
    public static func configure(
        apiKey: String,
        environment: Environment = .production,
        options: AppDNAOptions = AppDNAOptions()
    ) {
        // Guard against multiple calls — atomic check before async dispatch
        shared.initLock.lock()
        guard !shared.isConfigured else {
            shared.initLock.unlock()
            Log.warning("AppDNA.configure() called multiple times — ignoring")
            return
        }
        shared.isConfigured = true
        shared.configureEpoch &+= 1
        let epoch = shared.configureEpoch
        shared.initLock.unlock()

        // Firebase MUST be initialized on the main thread to avoid main-thread checker warnings.
        DispatchQueue.main.async {
            shared.initializeFirebase()
            // Then do the rest on background queue
            shared.queue.async {
                shared.performConfigure(apiKey: apiKey, environment: environment, options: options, epoch: epoch)
            }
        }
    }

    // MARK: - Public API: Identity

    /// Link the anonymous device to a known user.
    public static func identify(userId: String, traits: [String: Any]? = nil) {
        shared.queue.async {
            let previousAnonId = shared.identityManager?.currentIdentity.anonId
            let previousUserId = shared.identityManager?.currentIdentity.userId

            // Cross-account-leak defence — anchor the device's "first
            // identifier" the first time anyone identifies. Untagged
            // historical transactions (e.g. SDK-driven onboarding-paywall
            // purchases that fired BEFORE the host identified anyone) are
            // scoped to this anchor so a later user-switch can't inherit
            // them. Idempotent — a later `identify(B)` does NOT change
            // the anchor; that user gets `denyUntaggedOtherUser` for
            // untagged transactions. See `EntitlementOwnerFilter`.
            //
            // Recorded BEFORE the inner `identityManager.identify(...)`
            // call so that any synchronous downstream observer (event
            // listener, notification, etc.) that immediately reads
            // `firstIdentifiedToken()` sees the anchor populated.
            // Everything inside this block runs on `shared.queue`
            // (serial) so the read-modify-write under the hood is not
            // racy across concurrent identify() calls.
            AppAccountTokenResolver.recordFirstIdentifiedUserIdIfNeeded(userId)

            // Identity changed → clear the device-global subscription snapshot, or the new user's first
            // reconcile diffs their (user-filtered) entitlements against the PREVIOUS user's snapshot and
            // fabricates a phantom subscription_canceled/_renewal_failed. A fresh baseline emits nothing.
            if previousUserId != userId {
                SubscriptionStatusObserver.clearPersistedSnapshot()
            }

            shared.identityManager?.identify(userId: userId, traits: traits)
            Log.info("Identified user: \(userId)")

            // Fire identify event for backend alias/merge
            var identifyProps: [String: Any] = [
                "user_id": userId,
                "anon_id": previousAnonId ?? "",
            ]
            if let prev = previousUserId, prev != userId {
                identifyProps["previous_user_id"] = prev
            }
            if let traits = traits {
                identifyProps["traits"] = traits
            }
            // SPEC-428 CL-10/D7: route identify through the facade so a pre-configure() identify() is
            // captured by the pre-init buffer too (was a direct eventTracker?.track → silently dropped).
            AppDNA.track(event: "identify", properties: identifyProps)

            // Send identify to backend alias endpoint
            var aliasBody: [String: Any] = [
                "anon_id": previousAnonId ?? "",
                "user_id": userId,
            ]
            if let traits = traits { aliasBody["traits"] = traits }
            shared.apiClient?.post(path: "/api/v1/sdk/identify", body: aliasBody) { result in
                switch result {
                case .success: Log.debug("Identity alias synced: \(previousAnonId ?? "?") → \(userId)")
                case .failure(let err): Log.debug("Identity alias sync failed: \(err.localizedDescription)")
                }
            }

            // Start web entitlement observer for this user (v0.3)
            if let bootstrapData = shared.bootstrapData {
                shared.webEntitlementManager?.startObserving(
                    orgId: bootstrapData.orgId,
                    appId: bootstrapData.appId,
                    userId: userId
                )
                // SPEC-203: start journey-triggered pending-messages listener.
                shared.pendingMessageListener?.startObserving(
                    orgId: bootstrapData.orgId,
                    appId: bootstrapData.appId,
                    userId: userId
                )
            }

            // SPEC-401 Fix 1D — silently refresh the entitlement cache so
            // the next paywall_trigger entitlement gate (Fix 1A) reflects
            // the identified user's current StoreKit subscriptions, not
            // the prior anonymous user's empty entitlements. Fire-and-
            // forget; identify is not blocked on completion. Errors are
            // swallowed inside refreshEntitlementCache.
            Task {
                await AppDNA.billing.refreshEntitlementCache()
            }

            // Trigger (iii): a purchase queued for this user (or deferred to them as
            // its owner) is emitted / delivered now.
            Task {
                await PurchaseDeliveryQueue.shared.drain()
            }
        }
    }

    /// Clear user identity (keeps anonymous ID).
    ///
    /// Resets the host-supplied user identity, experiment exposures, the
    /// in-app message session, the survey session, the web-entitlement
    /// observer, and the journey-triggered pending-message listener.
    /// **Does NOT clear the device's first-identifier anchor used by
    /// the cross-account-entitlement-leak defence** (see
    /// `EntitlementOwnerFilter`) — that anchor is intentionally durable
    /// for the lifetime of the app installation. App uninstall (or
    /// Settings → App → Clear data on Android) is the only path that
    /// wipes it. This makes `reset()` safe to call as the host's
    /// "sign-out" hook without re-opening the leak surface for a
    /// subsequent user signing in on the same device.
    public static func reset() {
        shared.queue.async {
            shared.identityManager?.reset()
            shared.experimentManager?.resetExposures()
            shared.messageManager?.resetSession()
            shared.surveyManager?.resetSession()
            shared.webEntitlementManager?.stopObserving()
            shared.pendingMessageListener?.stopObserving()
            // The subscription snapshot is device-global; identity is not. Clear it on sign-out so the
            // next user's first reconcile does not diff their entitlements against this user's snapshot
            // and fabricate a phantom subscription_canceled/_renewal_failed. See clearPersistedSnapshot().
            SubscriptionStatusObserver.clearPersistedSnapshot()
            // The server-only entitlement rows (a purchase on another platform) of the signed-out user are
            // cleared, and — when the SDK reads StoreKit itself (StoreKit 2, or RevenueCat / Adapty not
            // linked into this build) — one entitlement refresh is queued so `onEntitlementsChanged` reports
            // the signed-out state (the device's StoreKit set without those rows). Under RevenueCat / Adapty
            // linked into a source build, or with no billing provider, none (`signOutRefreshes`).
            AppDNA.billing.signOut()

            // 🔴 USER A'S ONBOARDING ANSWERS SURVIVED THE SIGN-OUT AND RENDERED INTO USER B'S PAYWALL.
            //
            // `SessionDataStore` is a PERSISTED process-global (UserDefaults here, SharedPreferences on
            // Android) holding three buckets: onboarding responses, computed data, session data. `reset()`
            // cleared identity, exposures, message and survey session — and never touched it. Neither did
            // `shutdown()`. `clearAll()` existed on both platforms with ZERO callers.
            //
            // So after A signed out and B signed in on the same device, B could read A's onboarding
            // answers and structured location back via `getOnboardingResponses()` / `session.get(key)` /
            // `getLocationData(fieldId)`. And worse than the read: `TemplateEngine.buildContext()` feeds
            // all three buckets into the `{{…}}` namespace, so A's answers RENDERED INTO B's paywall,
            // onboarding and in-app-message copy. It survived app restarts. All four SDKs.
            //
            // `reset()` IS the sign-out boundary — it is already where identity, exposures and session
            // state go — and onboarding responses are per-user data that must not outlive the user.
            //
            // `shutdown()` deliberately does NOT do this: it is a lifecycle stop, not a user change.
            // Clearing a user's answers because the app is backgrounding would be a different bug.
            SessionDataStore.shared.clearAll()

            // Cross-account-leak defence — DELIBERATELY do NOT call
            // `AppAccountTokenResolver.clearFirstIdentifiedUserId()`
            // here. The anchor is a security boundary: clearing it on
            // sign-out would let the next `identify(B)` become the new
            // first-identifier and inherit any untagged purchase on
            // the device (the exact reproducer R2 surfaced). The
            // anchor's natural lifecycle is the app installation;
            // factory-reset / uninstall wipe UserDefaults, which is
            // the correct invalidation event.
            Log.info("Identity reset (session data cleared)")
        }
    }

    // MARK: - Public API: Events

    /// Track a custom event.
    public static func track(event: String, properties: [String: Any]? = nil) {
        // `emitted_by` marks the SDK's OWN billing events and `_appdna_origin` is
        // a server-only marker; a host may forge neither. Stripped FIRST, before the pre-init buffer
        // decision, so a buffered event is stripped too. (The SDK's billing emitters never come through
        // here — they track on the `EventTracker` directly, with `BillingEventProps.marked`.)
        let properties = BillingEventProps.strippingReservedKeys(properties)
        // SPEC-428 CL-10/D7 + F2: before configure() the pipeline isn't wired — buffer instead of dropping.
        // Double-checked locking (mirrors Android): fast path reads eventTracker with no lock; if nil, take
        // preInitLock (which configure() holds while it publishes eventTracker) and RE-CHECK — still nil →
        // buffer (pre-configure); set → fall through to mint. This makes the buffer-vs-mint decision
        // mutually exclusive with the publish, closing the buffer-after-drain STRAND race (an event offered
        // after the drain would be enqueued nowhere and silently lost).
        if shared.eventTracker == nil {
            preInitLock.lock()
            if shared.eventTracker == nil {
                let seq = ClientSeqCounter.next() // stamp NOW under the lock, in tracking order
                if preInitBuffer.count >= preInitBufferCap {
                    preInitBuffer.removeFirst() // drop-oldest
                    DroppedEventsCounter.increment(1) // SPEC-428 CL-1: count the pre-init overflow drop
                }
                preInitBuffer.append((event, properties, seq))
                preInitLock.unlock()
                return
            }
            preInitLock.unlock() // configure() published while we waited → mint below (seq lands above the block)
        }
        shared.queue.async {
            shared.eventTracker?.track(event: event, properties: properties)
            // Evaluate in-app messages on every tracked event
            shared.messageManager?.onEvent(eventName: event, properties: properties)
            // Evaluate surveys on every tracked event (v0.3)
            shared.surveyManager?.onEvent(eventName: event, properties: properties)
        }
    }

    /// Force flush all queued events immediately.
    public static func flush() {
        shared.queue.async {
            // Host-initiated: clear the failure-pause gate (matches Android's public flush()).
            shared.eventQueue?.flushClearingPause()
        }
    }

    // MARK: - Public API: Remote Config

    /// Get a remote config value by key.
    public static func getRemoteConfig(key: String) -> Any? {
        shared.remoteConfigManager?.getConfig(key: key)
    }

    /// SPEC-067: Force an immediate config refresh, bypassing the cache TTL.
    public static func forceRefreshConfig() {
        shared.remoteConfigManager?.forceRefresh()
    }

    /// Check if a feature flag is enabled.
    public static func isFeatureEnabled(flag: String) -> Bool {
        shared.featureFlagManager?.isEnabled(flag: flag) ?? false
    }

    // MARK: - Internal accessors for SDK modules (SPEC-083, SPEC-088)

    /// Current user ID (or anonymous ID).
    static var currentUserId: String? {
        shared.identityManager?.currentIdentity.userId ?? shared.identityManager?.currentIdentity.anonId
    }

    /// Current app ID from bootstrap.
    static var currentAppId: String? {
        shared.bootstrapData?.appId
    }

    /// Resolve a remote config flag value as a string (for webhook header interpolation).
    static func getRemoteConfigFlag(_ key: String) -> String? {
        shared.remoteConfigManager?.getConfig(key: key) as? String
    }

    /// Internal reference to identity manager for TemplateEngine (SPEC-088).
    static var identityManagerRef: IdentityManager? {
        shared.identityManager
    }

    // MARK: - Public API: Experiments

    /// Get the variant assignment for an experiment: the variant ID set in the Console, or nil when the user is not
    /// in the experiment — it is not running (or not in the config yet), does not target iOS, a targeting rule
    /// excludes the user, or the user is outside the traffic allocation (or the SDK is not configured).
    /// The `experiment_exposure` event is tracked automatically on the first assignment of each experiment, once
    /// until `reset()` or the next app launch (exposures are kept in memory; a new session does not reset them).
    /// A nil answer tracks nothing.
    public static func getExperimentVariant(experimentId: String) -> String? {
        shared.experimentManager?.getVariant(experimentId: experimentId)
    }

    /// Check if the user is in a specific variant.
    public static func isInVariant(experimentId: String, variantId: String) -> Bool {
        shared.experimentManager?.isInVariant(experimentId: experimentId, variantId: variantId) ?? false
    }

    /// Get a specific config value from the assigned variant's payload.
    public static func getExperimentConfig(experimentId: String, key: String) -> Any? {
        shared.experimentManager?.getExperimentConfig(experimentId: experimentId, key: key)
    }

    // MARK: - Public API: Paywalls

    /// Present a paywall modally from the given view controller.
    ///
    /// - Returns: `false` when NOTHING will be presented — the SDK is runtime-locked, was never
    ///   configured, or no paywall with this id exists in the published config. `presentOnboarding`
    ///   and `showScreen` have always reported this; `presentPaywall` returned `Void`, so every
    ///   wrapper resolved its promise SUCCESSFULLY on a typo'd id and the host was told a paywall it
    ///   never saw had been shown.
    @discardableResult
    public static func presentPaywall(
        id: String,
        from viewController: UIViewController,
        context: PaywallContext? = nil,
        delegate: AppDNAPaywallDelegate? = nil
    ) -> Bool {
        // SPEC-404 — refuse to present any paywall while the SDK is in
        // backend-locked mode. The lock fires only when the tenant is
        // per-key-suspended (day 20+) or org cancelled, so a paywall
        // purchase would be wasted UX (the receipt-validate route would 401
        // and no entitlement would ever land on our side).
        if runtimeLock != nil {
            Log.warning("AppDNA.presentPaywall(id:\(id)) skipped — SDK in runtime-locked mode")
            return false
        }
        guard let manager = shared.paywallManager else {
            Log.warning("Cannot present paywall — SDK not configured")
            return false
        }
        // Resolved here, synchronously, because the answer has to be in the RETURN VALUE — by the time
        // the main-queue block runs, the caller has already been told "presented". `present` is still
        // dispatched either way: its not-found branch is what notifies `onPaywallError`, and a native
        // host that relies on that callback must keep getting it.
        let known = manager.hasPaywall(id: id)
        DispatchQueue.main.async {
            manager.present(
                id: id,
                from: viewController,
                context: context,
                // 🔴 Fall back to the delegate the host registered with `AppDNA.paywall.setDelegate`.
                //
                // This parameter defaults to nil, and a caller that does not pass one — every wrapper,
                // because a wrapper has no Swift delegate object to hand over — got a paywall with NO
                // delegate at all. On a device: the paywall rendered, and `onPaywallPresented`,
                // `onPaywallDismissed`, `onPaywallAction` and every purchase callback never fired.
                //
                // Worse, `PaywallManager.present` passes `onPromoCodeSubmit: delegate == nil ? nil : …`,
                // so a nil delegate ALSO dropped the promo-code path into its no-delegate fallback —
                // the revenue defect this SDK has already been bitten by once.
                //
                // A per-call delegate still wins when one is passed; this only supplies the registered
                // one when the caller has none.
                delegate: delegate ?? AppDNA.paywall.delegate
            )
        }
        return known
    }

    /// Present a paywall by placement — auto-selects based on audience rules.
    /// Multiple paywalls can share the same placement; the best audience match wins.
    ///
    /// - Returns: `false` when no paywall matched the placement, the SDK is locked, or it was never
    ///   configured. See `presentPaywall(id:…)`.
    @discardableResult
    public static func presentPaywall(
        placement: String,
        from viewController: UIViewController,
        context: PaywallContext? = nil,
        delegate: AppDNAPaywallDelegate? = nil
    ) -> Bool {
        // SPEC-404 — same lock check as the id-based variant above.
        if runtimeLock != nil {
            Log.warning("AppDNA.presentPaywall(placement:\(placement)) skipped — SDK in runtime-locked mode")
            return false
        }
        guard let manager = shared.paywallManager else {
            Log.warning("Cannot present paywall by placement — SDK not configured")
            return false
        }
        let known = manager.hasPaywall(placement: placement)
        DispatchQueue.main.async {
            manager.presentByPlacement(
                placement: placement,
                from: viewController,
                // 🔴 `customData` used to be DROPPED here: the context was rebuilt inline from three of
                // its four fields, and the fourth is the only one `PaywallManager` merges into the
                // `paywall_view` event's properties. Named and extracted so a test can hold it to
                // carrying all four — see `PlacementPaywallContext`.
                context: PlacementPaywallContext.make(placement: placement, from: context),
                // Same fallback as `presentPaywall` — see the note there. A wrapper has no Swift
                // delegate to pass, so without this the placement path is delegate-less too.
                delegate: delegate ?? AppDNA.paywall.delegate
            )
        }
        return known
    }

    // MARK: - Public API: Onboarding (v0.2)

    /// Present an onboarding flow by ID. Returns false if config is unavailable.
    @discardableResult
    public static func presentOnboarding(
        flowId: String? = nil,
        from viewController: UIViewController? = nil,
        delegate: AppDNAOnboardingDelegate? = nil
    ) -> Bool {
        guard let vc = viewController ?? topViewController() else {
            Log.warning("No view controller available for onboarding presentation")
            return false
        }

        // 🔴 Same fallback as `presentPaywall`, and it matters MORE here.
        //
        // `delegate` defaults to nil and a wrapper has no Swift delegate object to pass, so Flutter and
        // React Native ran onboarding with NO delegate: `onOnboardingStarted`, `onOnboardingStepChanged`,
        // `onOnboardingCompleted` and `onOnboardingDismissed` never fired for them.
        //
        // And the renderer branches on `delegate != nil` for the AUTH-ACTION gate — so "Continue with
        // email" stayed on the step for every wrapper host even when that host HAD registered an
        // onboarding delegate in JS. The delegate was there; native just never saw it.
        let resolved = delegate ?? AppDNA.onboarding.delegate

        var result = false
        // Must present on main thread
        if Thread.isMainThread {
            result = shared.onboardingFlowManager?.present(flowId: flowId, from: vc, delegate: resolved) ?? false
        } else {
            DispatchQueue.main.sync {
                result = shared.onboardingFlowManager?.present(flowId: flowId, from: vc, delegate: resolved) ?? false
            }
        }
        return result
    }

    // MARK: - Public API: Server-Driven Screens (SPEC-089c)

    /// Show a server-driven screen by ID. The screen config is fetched from cache or Firestore.
    public static func showScreen(_ screenId: String, completion: ((ScreenResult) -> Void)? = nil) {
        ScreenManager.shared.showScreen(screenId, completion: completion)
    }

    /// Show a server-driven multi-screen flow by ID.
    public static func showFlow(_ flowId: String, completion: ((FlowResult) -> Void)? = nil) {
        ScreenManager.shared.showFlow(flowId, completion: completion)
    }

    /// Dismiss the currently presented server-driven screen or flow.
    public static func dismissScreen() {
        ScreenManager.shared.dismissScreen()
    }

    /// Enable navigation interception. SDK will inject server-driven screens between
    /// app navigations based on console-configured interception rules.
    public static func enableNavigationInterception(forScreens: [String]? = nil) {
        ScreenManager.shared.enableNavigationInterception(forScreens: forScreens)
        NavigationInterceptor.shared.enable()
    }

    /// Disable navigation interception.
    public static func disableNavigationInterception() {
        ScreenManager.shared.disableNavigationInterception()
        NavigationInterceptor.shared.disable()
    }

    /// Preview a screen from raw JSON, bypassing remote config. Console preview / QA.
    ///
    /// 🔴 This was inside `#if DEBUG`, and both wrappers call it unconditionally. A wrapper compiles
    /// in whatever configuration the HOST app is built in — so in a Release archive the symbol did
    /// not exist and the pod failed to compile: `type 'AppDNA' has no member 'previewScreen'`.
    /// Nothing caught it because nothing had ever built a wrapper in Release: both build bridges and
    /// both examples build Debug. The Flutter plugin already on pub.dev carries the same call, so it
    /// cannot be archived by a customer either.
    ///
    /// Android never had the guard, so this also broke parity in the one dimension nobody inspects:
    /// the build configuration. Returns whether the JSON parsed and a screen was presented, matching
    /// Android's Bool.
    @discardableResult
    public static func previewScreen(json: String, completion: ((ScreenResult) -> Void)? = nil) -> Bool {
        ScreenManager.shared.previewScreen(json: json, completion: completion)
    }

    /// SPEC-419 D6 — the applied (fetched + parsed) onboarding config version, for the
    /// structural parity harness's readiness poll. The host app surfaces this into a hidden
    /// `accessibilityIdentifier("adn.appliedConfigVersion")` label that the harness polls
    /// until it equals the just-published version.
    ///
    /// 🔴 NOT `#if DEBUG` — the Flutter plugin (`AppdnaPlugin.swift`) invokes this
    /// unconditionally via its `debugAppliedConfigVersion` method channel. A CocoaPods pod
    /// compiles in the HOST app's configuration, so guarding it made every Flutter customer's
    /// Release archive fail to compile (`type 'AppDNA' has no member 'debugAppliedConfigVersion'`)
    /// — the identical failure `previewScreen` above already hit. CI can't catch it because
    /// nothing builds a wrapper in Release. Keep it unguarded. (Issue #527.)
    public static func debugAppliedConfigVersion(flowId: String? = nil) -> Int? {
        shared.remoteConfigManager?.debugAppliedOnboardingVersion(flowId: flowId)
    }

    /// Check if analytics consent is granted. Used by zero-code mechanisms.
    public static func isConsentGranted() -> Bool {
        shared.eventTracker?.isConsentGranted ?? true
    }

    /// Get current user traits for audience rule evaluation.
    public static func getUserTraits() -> [String: Any] {
        shared.identityManager?.currentIdentity.traits ?? [:]
    }

    /// Shorthand to show a paywall by ID (used by screen action routing).
    public static func showPaywall(_ id: String) {
        guard let vc = topViewController() else { return }
        presentPaywall(id: id, from: vc)
    }

    /// Shorthand to show a survey by ID (used by screen action routing).
    public static func showSurvey(_ id: String) {
        shared.surveyManager?.present(surveyId: id)
    }

    // MARK: - Public API: Push Token (v0.2) + Push Tracking (v0.4 / SPEC-030)

    /// Set the APNS push token. Call from `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// This registers the token with the backend for direct push delivery.
    public static func setPushToken(_ token: Data) {
        shared.queue.async {
            shared.pushTokenManager?.setPushToken(token)
        }
    }

    /// Report push permission status.
    public static func setPushPermission(granted: Bool) {
        shared.queue.async {
            shared.pushTokenManager?.setPushPermission(granted: granted)
        }
    }

    /// Track that a push notification was delivered (call from UNNotificationServiceExtension or foreground handler).
    public static func trackPushDelivered(pushId: String) {
        shared.queue.async {
            shared.pushTokenManager?.trackDelivered(pushId: pushId)
        }
    }

    /// Track that a push notification was tapped (call from notification response handler).
    public static func trackPushTapped(pushId: String, action: String? = nil) {
        shared.queue.async {
            shared.pushTokenManager?.trackTapped(pushId: pushId, action: action)
        }
    }

    // MARK: - Public API: Push Registration (v0.4 / SPEC-030)

    /// Request push notification permission and register for remote notifications.
    /// Returns `true` if the user granted permission, `false` otherwise.
    @discardableResult
    public static func registerForPush() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            shared.pushTokenManager?.setPushPermission(granted: granted)
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            return granted
        } catch {
            Log.error("Failed to request push permission: \(error)")
            return false
        }
    }

    // MARK: - Public API: Web Entitlements (v0.3)

    /// Web subscription entitlement (from Stripe web checkout).
    public static var webEntitlement: WebEntitlement? {
        shared.webEntitlementManager?.currentEntitlement
    }

    /// Register a callback for when the web entitlement changes.
    /// Only one NotificationCenter observer is registered; all handlers are dispatched from it.
    /// - Returns: a token for `removeWebEntitlementChangedHandler`. Discardable, so existing native
    ///   call sites keep compiling unchanged; a WRAPPER must keep it, because a wrapper re-registers
    ///   on every `configure()` and this list only ever grew.
    @discardableResult
    public static func onWebEntitlementChanged(_ handler: @escaping (WebEntitlement?) -> Void) -> UUID {
        let token = UUID()
        webEntitlementChangeHandlers[token] = handler

        // Register the observer only once (first handler registration)
        guard webEntitlementObserverToken == nil else { return token }
        webEntitlementObserverToken = NotificationCenter.default.addObserver(
            forName: .webEntitlementChanged,
            object: nil,
            queue: .main
        ) { notification in
            let entitlement = notification.object as? WebEntitlement
            for h in webEntitlementChangeHandlers.values {
                h(entitlement)
            }
        }
        return token
    }

    /// Remove a handler registered by `onWebEntitlementChanged`. Removing the last one also tears
    /// down the NotificationCenter observer, so nothing is retained after a wrapper invalidates.
    /// Drop every web-entitlement handler and the backing observer. Called synchronously by `shutdown()`.
    static func removeAllWebEntitlementChangedHandlers() {
        if let observer = webEntitlementObserverToken {
            NotificationCenter.default.removeObserver(observer)
            webEntitlementObserverToken = nil
        }
        webEntitlementChangeHandlers.removeAll()
    }

    public static func removeWebEntitlementChangedHandler(_ token: UUID) {
        webEntitlementChangeHandlers.removeValue(forKey: token)
        guard webEntitlementChangeHandlers.isEmpty, let observer = webEntitlementObserverToken else { return }
        NotificationCenter.default.removeObserver(observer)
        webEntitlementObserverToken = nil
    }

    // MARK: - Public API: Deferred Deep Links (v0.3)

    /// Check for a deferred deep link on first launch.
    /// Call after `AppDNA.configure()` and `AppDNA.onReady`.
    public static func checkDeferredDeepLink(completion: @escaping (DeferredDeepLink?) -> Void) {
        shared.queue.async {
            guard let manager = shared.deferredDeepLinkManager else {
                completion(nil)
                return
            }
            manager.checkDeferredDeepLink(completion: completion)
        }
    }

    // MARK: - Public API: Log Level (v1.0 / SPEC-041)

    /// Dynamically change the SDK log level at runtime.
    /// Matches unified API: `AppDNA.setLogLevel(.debug)`
    public static func setLogLevel(_ level: LogLevel) {
        Log.level = level
        Log.info("Log level changed to \(level)")
    }

    // MARK: - Public API: Diagnostics

    /// Test seam for the `base_url:` line (the configured environment is private state).
    internal static var diagnoseEnvironmentForTesting: Environment?

    /// Print a comprehensive SDK health report to the console.
    /// Call after `configure()` has had time to complete (e.g. after 3-5 seconds or in viewDidAppear).
    /// Checks: API key format, bootstrap status, Firebase initialization, Firestore connectivity, event queue health.
    @discardableResult
    public static func diagnose() -> String {
        return shared.queue.sync {
            let isOffline = NetworkMonitor.shared.currentConnectionType == .none
            let hasBundledConfig = currentBundleVersion > 0
            let hasBootstrap = shared.bootstrapData != nil

            var lines: [String] = []
            lines.append("╔══════════════════════════════════════════")
            // Per-platform version: wrapper hosts (flutter/react_native) report
            // their OWN version; native core version shown on a Platform line.
            let fw = shared.options.framework
            let reportVersion = fw != "native" ? (shared.options.frameworkVersion ?? sdkVersion) : sdkVersion
            lines.append("║  AppDNA SDK Diagnostic Report  v\(reportVersion)")
            if fw != "native" {
                lines.append("║  Platform: \(fw) wrapper (native core v\(sdkVersion))")
            }
            lines.append("╠══════════════════════════════════════════")

            // 1. API Key
            if let key = shared.apiKey {
                if key.hasPrefix("adn_live_") {
                    lines.append("║ ✅ API Key: production key (adn_live_...\(String(key.suffix(4))))")
                } else if key.hasPrefix("adn_test_") {
                    lines.append("║ ✅ API Key: sandbox key (adn_test_...\(String(key.suffix(4))))")
                } else {
                    lines.append("║ ❌ API Key: invalid format — must start with adn_live_ or adn_test_")
                }
            } else {
                lines.append("║ ❌ API Key: not set — configure() not called?")
            }

            // 2. Environment
            lines.append("║ ✅ Environment: \(shared.environment.rawValue)")
            // The resolved API base. The E2E hosts match `base_url: ` by substring.
            lines.append("║ base_url: \(APIBaseURL.resolve(environment: diagnoseEnvironmentForTesting ?? shared.environment))")

            // 3. Network
            switch NetworkMonitor.shared.currentConnectionType {
            case .wifi:
                lines.append("║ ✅ Network: WiFi")
            case .cellular:
                lines.append("║ ✅ Network: Cellular")
            case .none:
                lines.append("║ ⚠️ Network: offline")
            }

            // 4. Bootstrap
            if hasBootstrap {
                let data = shared.bootstrapData!
                lines.append("║ ✅ Bootstrap: orgId=\(data.orgId), appId=\(data.appId)")
                lines.append("║    Firestore path: \(data.firestorePath)")
            } else if isOffline {
                lines.append("║ ⚠️ Bootstrap: offline — using cached/bundled config")
            } else {
                lines.append("║ ❌ Bootstrap: failed — check API key and network")
            }

            // 5. Firebase
            if FirebaseApp.app(name: "appdna") != nil {
                lines.append("║ ✅ Firebase: secondary app 'appdna' configured")
            } else if FirebaseApp.app() != nil {
                lines.append("║ ⚠️ Firebase: using default app (NOT AppDNA secondary) — add GoogleService-Info-AppDNA.plist")
            } else {
                lines.append("║ ❌ Firebase: no Firebase app configured")
            }

            // 6. Identity
            if let identity = shared.identityManager {
                let id = identity.currentIdentity
                lines.append("║ ✅ Identity: anonId=\(String(id.anonId.prefix(8)))..., userId=\(id.userId ?? "none")")
            } else {
                lines.append("║ ❌ Identity: not initialized")
            }

            // 7. Event Queue
            if shared.eventQueue != nil {
                lines.append("║ ✅ Event Queue: initialized\(isOffline ? " (events queued for later)" : "")")
            } else {
                lines.append("║ ❌ Event Queue: not initialized")
            }

            // 8. Remote Config
            if shared.remoteConfigManager != nil {
                if hasBootstrap {
                    lines.append("║ ✅ Remote Config: live (Firestore)")
                } else if hasBundledConfig {
                    lines.append("║ ✅ Remote Config: bundled (v\(currentBundleVersion))")
                } else {
                    lines.append("║ ⚠️ Remote Config: cached only")
                }
            } else {
                lines.append("║ ❌ Remote Config: not initialized")
            }

            // 9. Config Source
            if hasBootstrap {
                lines.append("║ ✅ Config Source: remote (Firestore)")
            } else if hasBundledConfig {
                lines.append("║ ✅ Config Source: bundled config (v\(currentBundleVersion))")
            } else {
                lines.append("║ ⚠️ Config Source: disk cache")
            }

            // 10. Modules
            var modules: [String] = []
            if shared.paywallManager != nil { modules.append("paywalls") }
            if shared.onboardingFlowManager != nil { modules.append("onboarding") }
            if shared.messageManager != nil { modules.append("messages") }
            if shared.surveyManager != nil { modules.append("surveys") }
            if shared.billingBridge != nil { modules.append("billing") }
            if shared.pushTokenManager != nil { modules.append("push") }
            if shared.experimentManager != nil { modules.append("experiments") }
            lines.append("║ ✅ Modules: \(modules.isEmpty ? "none" : modules.joined(separator: ", "))")

            // The notification proxy's state (read through the installed slot; the
            // disabled / not-installed states read no notification centre).
            for line in NotificationProxyBootstrap.diagnoseLines() {
                lines.append("║ ℹ️ \(line)")
            }

            // SPEC-070-B PN row 14 + 16: the two settings whose effect is invisible until something
            // goes wrong — a silently opted-out user, and a veto that timed out into its default.
            let consent = ConsentStore.decision
            let consentLabel = consent.map { $0 ? "granted" : "DENIED" } ?? "no decision yet"
            lines.append("║ ℹ️ Analytics consent: \(consentLabel) (requireConsent=\(shared.options.requireConsent))")
            lines.append("║ ℹ️ Veto timeout: \(DiagnoseFormat.seconds(shared.options.vetoTimeout))s · timed out \(VetoTimeoutCounter.count) time(s)")
            if let err = lastInitError {
                lines.append("║ ⚠️ Init degraded: \(err.localizedDescription)")
            }

            // Summary
            lines.append("╠══════════════════════════════════════════")
            let allGood = shared.apiKey != nil && hasBootstrap && FirebaseApp.app(name: "appdna") != nil
            if allGood {
                lines.append("║ ✅ SDK is fully operational")
            } else if isOffline && (hasBundledConfig || shared.remoteConfigManager != nil) {
                lines.append("║ ✅ SDK is operational (offline mode)")
            } else if isOffline {
                lines.append("║ ⚠️ SDK is offline — add bundled config for offline support")
            } else {
                lines.append("║ ⚠️ SDK has issues — review items marked ❌ above")
            }
            lines.append("╚══════════════════════════════════════════")

            for line in lines {
                print("[AppDNA] \(line)")
            }
            // Parity with Android `diagnose(): String` — return the report so
            // cross-platform hosts (incl. the Flutter wrapper) get the text too.
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Public API: Session Data (SPEC-088)

    /// Store a key-value pair in the cross-module session data store.
    /// Available to all modules via `{{session.key}}` template variables.
    public static func setSessionData(key: String, value: Any) {
        SessionDataStore.shared.setSessionData(key: key, value: value)
    }

    /// Retrieve a session data value by key.
    public static func getSessionData(key: String) -> Any? {
        SessionDataStore.shared.getSessionData(key: key)
    }

    /// Clear all app-defined session data.
    public static func clearSessionData() {
        SessionDataStore.shared.clearSessionData()
    }

    /// Get structured location data from an onboarding location field (SPEC-089).
    ///
    /// A selected suggestion returns the full object; text the user typed without selecting returns
    /// `{formatted_address, raw_query}` = that text with null coordinates. Returns nil if the field was
    /// not answered (or holds an empty string, a number or null). Never serialises the stored value,
    /// so no stored shape can crash the host.
    public static func getLocationData(fieldId: String) -> LocationData? {
        let responses = SessionDataStore.shared.onboardingResponses
        for key in responses.keys.sorted() {
            guard let stepData = responses[key] as? [String: Any], let stored = stepData[fieldId] else { continue }
            if let location = LocationData.fromStoredAnswer(stored) { return location }
        }
        return nil
    }

    // MARK: - Public API: Privacy

    /// Set analytics consent. When false, events are silently dropped.
    public static func setConsent(analytics: Bool) {
        // SPEC-070-B PN row 14 (AC-36): persist FIRST and synchronously. A crash between the async
        // hop and the write would otherwise lose a revocation, and the next launch would re-enable
        // analytics for a user who opted out.
        ConsentStore.decision = analytics
        shared.queue.async {
            shared.eventTracker?.setConsent(analytics: analytics)
            Log.info("Consent updated: analytics=\(analytics)")
        }
    }

    // MARK: - Public API: Ready callback

    /// Register a callback that fires once the bootstrap has succeeded or failed and the modules are ready
    /// (at once if that has already happened). The cached and bundled config are applied first; the remote
    /// config fetch is started but not awaited — observe remote config changes for fresh values.
    public static func onReady(_ callback: @escaping () -> Void) {
        shared.queue.async {
            // `isReady`, NOT `isConfigured` — see the flag's definition. The guard flag is true
            // before bootstrap has even been dispatched.
            if shared.isReady {
                DispatchQueue.main.async { callback() }
            } else {
                shared.readyCallbacks.append(callback)
            }
        }
    }

    // MARK: - Firebase Initialization (must run on main thread)

    /// Lock protecting `firebaseInitialized` and `isConfigured` flags against concurrent access.
    private let initLock = NSLock()

    /// Track whether Firebase has been initialized to avoid double-init.
    private var firebaseInitialized = false

    /// Initialize Firebase on the main thread.
    /// Priority:
    /// 1. GoogleService-Info-AppDNA.plist -> create named "appdna" instance
    /// 2. Default FirebaseApp already exists -> use it
    /// 3. Standard GoogleService-Info.plist (only if no existing Firebase app) -> auto-configure
    /// 4. None available -> log error, SDK works in degraded mode
    private func initializeFirebase() {
        initLock.lock()
        guard !firebaseInitialized else {
            initLock.unlock()
            return
        }
        firebaseInitialized = true
        initLock.unlock()

        // Option 1 (RECOMMENDED): Dedicated AppDNA plist → separate named Firebase app
        // This is the correct path when the host app has its own Firebase project.
        if let appdnaPlistPath = Bundle.main.path(forResource: "GoogleService-Info-AppDNA", ofType: "plist"),
           let appdnaOptions = FirebaseOptions(contentsOfFile: appdnaPlistPath) {
            if FirebaseApp.app(name: "appdna") == nil {
                FirebaseApp.configure(name: "appdna", options: appdnaOptions)
            }
            if let secondaryApp = FirebaseApp.app(name: "appdna") {
                AppDNA.firestoreDB = Firestore.firestore(app: secondaryApp)
                Log.info("✅ Firebase: Using secondary app 'appdna' (GoogleService-Info-AppDNA.plist)")
            } else {
                Log.error("❌ Firebase: GoogleService-Info-AppDNA.plist found but failed to create secondary app. Check the plist content is valid.")
                AppDNA.reportInitDegraded(AppDNAInitError.firebaseConfigMissing(
                    "GoogleService-Info-AppDNA.plist is present but its contents are not a valid Firebase configuration"))
            }
            return
        }

        // Option 2: No AppDNA plist, but standard plist exists and NO existing Firebase app
        // This only works if the standard plist points to the AppDNA Firebase project.
        if FirebaseApp.app() == nil {
            if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
                FirebaseApp.configure()
                AppDNA.firestoreDB = Firestore.firestore()
                Log.info("✅ Firebase: Auto-configured from GoogleService-Info.plist (make sure this is the AppDNA Firebase config)")
                return
            }
        }

        // Option 3: Host app already has Firebase, but no AppDNA plist
        // ⚠️ We CANNOT use the host's Firebase — it points to a different project
        // and Firestore reads will fail with "Missing or insufficient permissions".
        if FirebaseApp.app() != nil {
            Log.error("""
            ❌ Firebase: Your app already has Firebase configured (its own project), \
            but GoogleService-Info-AppDNA.plist was NOT found. \
            AppDNA needs its own Firebase config to access Firestore. \
            \n→ Download GoogleService-Info-AppDNA.plist from Console → Settings → SDK \
            \n→ Add it to your Xcode project (drag into navigator, check 'Copy items if needed', select your app target) \
            \n→ See: https://docs.appdna.ai/sdks/ios/installation#firebase-configuration \
            \nRemote config (paywalls, experiments, flags, onboarding) will NOT work without this file.
            """)
            AppDNA.reportInitDegraded(AppDNAInitError.firebaseConfigMissing(
                "the host app has its own Firebase project but GoogleService-Info-AppDNA.plist is absent"))
            return
        }

        // Option 4: No Firebase config at all
        Log.error("""
        ❌ Firebase: No Firebase configuration found. AppDNA requires Firebase Firestore for remote config. \
        \n→ Download GoogleService-Info-AppDNA.plist from Console → Settings → SDK \
        \n→ Add it to your Xcode project \
        \n→ See: https://docs.appdna.ai/sdks/ios/installation#firebase-configuration
        """)
        AppDNA.reportInitDegraded(AppDNAInitError.firebaseConfigMissing(
            "no Firebase configuration found in the app bundle"))
    }

    // MARK: - Internal bootstrap

    private func performConfigure(apiKey: String, environment: Environment, options: AppDNAOptions, epoch: Int) {
        // Bail if a newer configure()/shutdown() superseded this scheduled build. `isConfigured` is
        // false when a shutdown() landed after this configure() was accepted; a bumped epoch means a
        // later configure() is the one that should build. Either way, rebuilding here would duplicate
        // the pipeline, subscription observer and timers (there is no teardown between two back-to-back
        // performConfigures). Read both under the same lock configure()/shutdown() write them under.
        initLock.lock()
        let superseded = !isConfigured || configureEpoch != epoch
        initLock.unlock()
        if superseded {
            Log.warning("AppDNA.configure() superseded by a later configure()/shutdown() before its build ran — skipping duplicate initialization")
            return
        }
        Self.performConfigureCountLock.lock()
        Self._performConfigureCount += 1
        Self.performConfigureCountLock.unlock()

        self.apiKey = apiKey
        self.environment = environment
        self.options = options
        Log.level = options.logLevel

        Log.info("Configuring AppDNA SDK v\(AppDNA.sdkVersion) (\(environment.rawValue))")

        // Validate API key format
        if !apiKey.hasPrefix("adn_live_") && !apiKey.hasPrefix("adn_test_") {
            Log.error("❌ API key format invalid. Keys must start with 'adn_live_' (production) or 'adn_test_' (sandbox). Got: \(String(apiKey.prefix(10)))...")
        }
        if apiKey.count < 20 {
            Log.error("❌ API key too short (\(apiKey.count) chars). Check you're passing the full key from Console → Settings → SDK → API Keys.")
        }

        // Firebase already initialized on main thread in initializeFirebase()

        // The install marker first: whether the SDK's directory exists before this configure creates it is how the
        // first launch of an install is told from an update (`AppInstallDate`).
        AppInstallDate.recordAtLaunch()

        // 1. Initialize core managers
        let keychainStore = KeychainStore()
        let identityMgr = IdentityManager(keychainStore: keychainStore)
        self.identityManager = identityMgr

        let client = APIClient(apiKey: apiKey, environment: environment)
        self.apiClient = client

        // Runtime settings before any bootstrap: the host's values, else the built-in defaults.
        let initialRuntime = RuntimeSettings.resolveAll(options: options, bootstrap: nil)
        self.runtimeSettings = initialRuntime
        let configCache = ConfigCache(ttl: initialRuntime.configTTL)
        self.runtimeConfigCache = configCache
        let eventStore = EventStore()

        // 2. Initialize event system
        let tracker = EventTracker(identityManager: identityMgr)
        // NB: eventTracker is published LATER (under preInitLock, after setEventQueue) — SPEC-428 F2.

        let eq = EventQueue(
            apiClient: client,
            eventStore: eventStore,
            eventTracker: tracker,
            batchSizeCap: initialRuntime.batchSizeCap,
            flushInterval: initialRuntime.flushInterval
        )
        self.eventQueue = eq
        tracker.setEventQueue(eq)
        // SPEC-070-B PN row 1: every envelope carries the last-announced screen. Reads the static
        // through the lock, so a host announcing from a background thread is safe.
        tracker.setScreenProvider { AppDNA.lastScreenName }
        // Attach the current push_id (30-min window) to every event envelope — mirrors Android's
        // setPushIdProvider, so push→conversion attribution works on iOS too.
        tracker.setPushIdProvider { PushSessionContext.currentPushId() }

        // SPEC-070-B PN row 14 (AC-36): resolve consent from the PERSISTED decision before anything
        // can be tracked — including the pre-init buffer drain and `sdk_initialized`. A denied user
        // used to be silently re-opted-in on every cold start.
        tracker.setInitialConsent(analytics: ConsentStore.effectiveConsent(requireConsent: options.requireConsent))

        // SPEC-428 CL-10/D7 + F2: publish eventTracker UNDER preInitLock (mutually exclusive with the
        // facade track()'s buffer-vs-mint decision, so no event can be buffered after the drain and
        // stranded) AND after setEventQueue (so a post-publish mint never hits a nil queue). Then drain the
        // events buffered pre-publish — in order; their client_seq was stamped at track() time, sitting
        // strictly above the prior run's ceiling. Nothing buffers after the publish (track() re-checks).
        Self.preInitLock.lock()
        self.eventTracker = tracker
        Self.preInitLock.unlock()
        AppDNA.drainPreInitBuffer()

        // SPEC-067: Initialize background uploader.
        // BGTaskScheduler.register must happen during app launch (before
        // application(_:didFinishLaunchingWithOptions:) returns) — we
        // previously called it here in configure(), which crashed on devices
        // where configure() ran after launch completed. Registration is now
        // done via AppDNA.registerBackgroundTasks() which host apps call
        // early in their AppDelegate. If it hasn't happened, background
        // uploads are disabled for this session but the SDK still works.
        let bgUploader = BackgroundUploader(apiClient: client, eventStore: eventStore)
        BackgroundUploader.shared = bgUploader
        if !BackgroundUploader.isRegistered {
            Log.warning("""
                BackgroundUploader: background task not registered. Add this to \
                your AppDelegate's application(_:didFinishLaunchingWithOptions:) \
                BEFORE calling AppDNA.configure():
                    AppDNA.registerBackgroundTasks()
                Background event uploads are disabled for this session.
                """)
        }

        // 3. Initialize session manager (tracks lifecycle events)
        let sessionMgr = SessionManager(eventTracker: tracker)
        self.sessionManager = sessionMgr
        identityMgr.sessionManager = sessionMgr

        // 4. Initialize billing bridge — INSIDE the isolation seam, like every other subsystem.
        //
        // 🔴 This used to be a bare `switch`, outside `initSubsystem` entirely. Billing was therefore
        // the one subsystem that could neither be isolated nor observed: a throwing provider init (a bad
        // Adapty key, an unconfigured RevenueCat) would escape instead of degrading billing alone, and
        // `subsystemInitFailures` — the seam the whole isolation guarantee rests on — could not reach it.
        //
        // Nothing noticed, because `subsystemsUp()` had no `billing` key to report. Adding one surfaced
        // it immediately: `testEverySubsystemFailingAtOnceStillLeavesATrackingSDK` injects a failure into
        // EVERY subsystem and asserts none comes up — and billing came up anyway, because it was never
        // in the seam to fail. The oracle was blind in exactly the place the code was unguarded.
        // Ownership comes from the REQUESTED provider, decided once by
        // `BillingOwnership.policy`. A provider whose SDK is not linked into this build (RevenueCat /
        // Adapty on every published channel) gets `ExternalProviderBridge`, which refuses to buy or
        // restore and never finishes anything — it used to get a silent `StoreKit2Bridge` fallback that
        // bought through StoreKit and finished transactions the provider owned.
        let requestedProvider = options.billingProvider
        let providerLinked = BillingOwnership.isLinked(requestedProvider)
        var billingPolicy = BillingOwnership.policy(for: requestedProvider, bridgeLinked: providerLinked)
        self.billingBridge = AppDNA.initSubsystem("billing") { () -> BillingBridgeProtocol? in
            BillingOwnership.makeBridge(for: requestedProvider, tracker: tracker)
        } ?? nil
        // A provider init that failed inside the isolation seam leaves billing unavailable: the `none`
        // policy (no purchase, no restore, providerNotAvailable, no observer).
        if self.billingBridge == nil { billingPolicy = BillingOwnership.unavailable }

        // Billing is ready from the first call: the facade gets the bridge, the
        // policy and the tracker HERE, right after the bridge is built and before the observer starts
        // (so both see the same bridge) — not after the bootstrap. This point is already after
        // `tracker.setEventQueue` and the preInitLock publish above, so the tracker never meets a nil
        // queue.
        AppDNA.billing.wire(bridge: self.billingBridge, policy: billingPolicy, tracker: tracker)

        // 4b. Subscription lifecycle — the observer runs under every provider that has one; its MODE
        // comes from the ownership policy: `.storeKitOwned` ONLY for `storeKit2`.
        // Under `.providerOwned` it never drains `Transaction.updates` and never calls `finish()`.
        // Device lifecycle events follow `emitsLifecycleEvents` (none under RevenueCat — its
        // webhook is the single source; kept under Adapty); the snapshot is persisted either way.
        if let observerMode = billingPolicy.observerMode.subscriptionObserverMode {
            let observer = SubscriptionStatusObserver(
                eventTracker: tracker,
                mode: observerMode,
                emitsLifecycleEvents: billingPolicy.emitsLifecycleEvents,
                // After every pass (launch, foreground, `Transaction.updates`, provider callback): the
                // diff-guarded entitlement refresh — so a renewal, an expiry or a refund reaches
                // `onEntitlementsChanged` — and a retry of unverified purchases.
                afterPass: {
                    await AppDNA.billing.refreshEntitlementCache()
                    await PurchaseVerificationQueue.shared.retryPending()
                }
            )
            self.subscriptionObserver = observer
            observer.start()
        }

        // The delivery queue is activated once the identity is loaded; trigger (iv): drain at
        // the end of billing initialisation when a delivering delegate was set before `configure`.
        Task {
            await PurchaseDeliveryQueue.shared.activate(session: epoch)
            await PurchaseDeliveryQueue.shared.drain()
        }

        // 5. Initialize push token manager (v0.2 + v0.4 SPEC-030: backend registration)
        self.pushTokenManager = PushTokenManager(keychainStore: keychainStore, eventTracker: tracker, apiClient: client)
        AppDNA.pushModule.manager = self.pushTokenManager
        // The push CONFIGURED POINT: from here the SDK can track, so buffered
        // launch taps / deliveries (from the notification proxy and from host forwarding) drain now, on
        // the main queue, in arrival order. Then the configure fallback decides whether the proxy has
        // to be installed here because no launch-time observer was ever registered (table).
        // Epoch-scoped: a `shutdown()` that already ended this configure (it can land between the
        // superseded check above and this line) keeps the gate closed.
        PushGate.shared.markConfigured(epoch: epoch)
        DispatchQueue.main.async {
            NotificationProxyBootstrap.configureFallback(plist: Bundle.main.infoDictionary ?? [:])
            // Button categories of AppDNA pushes delivered while the app was not
            // running (no Notification Service Extension to register them).
            PushActionCategories.registerFromDeliveredNotifications()
        }

        // 6. Bootstrap async (fetch orgId/appId, then Firestore configs)
        Task { [weak self] in
            await self?.performBootstrap(client: client, configCache: configCache, identityMgr: identityMgr, tracker: tracker, epoch: epoch)
        }
    }

    /// The bootstrap request, with its 15-second limit (allows 1 retry cycle: initial + 1s + retry = ~5-10s).
    private func fetchBootstrap(_ client: APIClient) async throws -> BootstrapData {
        try await withTimeout(seconds: 15) {
            try await client.request(.bootstrap)
        }
    }

    /// The part of applying a successful bootstrap that does not need `queue`: map keys, the runtime lock
    /// and geo traits. The first bootstrap and a later recovery (`startBootstrapRecovery`) both run it.
    private func applyBootstrapSettings(_ data: BootstrapData, identityMgr: IdentityManager) {
        Log.info("Bootstrap successful: orgId=\(data.orgId), appId=\(data.appId)")

        // Reconcile runtime lock state from the bootstrap
        // response. Fire delegate callbacks ONLY on a state transition
        // (idle → locked or locked → idle), not on every bootstrap.
        // Repeated bootstraps in the same state are a no-op for delegate
        // notification.
        AppDNA.applyRemoteMapboxToken(data.settings.mapboxToken)
        // Same path, same ownership rules, for the Google provider.
        AppDNA.applyRemoteGoogleMapsKey(data.settings.googleMapsApiKey)
        // The engine those two keys select between, same delivery path.
        AppDNA.applyRemoteMapProvider(data.settings.mapProvider)

        let previousLock = AppDNA.runtimeLock
        let currentLock = data.runtime_lock
        AppDNA.runtimeLock = currentLock
        if previousLock == nil, let newLock = currentLock {
            Log.warning("AppDNA runtime locked by backend (reason=\(newLock.reason), locked_at=\(newLock.locked_at)) — pausing paywall/message/survey presentation")
            AppDNA.lifecycleDelegate?.onSdkRuntimeLocked(reason: newLock.reason, lockedAt: newLock.locked_at)
        } else if previousLock != nil, currentLock == nil {
            Log.info("AppDNA runtime lock cleared — restoring normal SDK behaviour")
            AppDNA.lifecycleDelegate?.onSdkRuntimeUnlocked()
        }

        // Auto-inject geo traits from bootstrap response
        if let geo = data.geo {
            var geoTraits: [String: Any] = [:]
            if let country = geo.country, !country.isEmpty { geoTraits["country"] = country }
            if let region = geo.region, !region.isEmpty { geoTraits["region"] = region }
            if let city = geo.city, !city.isEmpty { geoTraits["city"] = city }
            if let tz = geo.timezone, !tz.isEmpty { geoTraits["timezone"] = tz }
            if !geoTraits.isEmpty {
                identityMgr.mergeTraits(geoTraits)
                Log.info("Geo traits injected: \(geoTraits.keys.joined(separator: ", "))")
            }
        }
    }

    private func performBootstrap(
        client: APIClient,
        configCache: ConfigCache,
        identityMgr: IdentityManager,
        tracker: EventTracker,
        epoch: Int
    ) async {
        do {
            let data = try await fetchBootstrap(client)
            // 🔴 A BOOTSTRAP THAT OUTLIVES ITS CONFIGURE IS DROPPED. The request can take seconds; a
            // `shutdown()` (or `shutdown(); configure()`) in that window used to be ignored here, and
            // the late answer rebuilt every manager and set `isReady` on a shut-down SDK — or, after a
            // re-configure, overwrote the new configure's bootstrap with the old one's. Checked here so
            // none of the side effects below run, and again on `queue` (authoritative) before applying.
            guard isCurrentConfigure(epoch) else {
                return dropStaleBootstrap(epoch)
            }
            applyBootstrapSettings(data, identityMgr: identityMgr)

            queue.async { [weak self] in
                guard let self else { return }
                guard self.isCurrentConfigure(epoch) else { return self.dropStaleBootstrapOnQueue(epoch) }
                self.bootstrapData = data
                self.applyRuntimeSettings(data.settings)
                self.initializeManagers(
                    firestorePath: data.firestorePath,
                    configCache: configCache,
                    identityMgr: identityMgr,
                    tracker: tracker
                )
            }
        } catch {
            // A failure that outlives its configure is just as stale as a success: no degraded report,
            // no managers, no ready on a shut-down (or re-configured) SDK.
            guard isCurrentConfigure(epoch) else {
                return dropStaleBootstrap(epoch)
            }
            let desc = error.localizedDescription
            if desc.contains("401") || desc.contains("UNAUTHORIZED") || desc.contains("Invalid API key") {
                Log.error("❌ Bootstrap failed: Invalid API key. Check your key in Console → Settings → SDK → API Keys. Make sure it starts with 'adn_live_' or 'adn_test_'.")
            } else if desc.contains("Network error") || desc.contains("not connected") || desc.contains("timed out") {
                Log.error("❌ Bootstrap failed: Network error (\(desc)). Check your device has internet access and can reach api.appdna.ai")
            } else {
                Log.error("❌ Bootstrap failed: \(desc) — SDK will operate in degraded mode with cached/bundled config until it is retried")
            }
            // SPEC-070-B PN row 2 (D-k): a failed bootstrap IS the degraded state. Surface it instead of
            // leaving the host to infer it from a log line. Managers still initialize below (row 17).
            AppDNA.reportInitDegraded(AppDNAInitError.bootstrapFailed(desc))
            queue.async { [weak self] in
                guard let self else { return }
                guard self.isCurrentConfigure(epoch) else { return self.dropStaleBootstrapOnQueue(epoch) }
                self.initializeManagers(
                    firestorePath: nil,
                    configCache: configCache,
                    identityMgr: identityMgr,
                    tracker: tracker
                )
                // Ready now (on cached and bundled config); the bootstrap is retried for the rest of the
                // session and applied when it answers — unless the server refused the key (401 / 403):
                // retrying that cannot help.
                // A 429's Retry-After holds back the first retry too (not only the retries' own).
                let outcome = BootstrapRecovery.outcome(for: error)
                if outcome == .stop {
                    Log.warning("Bootstrap not retried — the server refused the API key")
                } else {
                    self.startBootstrapRecovery(client: client, identityMgr: identityMgr, tracker: tracker, epoch: epoch,
                                                after: outcome)
                }
            }
        }
    }

    // MARK: - Bootstrap recovery

    /// The retry loop of the current configure's failed bootstrap. Under `initLock`; stopped by `shutdown()`.
    private var bootstrapRecovery: BootstrapRecovery?

    /// Test seams: the backoff and the network check the next `BootstrapRecovery` uses (nil: defaults).
    internal static var bootstrapRetryBackoffForTesting: ((Int) -> TimeInterval)?
    internal static var bootstrapRetryOnlineForTesting: (() -> Bool)?
    private static let recoveredLock = NSLock()
    private static var _bootstrapsRecovered = 0
    /// Test reader: bootstrap recoveries applied since the process started.
    internal static var bootstrapsRecoveredForTesting: Int { recoveredLock.lock(); defer { recoveredLock.unlock() }; return _bootstrapsRecovered }
    /// Test reader: the current retry loop, if any.
    internal static var bootstrapRecoveryForTesting: BootstrapRecovery? {
        shared.initLock.lock(); defer { shared.initLock.unlock() }; return shared.bootstrapRecovery
    }

    /// The bootstrap of configure `epoch` failed and the SDK is ready on cached and bundled config: keep
    /// trying it (`BootstrapRecovery` — when the network comes back, on foreground, after a bounded backoff).
    /// The first answer is applied exactly as a first-time success: map keys, runtime lock and geo traits
    /// (`applyBootstrapSettings`), then on `queue` `bootstrapData`, the Firestore path and its config fetch,
    /// the deferred deep-link manager and the Firestore listeners of an identified user
    /// (`applyRecoveredBootstrap`). The SDK is already ready: `onReady` does not fire again and
    /// `sdk_initialized` is not tracked again. An attempt for a configure that has ended applies nothing.
    /// On `queue`.
    private func startBootstrapRecovery(client: APIClient, identityMgr: IdentityManager, tracker: EventTracker, epoch: Int,
                                        after initial: BootstrapRecovery.Outcome? = nil) {
        let recovery = BootstrapRecovery(
            isOnline: Self.bootstrapRetryOnlineForTesting ?? { NetworkMonitor.shared.isConnected },
            backoff: Self.bootstrapRetryBackoffForTesting ?? BootstrapRecovery.defaultBackoff
        )
        initLock.lock()
        guard isConfigured, configureEpoch == epoch else { initLock.unlock(); return }
        let previous = bootstrapRecovery
        bootstrapRecovery = recovery
        initLock.unlock()
        previous?.stop()

        recovery.start(after: initial) { [weak self] in
            guard let self, self.isCurrentConfigure(epoch) else { return .done }
            let data: BootstrapData
            do {
                data = try await self.fetchBootstrap(client)
            } catch {
                Log.debug("Bootstrap retry failed: \(error.localizedDescription)")
                // 401 / 403 end the retries; a 429's Retry-After holds the next one back.
                return BootstrapRecovery.outcome(for: error)
            }
            guard self.isCurrentConfigure(epoch) else { return .done }
            self.applyBootstrapSettings(data, identityMgr: identityMgr)
            return await withCheckedContinuation { (cont: CheckedContinuation<BootstrapRecovery.Outcome, Never>) in
                self.queue.async {
                    if self.isCurrentConfigure(epoch) {
                        self.applyRecoveredBootstrap(data, tracker: tracker, recovery: recovery)
                    }
                    cont.resume(returning: .done)
                }
            }
        }
    }

    /// On `queue`. The `queue` half of a recovered bootstrap — what `initializeManagers` does with
    /// `bootstrapData` on a first success, applied to the managers that already run.
    private func applyRecoveredBootstrap(_ data: BootstrapData, tracker: EventTracker, recovery: BootstrapRecovery) {
        bootstrapData = data
        applyRuntimeSettings(data.settings)
        if deferredDeepLinkManager == nil {
            deferredDeepLinkManager = DeferredDeepLinkManager(orgId: data.orgId, appId: data.appId, eventTracker: tracker)
        }
        if let userId = identityManager?.currentIdentity.userId {
            webEntitlementManager?.startObserving(orgId: data.orgId, appId: data.appId, userId: userId)
            pendingMessageListener?.startObserving(orgId: data.orgId, appId: data.appId, userId: userId)
        }
        remoteConfigManager?.attachFirestorePath(data.firestorePath)

        Self.initErrorLock.lock()
        if let e = Self._lastInitError as? AppDNAInitError, case .bootstrapFailed = e { Self._lastInitError = nil }
        Self.initErrorLock.unlock()
        initLock.lock()
        if bootstrapRecovery === recovery { bootstrapRecovery = nil }
        initLock.unlock()
        Self.recoveredLock.lock(); Self._bootstrapsRecovered += 1; Self.recoveredLock.unlock()
        Log.info("Bootstrap recovered — Firestore config and listeners are live")
    }

    /// On `queue`. Resolve the runtime settings against a bootstrap answer (`RuntimeSettings`: host option >
    /// bootstrap value > default; a non-positive bootstrap value is ignored) and apply them: the event queue's
    /// batch cap and flush timer, and the config TTL of the cache and of the config manager.
    private func applyRuntimeSettings(_ settings: BootstrapSettings) {
        let resolved = RuntimeSettings.resolveAll(options: options, bootstrap: settings)
        runtimeSettings = resolved
        eventQueue?.applyRuntimeSettings(batchSizeCap: resolved.batchSizeCap, flushInterval: resolved.flushInterval)
        runtimeConfigCache?.ttl = resolved.configTTL
        remoteConfigManager?.setConfigTTL(resolved.configTTL)
    }

    /// A bootstrap whose configure has been ended by `shutdown()` or superseded by a later `configure()`.
    /// Nothing of it is applied: no managers, no `isReady`, no `onReady` callbacks, no `sdk_initialized`.
    private func dropStaleBootstrap(_ epoch: Int) {
        queue.async { [weak self] in self?.dropStaleBootstrapOnQueue(epoch) }
    }

    private func dropStaleBootstrapOnQueue(_ epoch: Int) {
        Log.info("Bootstrap result for configure #\(epoch), since shut down or replaced — dropped")
        Self.recordBootstrapOutcome(applied: false)
    }

    /// Execute an async operation with a timeout. Throws CancellationError if the timeout is reached.
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            // Return whichever finishes first
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func initializeManagers(
        firestorePath: String?,
        configCache: ConfigCache,
        identityMgr: IdentityManager,
        tracker: EventTracker
    ) {
        let remoteCfg = RemoteConfigManager(
            firestorePath: firestorePath,
            configCache: configCache,
            configTTL: configCache.ttl
        )
        remoteCfg.setEventTracker(tracker)
        self.remoteConfigManager = remoteCfg

        self.featureFlagManager = FeatureFlagManager(remoteConfigManager: remoteCfg)

        let experimentMgr = ExperimentManager(
            remoteConfigManager: remoteCfg,
            identityManager: identityMgr,
            eventTracker: tracker
        )
        self.experimentManager = experimentMgr
        // Attach the active experiment exposures to EVERY event envelope (context.experiment_exposures),
        // matching Android's setExperimentExposureProvider (AppDNA.kt). Previously iOS shipped nil on
        // every event because the only method that passed exposures had zero callers.
        tracker.setExperimentExposureProvider {
            experimentMgr.getExposures().map { ExperimentExposure(exp: $0.experimentId, variant: $0.variant) }
        }

        // SPEC-036-F §1.2 — surface managers receive the ExperimentManager so
        // they can consult it for a running experiment targeting the surface+
        // entity being presented (treatment → render variant payload; control/
        // none → render the active entity through the normal path).
        self.paywallManager = Self.initSubsystem("paywall") {
            PaywallManager(
                remoteConfigManager: remoteCfg,
                billingBridge: self.billingBridge,
                billingPolicy: AppDNA.billing.ownershipPolicy,
                billingConfigured: { AppDNA.billing.configured },
                eventTracker: tracker,
                experimentManager: experimentMgr
            )
        }

        // v0.2 managers
        self.onboardingFlowManager = Self.initSubsystem("onboarding") {
            OnboardingFlowManager(
                remoteConfigManager: remoteCfg,
                eventTracker: tracker,
                experimentManager: experimentMgr
            )
        }

        self.messageManager = Self.initSubsystem("in_app_messages") {
            MessageManager(
                remoteConfigManager: remoteCfg,
                eventTracker: tracker,
                experimentManager: experimentMgr
            )
        }

        // v0.3 managers
        let surveyMgr = Self.initSubsystem("surveys") {
            SurveyManager(
                remoteConfigManager: remoteCfg,
                eventTracker: tracker,
                apiClient: self.apiClient,
                experimentManager: experimentMgr
            )
        }
        self.surveyManager = surveyMgr
        if let surveyMgr {
            remoteCfg.onSurveyConfigsUpdated { configs in
                surveyMgr.updateConfigs(configs)
            }
        }

        self.webEntitlementManager = Self.initSubsystem("web_entitlements") {
            WebEntitlementManager(eventTracker: tracker)
        }

        // SPEC-203: per-user journey-triggered message listener. Renders
        // delivered messages via the same MessageRenderer used for
        // remote-config-driven messages (modal/fullscreen/banner/tooltip
        // with full styling + rich media).
        self.pendingMessageListener = PendingMessageListener(
            eventTracker: tracker
        )

        if let bootstrapData = self.bootstrapData {
            self.deferredDeepLinkManager = DeferredDeepLinkManager(
                orgId: bootstrapData.orgId,
                appId: bootstrapData.appId,
                eventTracker: tracker
            )
        }

        // Fetch Firestore configs (includes onboarding + messages + surveys)
        remoteCfg.fetchConfigs()

        // Start web entitlement observer if user is identified
        if let userId = self.identityManager?.currentIdentity.userId,
           let bootstrapData = self.bootstrapData {
            self.webEntitlementManager?.startObserving(
                orgId: bootstrapData.orgId,
                appId: bootstrapData.appId,
                userId: userId
            )
            // SPEC-203: also start pending-messages listener if already identified.
            self.pendingMessageListener?.startObserving(
                orgId: bootstrapData.orgId,
                appId: bootstrapData.appId,
                userId: userId
            )
        }

        // Wire module namespaces (v1.0). (Billing is wired in `performConfigure`, right after its bridge
        // is built: ready from the first call, not after the bootstrap.)
        AppDNA.onboarding.manager = self.onboardingFlowManager
        AppDNA.paywall.paywallManager = self.paywallManager
        AppDNA.remoteConfig.manager = remoteCfg
        AppDNA.features.manager = self.featureFlagManager
        AppDNA.inAppMessages.manager = self.messageManager
        AppDNA.surveys.manager = self.surveyManager
        AppDNA.experiments.manager = self.experimentManager

        // Load config bundle version (v1.0 offline-first)
        self.loadConfigBundle()

        // Mark ready. Reached from BOTH performBootstrap exits — success and failure — so an offline
        // launch still becomes ready (with cached/bundled config) rather than hanging every host that
        // awaits it.
        self.isReady = true
        Self.recordBootstrapOutcome(applied: true)
        tracker.track(event: "sdk_initialized", properties: nil)
        Log.info("SDK ready")

        let callbacks = self.readyCallbacks
        self.readyCallbacks = []
        for cb in callbacks {
            DispatchQueue.main.async { cb() }
        }
    }

    // MARK: - Config Bundle (v1.0 offline-first)

    /// Load config from bundle embedded in app binary.
    /// Priority: remote (already fetched) > cached > bundled.
    private func loadConfigBundle() {
        // Try to load bundled config from app resources
        guard let bundleURL = Bundle.main.url(forResource: "appdna-config", withExtension: "json"),
              let data = try? Data(contentsOf: bundleURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.debug("No bundled config found at appdna-config.json — using remote/cached only")
            return
        }

        let bundleVersion = json["bundle_version"] as? Int ?? 0
        AppDNA.currentBundleVersion = bundleVersion

        // Feed bundled config to RemoteConfigManager — only fills empty caches
        remoteConfigManager?.loadBundledConfig(json)
        Log.info("Loaded bundled config (version \(bundleVersion))")
    }

    // MARK: - Helpers

    /// A third-party billing provider (RevenueCat / Adapty) reports that the subscriber's state moved.
    ///
    /// Under `.providerOwned` the subscription observer does not watch `Transaction.updates` — the
    /// provider owns transaction finishing — so this is how a renewal is noticed without waiting for the
    /// next app foreground. The pass is serialized inside the observer, so this is safe to call from any
    /// thread, as often as the provider fires: a redundant call re-reads the same entitlements, diffs
    /// them against the snapshot it just wrote, and emits nothing.
    /// The purchase path's one snapshot pass after a subscription purchase, so the
    /// first renewal diffs against the right baseline. Awaits the pass (serialized in the observer).
    internal static func reconcileSubscriptionStateNow() async {
        let observer: SubscriptionStatusObserver? = shared.queue.sync { shared.subscriptionObserver }
        await observer?.reconcile()
    }

    internal static func reconcileSubscriptionState() {
        // Hopped onto the SDK queue, like every other cross-thread read of a manager the configure path
        // writes: a provider callback arrives on the provider's own thread, and `subscriptionObserver`
        // is assigned during `configure()`.
        shared.queue.async {
            shared.subscriptionObserver?.reconcileNow()
        }
    }

    // MARK: - Lifecycle

    /// Shut down the SDK and release resources.
    /// Makes one last upload attempt of the queued events (what it cannot send stays on disk and goes at
    /// the next `configure`) and resets internal state.
    /// After calling shutdown the SDK must be re-configured before use.
    public static func shutdown() {
        // 🔴 CLEAR `isConfigured` SYNCHRONOUSLY, UNDER THE SAME LOCK `configure()` READS — OR A
        // shutdown()→configure() PAIR LEAVES THE SDK DEAD FOR THE PROCESS.
        //
        // `configure()` checks `isConfigured` synchronously under `initLock` and returns early if it is
        // true. This flag used to be flipped to false ONLY inside the async teardown block below. So the
        // ordinary sign-out→sign-in / RN-reload sequence — `shutdown(); configure()` on the same tick —
        // ran `configure()` while the teardown was merely SCHEDULED, `isConfigured` was still true, and
        // the configure was IGNORED. The teardown then nilled everything, and the SDK stayed dead (no
        // pipeline, no billing, no managers) until the process restarted. There is no completion
        // callback on `shutdown()` for a host to wait on, so it could not even be worked around.
        //
        // Flipped here, on the caller's thread, before the async teardown is queued: a `configure()`
        // that follows now sees `false` and proceeds. Its `performConfigure` is enqueued on the same
        // serial `queue` strictly AFTER this teardown (configure double-hops through main first), so the
        // rebuild lands after the teardown — correct order, no lost re-configure.
        shared.initLock.lock()
        shared.isConfigured = false
        let shutdownEpoch = shared.configureEpoch
        // The shutdown is its own generation: a bootstrap still in flight for `shutdownEpoch` is stale
        // from this instant, even if no `configure()` follows (see `performBootstrap`). The session-scoped
        // gates below still receive `shutdownEpoch` — the configure this shutdown ends.
        shared.configureEpoch &+= 1
        // A failed bootstrap's retry loop belongs to the configure that just ended.
        let recovery = shared.bootstrapRecovery
        shared.bootstrapRecovery = nil
        shared.initLock.unlock()
        recovery?.stop()

        // 🔴 DROP THE ENTITLEMENT HANDLERS SYNCHRONOUSLY, FOR THE SAME REASON `isConfigured` IS CLEARED
        // SYNCHRONOUSLY ABOVE. This used to live inside the async `billing.teardown()` below, which made
        // it a race against the caller rather than a guarantee: `shutdown(); configure()` on one tick
        // (sign-out→sign-in, an RN reload) re-registers a handler the moment `shutdown()` RETURNS, and
        // the teardown then landed and removed THAT handler — so entitlement changes stopped being
        // delivered at all, which is strictly worse than the duplicate delivery the removal exists to
        // prevent. Clearing here makes the contract positional instead of temporal: once `shutdown()`
        // returns, the pre-shutdown handlers are gone and anything registered afterwards is the
        // caller's and survives. `teardown()` deliberately no longer clears them.
        billing.removeAllEntitlementsChangedHandlers()
        // …and the WEB-entitlement handlers, for the same reason. They used to be cleared inside the async
        // teardown below, so a wrapper that re-registered on the `configure()` that followed on the same
        // tick (React Native and Flutter both do) had its new handler removed by the late teardown, and
        // `onWebEntitlementChanged` went silent for the rest of the process.
        removeAllWebEntitlementChangedHandlers()

        // Clear the push configured point synchronously: the notification proxy stays
        // installed (removing it could orphan a library that wrapped it) but becomes pass-through for
        // AppDNA pushes until the next `configure()`.
        PushGate.shared.markShutDown(epoch: shutdownEpoch)

        shared.queue.async {
            // 🔴 BILLING GOES DOWN FIRST — BEFORE THE PIPELINE THAT REPORTS IT.
            //
            // This used to happen ~70 lines below, AFTER `eventTracker` was released. Between those two
            // points the SDK sat in the single worst state it can occupy: **able to charge the user, and
            // unable to tell anyone it did.** A `purchase()` landing in that window took the money and
            // emitted nothing — no `purchase_completed`, no `subscription_started` — so the subscriber
            // was never metered, in the customer's revenue dashboard or in our billing.
            //
            // The window was real, not theoretical: the behavioural test for this caught it on the first
            // run, from a plain `AppDNA.billing.purchase()` issued right after `shutdown()`.
            //
            // Order the teardown by blast radius: stop what can spend money, then stop what observes it.
            billing.teardown()
            // No drain until the next `configure` has loaded the identity again.
            // (Session-scoped: a `configure()` that followed on the same tick has a newer epoch and its
            // activation is never undone by this late deactivation.)
            Task { await PurchaseDeliveryQueue.shared.deactivate(session: shutdownEpoch) }

            // One last upload attempt of the queued events; what it cannot send stays on disk for the next
            // `configure`. `flushForShutdown` keeps the queue alive until the attempt has finished — with
            // `flush()` the queue was released before its weak-captured attempt ran (Android makes the same
            // one attempt in `EventQueue.shutdown()`).
            shared.eventQueue?.flushForShutdown()
            shared.eventQueue = nil
            shared.runtimeConfigCache = nil
            shared.eventTracker = nil
            // The `Transaction.updates` listener is a long-lived Task holding the tracker we just
            // released. Cancel it, or a re-configure()d SDK ends up with two live listeners.
            shared.subscriptionObserver?.stop()
            shared.subscriptionObserver = nil
            shared.sessionManager = nil
            shared.apiClient = nil
            // `isConfigured` was already cleared synchronously at the top (under initLock) so a
            // concurrent `configure()` is not lost. Only `isReady` is cleared here.
            shared.isReady = false
            // SPEC-070-B PN row 10 (iOS half): a static that outlives the instance must be reset, or a
            // re-configure()d SDK attributes its first events to the previous run's last screen.
            lastScreenName = nil
            initErrorLock.lock()
            _lastInitError = nil
            initErrorLock.unlock()

            // (The web-entitlement handlers are dropped SYNCHRONOUSLY at the top of `shutdown()`, like the
            // billing ones — see `removeAllWebEntitlementChangedHandlers()`.)

            // (The `billing` facade — bridge, tracker and entitlement handlers — was released at the TOP
            // of this method. `billing` is a process-global `static let`, so `shutdown()` cannot nil the
            // object; it must nil what the object HOLDS. It used to release only the entitlement
            // handlers, leaving `billing.bridge` — the SDK's one STRONG facade reference — alive, so
            // `AppDNA.billing.purchase(...)` kept executing real StoreKit purchases after shutdown.)

            // 🔴 SHUTDOWN LEFT MOST OF THE SDK RUNNING.
            //
            // This method released the event pipeline, the session and the API client — and left
            // THIRTEEN subsystem managers alive, holding references to the very `apiClient` and
            // `eventTracker` it had just dropped. Android nulls all eighteen of its own
            // (`AppDNA.kt` shutdown), and its comment says it is mirroring THIS method. It was not.
            //
            // Found by a test that injected a failure into every subsystem and then asked
            // `subsystemsUp()`. Four came back UP — not because the isolation seam was broken (it
            // works; every manager is built through `initSubsystem`), but because they were STALE
            // OBJECTS FROM A PREVIOUS `configure()` that `shutdown()` had never released. So the new
            // diagnostic was lying, and it was lying because the thing it diagnoses was.
            //
            // Beyond the leak: `webEntitlementManager` and `pendingMessageListener` are OBSERVERS. A
            // host that calls `shutdown()` — on sign-out, on teardown — reasonably expects the SDK to
            // stop. Half of it did not.
            shared.identityManager = nil
            shared.remoteConfigManager = nil
            shared.featureFlagManager = nil
            shared.experimentManager = nil
            shared.paywallManager = nil
            shared.billingBridge = nil
            shared.onboardingFlowManager = nil
            shared.messageManager = nil
            shared.pendingMessageListener = nil
            shared.pushTokenManager = nil
            shared.surveyManager = nil
            shared.webEntitlementManager = nil
            shared.deferredDeepLinkManager = nil
            shared.screenManager = nil

            Log.info("AppDNA SDK shut down")
        }
    }

    /// The top-most presented view controller, resolved from the key window.
    ///
    /// `public` for cross-platform wrappers (SPEC-070-B): a React Native / Flutter host has no
    /// `UIViewController` of its own to hand `presentPaywall(placement:from:)`, and the SDK already
    /// uses this exact resolver internally (`PaywallModule.present` at `AppDNA+Modules.swift`). A
    /// wrapper needs the same entry point rather than reimplementing key-window traversal.
    public static func topViewController() -> UIViewController? {
        // UIApplication.shared must be accessed on the main thread
        if Thread.isMainThread {
            return _findTopViewController()
        } else {
            var result: UIViewController?
            DispatchQueue.main.sync {
                result = _findTopViewController()
            }
            return result
        }
    }

    private static func _findTopViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var vc = root
        while let presented = vc.presentedViewController {
            vc = presented
        }
        return vc
    }
}

// MARK: - Bootstrap response

struct BootstrapData: Codable {
    let orgId: String
    let appId: String
    let firestorePath: String
    let settings: BootstrapSettings
    let geo: BootstrapGeo?
    // SPEC-404 — optional runtime_lock. Backend sends this only when the
    // tenant is per-key-suspended (day 20+) or cancelled. Older SDKs that
    // pre-date this field still deserialise the response — Swift's Decodable
    // ignores unknown keys by default, and the Optional means missing key
    // decodes to nil. Forward-compatible across both directions.
    let runtime_lock: BootstrapRuntimeLock?
}

struct BootstrapSettings: Codable {
    /// Runtime settings the server may set (seconds / events / seconds). Optional so an answer that omits
    /// one still decodes; a missing or non-positive value leaves the default (see `RuntimeSettings`).
    let flushInterval: Int?
    let batchSize: Int?
    let configTTL: Int?
    /// SPEC-451 — the customer's own Mapbox token, set once in the console. Optional so every
    /// pre-451 backend response still decodes.
    let mapboxToken: String?
    /// SPEC-495 §B — the customer's Google Maps key, same delivery path and same optionality so a
    /// backend that has not shipped the field yet still decodes.
    let googleMapsApiKey: String?
    /// SPEC-495 §B — `mapbox` | `google`, chosen once per app. Optional so a backend that has not
    /// shipped the field yet still decodes.
    let mapProvider: String?
}

struct BootstrapGeo: Codable {
    let country: String?
    let region: String?
    let city: String?
    let timezone: String?
    let latitude: Double?
    let longitude: Double?
}

/// SPEC-404 — runtime lock payload from the bootstrap response. When present,
/// the SDK enters locked mode: paywall_trigger nodes auto-skip, messages and
/// surveys pause, identify continues to work locally (anchor + UserDefaults),
/// event uploads cleanly disable via the existing eventUploadPermanentlyFailed
/// flag on first 401.
public struct BootstrapRuntimeLock: Codable, Sendable {
    /// Backend-supplied reason for the lock. `org_cancelled` is terminal;
    /// `billing_overdue` and `manual_admin` clear when the back end restores.
    public let reason: String
    /// ISO-8601 string the lock was first observed (per-key suspended_at when
    /// available, else the moment the bootstrap saw org=cancelled).
    public let locked_at: String
}

/// `diagnose()` number formatting.
enum DiagnoseFormat {
    /// Seconds as given: 0.5 → "0.5", 5 → "5". (The veto wait used to print `Int(...)`, so 0.5 s read "0s".)
    static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return String(value) }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
