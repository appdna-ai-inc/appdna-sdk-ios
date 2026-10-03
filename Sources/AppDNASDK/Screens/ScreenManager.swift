import Foundation
import UIKit

/// Central manager for server-driven screens. Handles config loading, caching,
/// trigger evaluation, slot resolution, navigation interception, and screen presentation.
internal class ScreenManager {
    static let shared = ScreenManager()

    private var screenIndex: ScreenIndex?
    private var screenCache: [String: ScreenConfig] = [:]
    private var flowCache: [String: FlowConfig] = [:]
    private var nestingDepth: Int = 0
    private let maxNestingDepth = 5
    private let lock = NSLock()

    /// The only way a screen action reaches the OS. Injectable so a test can assert that a vetoed
    /// action opens nothing; production keeps calling `UIApplication.shared.open`.
    internal var urlOpener: (URL) -> Void = { UIApplication.shared.open($0) }

    // MARK: - Config Loading

    func updateIndex(_ index: ScreenIndex) {
        lock.lock()
        self.screenIndex = index
        lock.unlock()
    }

    func getCachedScreen(_ screenId: String) -> ScreenConfig? {
        lock.lock()
        defer { lock.unlock() }
        return screenCache[screenId]
    }

    func cacheScreen(_ screenId: String, config: ScreenConfig) {
        lock.lock()
        screenCache[screenId] = config
        lock.unlock()
    }

    func getCachedFlow(_ flowId: String) -> FlowConfig? {
        lock.lock()
        defer { lock.unlock() }
        return flowCache[flowId]
    }

    func cacheFlow(_ flowId: String, config: FlowConfig) {
        lock.lock()
        flowCache[flowId] = config
        lock.unlock()
    }

    // MARK: - Show Screen (Manual API)

    func showScreen(_ screenId: String, completion: ((ScreenResult) -> Void)? = nil) {
        // Thread-safe nesting depth check
        lock.lock()
        guard nestingDepth < maxNestingDepth else {
            lock.unlock()
            print("[SDUI] Max nesting depth (\(maxNestingDepth)) exceeded for screen: \(screenId)")
            completion?(ScreenResult(screenId: screenId, dismissed: true, error: .nestingDepthExceeded))
            return
        }
        nestingDepth += 1
        lock.unlock()
        let startTime = Date()

        // Try cache first
        if let cached = getCachedScreen(screenId) {
            presentScreen(cached, screenId: screenId, startTime: startTime, completion: completion)
            return
        }

        // Fetch from Firestore on-demand
        // In production, this would call RemoteConfigManager.fetchScreenConfig()
        // For now, fire callback with error if not cached
        completion?(ScreenResult(screenId: screenId, dismissed: true, error: .screenNotFound))
        nestingDepth -= 1
    }

    func showFlow(_ flowId: String, completion: ((FlowResult) -> Void)? = nil) {
        if let cached = getCachedFlow(flowId) {
            presentFlow(cached, flowId: flowId, completion: completion)
            return
        }

        completion?(FlowResult(flowId: flowId, error: .screenNotFound))
    }

    func dismissScreen() {
        DispatchQueue.main.async {
            if let topVC = UIApplication.shared.topViewController {
                topVC.dismiss(animated: true)
            }
        }
    }

    // MARK: - Preview

    /// Render a screen straight from JSON. Returns whether the JSON parsed and a screen was
    /// presented — the same Bool Android returns, so a caller can branch on it.
    ///
    /// NOT `#if DEBUG`. It used to be, on both this and the `AppDNA` facade, and the wrappers call
    /// it unconditionally — a wrapper compiles in the HOST's configuration, so a Release archive
    /// could not compile the pod at all. See `AppDNA.previewScreen`.
    @discardableResult
    func previewScreen(json: String, completion: ((ScreenResult) -> Void)? = nil) -> Bool {
        guard let data = json.data(using: .utf8) else {
            Log.error("[SDUI] Invalid JSON string for preview")
            completion?(ScreenResult(screenId: "preview", dismissed: true, error: .configParseError))
            return false
        }

        do {
            let config = try JSONDecoder().decode(ScreenConfig.self, from: data)
            let startTime = Date()
            presentScreen(config, screenId: config.id ?? "preview", startTime: startTime, completion: completion)
            return true
        } catch {
            Log.error("[SDUI] Failed to parse preview JSON: \(error)")
            completion?(ScreenResult(screenId: "preview", dismissed: true, error: .configParseError))
            return false
        }
    }

    // MARK: - Presentation

    private func presentScreen(_ config: ScreenConfig, screenId: String, startTime: Date, completion: ((ScreenResult) -> Void)?) {
        // Validate config
        let sections = config.sections ?? []
        guard !sections.isEmpty else {
            completion?(ScreenResult(screenId: screenId, dismissed: true, error: .configInvalid))
            nestingDepth -= 1
            return
        }

        // Check scheduling
        if let startDate = config.start_date, let date = ISO8601.date(from: startDate), date > Date() {
            completion?(ScreenResult(screenId: screenId, dismissed: true))
            nestingDepth -= 1
            return
        }
        if let endDate = config.end_date, let date = ISO8601.date(from: endDate), date < Date() {
            completion?(ScreenResult(screenId: screenId, dismissed: true))
            nestingDepth -= 1
            return
        }

        // Resolve experiment variants
        var resolvedConfig = config
        var variantKey: String?
        if let experimentId = config.experiment_id, let variants = config.variants {
            // Check experiment bucketing
            if let bucket = AppDNA.getExperimentVariant(experimentId: experimentId) {
                variantKey = bucket
                if let override = variants[bucket] {
                    // Apply variant overrides
                    if let overrideSections = override.sections { resolvedConfig = ScreenConfig(
                        id: config.id, name: config.name, version: config.version,
                        presentation: override.presentation ?? config.presentation,
                        transition: config.transition, layout: config.layout,
                        sections: overrideSections,
                        background: override.background ?? config.background,
                        dismiss: config.dismiss, nav_bar: config.nav_bar,
                        haptic: config.haptic, particle_effect: config.particle_effect,
                        localizations: config.localizations, default_locale: config.default_locale,
                        audience_rules: config.audience_rules, trigger_rules: config.trigger_rules,
                        slot_config: config.slot_config, start_date: config.start_date,
                        end_date: config.end_date, min_sdk_version: config.min_sdk_version,
                        experiment_id: config.experiment_id, variants: config.variants,
                        analytics_name: config.analytics_name
                    )}
                }
            }
        }

        // Build context
        let context = SectionContext(
            screenId: screenId,
            onAction: { [weak self] action in
                self?.handleAction(action, screenId: screenId, startTime: startTime, completion: completion)
            }
        )

        // Track event (include experiment_id and variant_key)
        var trackProps: [String: Any] = [
            "screen_id": screenId,
            "screen_name": resolvedConfig.name,
            "presentation": resolvedConfig.presentation,
        ]
        if let expId = config.experiment_id { trackProps["experiment_id"] = expId }
        if let vk = variantKey { trackProps["variant_key"] = vk }
        AppDNA.track(event:"screen_presented", properties: trackProps)
        // Fire onScreenPresented to the host's
        // AppDNAScreenDelegate. Read fresh on every callback.
        DispatchQueue.main.async {
            AppDNA.screenDelegate?.onScreenPresented(screenId: screenId)
        }

        // Present via PresentationCoordinator
        PresentationCoordinator.shared.requestPresentation(type: .screen) {
            ScreenPresenter.present(config: resolvedConfig, context: context) { [weak self] in
                let duration = Int(Date().timeIntervalSince(startTime) * 1000)
                AppDNA.track(event:"screen_dismissed", properties: [
                    "screen_id": screenId,
                    "screen_name": config.name,
                    "duration_ms": duration,
                ])
                self?.nestingDepth -= 1
                let screenResult = ScreenResult(screenId: screenId, dismissed: true, duration_ms: duration)
                // Fire onScreenDismissed alongside the
                // existing analytics track + completion handler.
                DispatchQueue.main.async {
                    AppDNA.screenDelegate?.onScreenDismissed(screenId: screenId, result: screenResult)
                }
                completion?(screenResult)
            }
        }
    }

    private func presentFlow(_ config: FlowConfig, flowId: String, completion: ((FlowResult) -> Void)?) {
        // Collect screen configs for all screens in the flow
        var screens: [String: ScreenConfig] = [:]
        for ref in config.screens ?? [] {
            guard let sid = ref.screen_id else { continue }
            if let screenConfig = getCachedScreen(sid) {
                screens[sid] = screenConfig
            }
        }

        let flowManager = FlowManager(flowConfig: config, screens: screens)
        flowManager.onComplete = { result in
            // Emit the LITERAL event name for each terminal — the catalog-provenance gate harvests real
            // `track("…")` literals, and a ternary-built name is invisible to it, which is why
            // `flow_completed` (the flow's success terminal, the most valuable of the three) could not be
            // catalogued and thus could not be a journey/email trigger. Two literal calls, same props.
            let props: [String: Any] = [
                "flow_id": flowId,
                "flow_name": config.name,
                "screens_viewed": result.screensViewed,
                "duration_ms": result.duration_ms,
            ]
            if result.completed {
                AppDNA.track(event: "flow_completed", properties: props)
            } else {
                AppDNA.track(event: "flow_abandoned", properties: props)
            }
            // Fire onFlowCompleted to the host's
            // AppDNAScreenDelegate. Fires for both completed and
            // abandoned flows; the FlowResult.completed flag tells
            // the host which path was taken.
            DispatchQueue.main.async {
                AppDNA.screenDelegate?.onFlowCompleted(flowId: flowId, result: result)
            }
            completion?(result)
        }

        AppDNA.track(event:"flow_started", properties: [
            "flow_id": flowId,
            "flow_name": config.name ?? "",
            "start_screen_id": config.start_screen_id ?? "",
        ])

        ScreenPresenter.presentFlow(flowManager: flowManager)
    }

    // MARK: - Action Handling

    /// Internal (not private) and routed through `urlOpener` below so the D10 veto gate can be
    /// exercised without UIKit — a vetoed action that still opened its URL would otherwise only be
    /// detectable on a device.
    internal func handleAction(_ action: SectionAction, screenId: String, startTime: Date, completion: ((ScreenResult) -> Void)?) {
        // Veto gate, consulted before performing ANY action.
        //
        // (1) SYNC delegate veto: `onScreenAction` returns `Bool`. This was
        //     previously called only for `.custom` and its return value was
        //     DISCARDED — the veto was never honored. It is now the single
        //     gate for every action and a `false` reply blocks the action.
        // (2) ASYNC wrapper-veto: an optional closure a cross-platform wrapper
        //     (Flutter) registers when it can only answer asynchronously. When
        //     set, it is awaited before performing; a `false` reply blocks.
        //
        // Native hosts that don't set `asyncOnScreenAction` (all of them today)
        // keep synchronous behavior — the action is performed inline below.
        if AppDNA.screenDelegate?.onScreenAction(screenId: screenId, action: action) == false {
            Log.debug("Screen action vetoed by host onScreenAction: \(screenId)")
            return
        }
        if let asyncVeto = AppDNA.asyncOnScreenAction {
            Task { @MainActor [weak self] in
                let allow = await asyncVeto(screenId, action)
                guard allow else {
                    Log.debug("Screen action vetoed by host asyncOnScreenAction: \(screenId)")
                    return
                }
                self?.performAction(action, screenId: screenId, startTime: startTime, completion: completion)
            }
            return
        }
        performAction(action, screenId: screenId, startTime: startTime, completion: completion)
    }

    /// Run `perform` only if the host's `onScreenAction` veto (sync + async wrapper) allows it.
    /// Inline-slot actions must honor the SAME veto as full-screen actions. The iOS slot
    /// previously called `handleSlotAction` directly, bypassing the veto that Android's slot
    /// (`dispatchScreenAction`) and the full-screen `handleAction` both consult — so a host that
    /// returned `false` from `onScreenAction` had its slot buttons fire anyway.
    func dispatchSlotAction(_ action: SectionAction, screenId: String, perform: @escaping () -> Void) {
        if AppDNA.screenDelegate?.onScreenAction(screenId: screenId, action: action) == false {
            Log.debug("Slot action vetoed by host onScreenAction: \(screenId)")
            return
        }
        if let asyncVeto = AppDNA.asyncOnScreenAction {
            Task { @MainActor in
                let allow = await asyncVeto(screenId, action)
                guard allow else {
                    Log.debug("Slot action vetoed by host asyncOnScreenAction: \(screenId)")
                    return
                }
                perform()
            }
            return
        }
        perform()
    }

    /// Perform a screen action after the D10 veto gate has allowed it.
    private func performAction(_ action: SectionAction, screenId: String, startTime: Date, completion: ((ScreenResult) -> Void)?) {
        switch action {
        case .next:
            // For single screens (not flows), "next" dismisses the screen
            dismissScreen()

        case .back:
            // For single screens, "back" dismisses the screen
            dismissScreen()

        case .dismiss:
            dismissScreen()

        case .navigate(let targetScreenId):
            // Dismiss current and show target screen
            dismissScreen()
            showScreen(targetScreenId)

        case .openURL(let url):
            // Config-driven URL — scheme-checked before it reaches the OS.
            if let url = URLSafety.sanitized(url) {
                DispatchQueue.main.async { [urlOpener = self.urlOpener] in urlOpener(url) }
            }

        case .openWebview(let url):
            // Config-driven URL: scheme-check before it reaches the OS (as .openURL does, as the iOS
            // slot path does, and as Android does for all three verbs). A screen config could otherwise
            // hand `file:`/`javascript:`/`data:`/cleartext-`http:` straight to the system opener.
            if let url = URLSafety.sanitized(url) {
                DispatchQueue.main.async { [urlOpener = self.urlOpener] in
                    // SFSafariViewController would be used here
                    urlOpener(url)
                }
            }

        case .openAppSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                DispatchQueue.main.async { [urlOpener = self.urlOpener] in urlOpener(url) }
            }

        case .share(let text):
            DispatchQueue.main.async {
                let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                UIApplication.shared.topViewController?.present(vc, animated: true)
            }

        case .deepLink(let url):
            // Same scheme-check as .openURL / the slot path / Android — a raw opener here was an
            // allowlist bypass for full-screen SDUI deep-link CTAs.
            if let url = URLSafety.sanitized(url) {
                DispatchQueue.main.async { [urlOpener = self.urlOpener] in urlOpener(url) }
            }

        case .showPaywall(let id):
            if let paywallId = id {
                AppDNA.showPaywall(paywallId)
            }

        case .showSurvey(let id):
            if let surveyId = id {
                AppDNA.showSurvey(surveyId)
            }

        case .showScreen(let id):
            showScreen(id)

        case .submitForm(let data):
            // Submit form data to backend
            AppDNA.track(event:"screen_response_submitted", properties: [
                "screen_id": screenId,
                "field_count": data.count,
            ])

        case .track(let event, let properties):
            AppDNA.track(event:event, properties: properties)

        case .haptic(let type):
            if let hapticType = HapticType(rawValue: type) {
                HapticEngine.trigger(hapticType)
            }

        case .custom:
            // The host was already notified of this custom action via the D10
            // veto gate (`onScreenAction`) in `handleAction`; a custom action
            // has no built-in SDK handling beyond that host callback.
            break

        default:
            break
        }

        // Track action
        AppDNA.track(event:"screen_action", properties: [
            "screen_id": screenId,
            "action_type": String(describing: action),
        ])
    }

    // MARK: - Slot Resolution (Mechanism 2)

    func screenForSlot(_ slotName: String) -> (screenId: String, config: ScreenConfig)? {
        guard let index = screenIndex, let slots = index.slots else { return nil }

        guard let assignment = slots.first(where: { $0.slot_name == slotName }) else { return nil }

        // Check audience rules
        let userTraits = AppDNA.getUserTraits()
        if let audienceRules = assignment.audience_rules {
            if !AudienceRuleEvaluator.evaluate(rules: audienceRules, userTraits: userTraits) {
                return nil
            }
        }

        // Get screen config
        guard let screenId = assignment.screen_id,
              let config = getCachedScreen(screenId) else { return nil }

        return (screenId, config)
    }

    // MARK: - Trigger Evaluation (Mechanism 1)

    func evaluateTriggers(event: String, properties: [String: Any]?) {
        guard let index = screenIndex, let screens = index.screens else { return }
        guard AppDNA.isConsentGranted() else { return }

        let userTraits = AppDNA.getUserTraits()

        // Find matching screens sorted by priority (highest first)
        let matchingScreens = screens
            .filter { entry in
                evaluateScreenTrigger(entry, event: event, properties: properties, userTraits: userTraits)
            }
            .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }

        // Show highest priority match
        if let match = matchingScreens.first {
            guard PresentationCoordinator.shared.canPresent(type: .screen, isAutoTriggered: true) else { return }
            if let matchId = match.id { showScreen(matchId) }
        }
    }

    private func evaluateScreenTrigger(
        _ entry: ScreenIndexEntry,
        event: String,
        properties: [String: Any]?,
        userTraits: [String: Any]
    ) -> Bool {
        guard let triggerRules = entry.trigger_rules else { return false }

        // Check scheduling
        if let startDate = entry.start_date, let date = ISO8601.date(from: startDate), date > Date() {
            return false
        }
        if let endDate = entry.end_date, let date = ISO8601.date(from: endDate), date < Date() {
            return false
        }

        // Check audience rules
        if let audienceRules = entry.audience_rules {
            if !AudienceRuleEvaluator.evaluate(rules: audienceRules, userTraits: userTraits) {
                return false
            }
        }

        // Check event triggers
        if let events = triggerRules.events {
            let eventMatch = events.contains { trigger in
                guard trigger.event_name == event else { return false }
                // Check event property conditions
                if let conditions = trigger.conditions, let props = properties {
                    return conditions.allSatisfy { cond in
                        guard let field = cond.field else { return true }
                        let propValue = props[field]
                        return ConditionEvaluator.valuesEqual(propValue, cond.value?.value)
                    }
                }
                return true
            }
            if eventMatch { return true }
        }

        return false
    }

    // MARK: - Navigation Interception (Mechanism 3)

    private var interceptionEnabled = false
    private var interceptionScreenFilter: [String]?

    func enableNavigationInterception(forScreens: [String]? = nil) {
        interceptionEnabled = true
        interceptionScreenFilter = forScreens
    }

    func disableNavigationInterception() {
        interceptionEnabled = false
        interceptionScreenFilter = nil
    }

    func evaluateInterceptions(screenName: String, timing: String) {
        guard interceptionEnabled else { return }
        guard AppDNA.isConsentGranted() else { return }

        // Check filter
        if let filter = interceptionScreenFilter, !filter.contains(where: { matchGlob(pattern: $0, string: screenName) }) {
            return
        }

        guard let index = screenIndex, let interceptions = index.interceptions else { return }

        let userTraits = AppDNA.getUserTraits()

        for interception in interceptions {
            guard interception.timing ?? "" == timing else { continue }
            guard let triggerScreen = interception.trigger_screen,
                  matchGlob(pattern: triggerScreen, string: screenName) else { continue }

            // Check audience rules
            if let audienceRules = interception.audience_rules {
                if !AudienceRuleEvaluator.evaluate(rules: audienceRules, userTraits: userTraits) {
                    continue
                }
            }

            // Track and show
            guard let interceptScreenId = interception.screen_id else { continue }
            AppDNA.track(event:"interception_triggered", properties: [
                "trigger_screen": screenName,
                "timing": timing,
                "screen_id": interceptScreenId,
            ])

            showScreen(interceptScreenId)
            return // Only show one interception per navigation
        }
    }

    /// Glob-style pattern matching: "*" matches any characters, case-insensitive
    private func matchGlob(pattern: String, string: String) -> Bool {
        let p = pattern.lowercased()
        let s = string.lowercased()

        if !p.contains("*") {
            return p == s
        }

        // Simple glob: prefix*, *suffix, *contains*
        if p.hasPrefix("*") && p.hasSuffix("*") {
            let inner = String(p.dropFirst().dropLast())
            return s.contains(inner)
        } else if p.hasPrefix("*") {
            let suffix = String(p.dropFirst())
            return s.hasSuffix(suffix)
        } else if p.hasSuffix("*") {
            let prefix = String(p.dropLast())
            return s.hasPrefix(prefix)
        }

        return p == s
    }

    // MARK: - Reset

    func reset() {
        lock.lock()
        screenIndex = nil
        screenCache.removeAll()
        flowCache.removeAll()
        nestingDepth = 0
        lock.unlock()
        disableNavigationInterception()
    }
}
