import Foundation
import Combine

/// Manages multi-screen flow navigation with back stack, navigation rules, and response accumulation.
internal class FlowManager: ObservableObject {
    @Published var currentScreenIndex: Int = 0
    @Published var navigationStack: [String] = []

    let flowConfig: FlowConfig
    let screens: [String: ScreenConfig]
    var responses: [String: Any] = [:]
    var screensViewed: [String] = []
    let startTime = Date()

    var onComplete: ((FlowResult) -> Void)?

    /// The ONE action router. Flow actions and single-screen actions used to be routed by two
    /// different switches, and the flow one handled 4 of 21 verbs — so a console-authored CTA worked
    /// on a screen and did nothing in a flow. Both paths now share `ScreenManager`'s router (which
    /// also applies the `onScreenAction` veto gate). Injectable so a test can observe the OS-facing
    /// edge (`urlOpener`) without a device.
    internal var router: ScreenManager = .shared

    /// Test seam: fires next to every analytics emit this manager makes, mirroring
    /// `EventTracker.eventSink`. `AppDNA.track` BUFFERS events until `configure()` has run, so a flow
    /// emit is not observable through the tracker's own sink in a unit test. Nil in production.
    internal var eventSink: ((String, [String: Any]) -> Void)?

    private var flowScreens: [FlowScreenRef] { flowConfig.screens ?? [] }

    var currentScreen: ScreenConfig? {
        guard currentScreenIndex < flowScreens.count else { return nil }
        guard let screenId = flowScreens[currentScreenIndex].screen_id else { return nil }
        return screens[screenId]
    }

    var currentScreenId: String? {
        guard currentScreenIndex < flowScreens.count else { return nil }
        return flowScreens[currentScreenIndex].screen_id
    }

    init(flowConfig: FlowConfig, screens: [String: ScreenConfig]) {
        self.flowConfig = flowConfig
        self.screens = screens

        // Start from the configured start screen
        if let startIdx = flowScreens.firstIndex(where: { $0.screen_id == flowConfig.start_screen_id }) {
            self.currentScreenIndex = startIdx
        }

        if let firstScreenId = currentScreenId {
            screensViewed.append(firstScreenId)
        }
    }

    /// Handle every `SectionAction` the SDUI layer can dispatch inside a flow.
    ///
    /// THE BUG THIS FIXES: this method handled `.next` / `.back` / `.dismiss` / `.navigate` and
    /// `break`-ed on everything else under the comment "Other actions handled by parent". No parent
    /// existed — `ScreenPresenter.presentFlow` wires `context.onAction` straight to this method, so
    /// inside a FLOW a console-authored "show_paywall" / "deep_link" / "open_url" / "track" button did
    /// NOTHING, while the identical button worked on a single screen and on Android.
    ///
    /// Mirrors Android `screens/FlowManager.kt handleAction(...)` (case for case, same emitted event
    /// names): flow-level verbs (navigation, response accumulation, paywall/message/purchase signals)
    /// are handled here; every platform-level verb is delegated to the single router in
    /// `ScreenManager` that the single-screen path already used, so the two paths cannot drift again.
    func handleAction(_ action: SectionAction) {
        switch action {
        // Flow navigation (Android FlowManager.kt:51-59).
        case .dismiss:
            dismissFlow()
        case .next:
            advanceToNextScreen()
        case .back:
            navigateBack()
        case .navigate(let screenId):
            navigateToScreen(screenId)
        case .restart:
            restartFlow()
        case .complete:
            completeFlow()

        // Response accumulation (Android FlowManager.kt:61-63). Without this, `responses` stayed
        // empty forever: `evaluateCondition` could never match a navigation rule and `FlowResult`
        // always handed the host `{}` — conditional flows were structurally broken.
        case .setResponse(let key, let value):
            if let value = value { mergeResponses([key: value]) }

        case .presentPaywall(let id):
            if let paywallId = id { AppDNA.showPaywall(paywallId) }

        // Android FlowManager.kt:69 — the paywall host dismisses itself; nothing to do at flow level.
        case .dismissPaywall:
            break

        case .showMessage(let id):
            let props: [String: Any] = ["message_id": id ?? ""]
            eventSink?(messageRequestEvent, props)
            AppDNA.track(event: messageRequestEvent, properties: props)

        // Android FlowManager.kt:91-102 — merge the trait, then re-`identify` under the existing
        // user id (looked up as `user_id`, then `userId`); no id means no identify call.
        case .setUserProperty(let key, let value):
            guard let value = value else { break }
            var traits = AppDNA.getUserTraits()
            traits[key] = value
            let userId = (traits["user_id"] as? String) ?? (traits["userId"] as? String) ?? ""
            if !userId.isEmpty {
                AppDNA.identify(userId: userId, traits: traits)
            }

        // Android FlowManager.kt:104-110 — the SDK signals the intent; the host paywall manager
        // performs the buy/restore.
        case .purchase(let productId):
            let props: [String: Any] = ["product_id": productId]
            eventSink?(purchaseRequestEvent, props)
            AppDNA.track(event: purchaseRequestEvent, properties: props)
        case .restore:
            eventSink?(restoreRequestEvent, [:])
            AppDNA.track(event: restoreRequestEvent, properties: [:])

        // Every platform-level verb: one router, shared with the single-screen path.
        case .openURL, .openWebview, .deepLink, .openAppSettings, .share, .showPaywall,
             .showSurvey, .showScreen, .submitForm, .track, .haptic, .custom:
            router.handleAction(
                action,
                screenId: currentScreenId ?? "",
                startTime: startTime,
                completion: nil
            )
        }
    }

    /// Android FlowManager.kt:122-130 — re-enter the start screen, preserving `responses`.
    private func restartFlow() {
        guard let startIdx = flowScreens.firstIndex(where: { $0.screen_id == flowConfig.start_screen_id })
        else { return }
        navigationStack.removeAll()
        currentScreenIndex = startIdx
        if let screenId = currentScreenId {
            screensViewed.append(screenId)
        }
    }

    private func advanceToNextScreen() {
        guard currentScreenIndex < flowScreens.count else {
            completeFlow()
            return
        }

        let currentRef = flowScreens[currentScreenIndex]

        // Evaluate navigation rules in array order, first match wins
        for rule in currentRef.navigation_rules ?? [] {
            if evaluateCondition(rule) {
                switch rule.target ?? "next" {
                case "next":
                    moveToNext()
                case "end":
                    completeFlow()
                default:
                    navigateToScreen(rule.target ?? "next")
                }
                return
            }
        }

        // Default: advance to next
        moveToNext()
    }

    private func moveToNext() {
        if currentScreenIndex + 1 < flowScreens.count {
            if let screenId = currentScreenId {
                navigationStack.append(screenId)
            }
            currentScreenIndex += 1
            if let screenId = currentScreenId {
                screensViewed.append(screenId)
            }
        } else {
            completeFlow()
        }
    }

    private func navigateBack() {
        if let previousScreenId = navigationStack.popLast() {
            if let index = flowScreens.firstIndex(where: { $0.screen_id == previousScreenId }) {
                currentScreenIndex = index
            }
        }
    }

    private func navigateToScreen(_ screenId: String) {
        if let index = flowScreens.firstIndex(where: { $0.screen_id == screenId }) {
            if let currentId = currentScreenId {
                navigationStack.append(currentId)
            }
            currentScreenIndex = index
            screensViewed.append(screenId)
        }
    }

    private func completeFlow() {
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let result = FlowResult(
            flowId: flowConfig.id ?? "",
            completed: true,
            lastScreenId: currentScreenId ?? "",
            responses: responses,
            screensViewed: screensViewed,
            duration_ms: duration
        )
        onComplete?(result)
    }

    func dismissFlow() {
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let result = FlowResult(
            flowId: flowConfig.id ?? "",
            completed: false,
            lastScreenId: currentScreenId ?? "",
            responses: responses,
            screensViewed: screensViewed,
            duration_ms: duration
        )
        onComplete?(result)
    }

    private func evaluateCondition(_ rule: NavigationRule) -> Bool {
        let context = ["responses": responses]
        return ConditionEvaluator.evaluateCondition(
            type: rule.condition ?? "always",
            variable: rule.variable,
            value: rule.value?.value,
            context: context
        )
    }

    func mergeResponses(_ newResponses: [String: Any]) {
        for (key, value) in newResponses {
            responses[key] = value
        }
    }
}

// MARK: - Flow action signal events

/// The three analytics signals a flow action raises when the SDK cannot perform the action itself and
/// the host must (present an in-app message, buy, restore).
///
/// Names + property keys are Android's, verbatim, from `screens/FlowManager.kt`:
/// `message_request` / `message_id` (kt:77), `purchase_request` / `product_id` (kt:105),
/// `restore_request` (kt:109, no props). Constants rather than literals at the call sites so a rename
/// has to happen in one place — `scripts/check-event-name-parity.ts` resolves constants, so these
/// still count as iOS emits for the parity gate.
internal let messageRequestEvent = "message_request"
internal let purchaseRequestEvent = "purchase_request"
internal let restoreRequestEvent = "restore_request"
