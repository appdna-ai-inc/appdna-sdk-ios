import Foundation
import UIKit
import SwiftUI

/// Manages in-app message trigger evaluation, frequency tracking, and presentation.
final class MessageManager {
    private let remoteConfigManager: RemoteConfigManager
    private let eventTracker: EventTracker
    /// SPEC-036-F §1.2 — consulted per-candidate (inside the present hook) for a
    /// running in-app-message experiment targeting the message being shown.
    private let experimentManager: ExperimentManager?
    private let frequencyTracker = MessageFrequencyTracker()
    private var isPresenting = false

    /// When true, suppresses display of in-app messages.
    var suppressDisplay = false

    // Date-only fallback for hand-authored / legacy configs. UTC midnight to match Android's
    // `parseWindowDate` fallback, so a bare `yyyy-MM-dd` window opens on the same instant on both
    // platforms rather than device-local midnight (which drifted by the device's UTC offset).
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The server serializes `start_date`/`end_date` via `Date.toISOString()` — a full ISO-8601
    /// instant with fractional seconds and `Z`. Parse that instant first (exact time-of-day, and
    /// identical to Android), and only fall back to the date-only shape for legacy/authored values.
    /// The old bare `yyyy-MM-dd` formatter (device time zone) did NOT read the server's full string:
    /// `DateFormatter.date(from:)` must consume the whole string, so it returned nil and the window
    /// was ignored; a date-only value opened at device-local midnight. The fallback is non-lenient
    /// and whole-string: a zone-less instant (`2026-05-07T10:00:00`) and an impossible date
    /// (`2026-02-30`) are nil; `yyyy-MM-dd` is UTC midnight. Unparsable → nil (treated as no
    /// constraint). Pinned with Android by the shared fixture `dto_parsing/message_window_date_parsing`.
    static func parseWindowDate(_ s: String) -> Date? {
        ISO8601.date(from: s) ?? dateOnlyFormatter.date(from: s)
    }

    init(
        remoteConfigManager: RemoteConfigManager,
        eventTracker: EventTracker,
        experimentManager: ExperimentManager? = nil
    ) {
        self.remoteConfigManager = remoteConfigManager
        self.eventTracker = eventTracker
        self.experimentManager = experimentManager
    }

    /// Evaluate all active messages against an event. Called internally after every track() call.
    func onEvent(eventName: String, properties: [String: Any]?) {
        guard !isPresenting, !suppressDisplay else {
            Log.debug("[Messages] Skipping event '\(eventName)' — isPresenting=\(isPresenting), suppressDisplay=\(suppressDisplay)")
            return
        }

        let messages = remoteConfigManager.getActiveMessages()
        Log.debug("[Messages] Evaluating \(messages.count) active message(s) for event '\(eventName)'")
        var candidates: [(id: String, config: MessageConfig)] = []
        var filteredByEvent = 0
        var filteredByConditions = 0
        var filteredByFrequency = 0
        var filteredByDateRange = 0

        for (id, config) in messages {
            // 1. Event name match
            guard config.trigger_rules?.event == eventName else {
                filteredByEvent += 1
                continue
            }

            // 2. Conditions evaluation
            guard evaluateConditions(config.trigger_rules?.conditions, properties: properties ?? [:]) else {
                filteredByConditions += 1
                continue
            }

            // 3. Frequency check
            guard frequencyTracker.canShow(
                messageId: id,
                frequency: config.trigger_rules?.frequency ?? .once,
                maxDisplays: config.trigger_rules?.max_displays
            ) else {
                filteredByFrequency += 1
                continue
            }

            // 4. Date range check
            guard checkDateRange(config) else {
                filteredByDateRange += 1
                continue
            }

            candidates.append((id: id, config: config))
        }

        if candidates.isEmpty {
            Log.debug("[Messages] No candidates for '\(eventName)' — filtered: event=\(filteredByEvent), conditions=\(filteredByConditions), frequency=\(filteredByFrequency), dateRange=\(filteredByDateRange)")
        } else {
            Log.debug("[Messages] \(candidates.count) candidate(s) passed all filters for '\(eventName)'")
        }

        // 5. Sort by priority (highest first), tie-broken by id (lowest wins) for a DETERMINISTIC winner.
        // `sorted(by:)` is not guaranteed stable and `candidates` derives from an unordered Dictionary
        // (`getActiveMessages()`), so priority-only sorting picked a nondeterministic message run-to-run
        // among equal-priority candidates — and diverged from Android, which does
        // `compareByDescending { priority }.thenBy { it.first }` (lowest id wins).
        guard let winner = candidates.sorted(by: {
            let p0 = $0.config.priority ?? 0, p1 = $1.config.priority ?? 0
            return p0 != p1 ? p0 > p1 : $0.id < $1.id
        }).first else {
            return
        }

        // 6. Present with optional delay
        let delay = winner.config.trigger_rules?.delay_seconds ?? 0
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
                self?.present(messageId: winner.id, activeConfig: winner.config, triggerEvent: eventName)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.present(messageId: winner.id, activeConfig: winner.config, triggerEvent: eventName)
            }
        }
    }

    /// Reset session-level frequency tracking.
    func resetSession() {
        frequencyTracker.resetSession()
    }

    // MARK: - Presentation

    private func present(messageId: String, activeConfig: MessageConfig, triggerEvent: String) {
        // SPEC-400 / SPEC-404 — the three synchronous suppression rules (already-presenting, SDK
        // runtime-locked, host `shouldShowMessage` veto), consulted BEFORE any analytics tracking or
        // view construction so a suppressed message produces no `in_app_message_shown` event. The
        // gate now also runs ahead of the experiment resolution below, which records an exposure as a
        // side effect — a message the host vetoed was never seen, so it must not count as exposed.
        guard MessagePresentationGate.shouldPresent(
            messageId: messageId,
            isPresenting: isPresenting,
            runtimeLocked: AppDNA.runtimeLock != nil,
            delegate: AppDNA.inAppMessages.delegate
        ) else { return }

        // SPEC-036-F §1.2 — experiment-aware presentation, attached inside the
        // candidate/present path (not a host present() call). A running in-app-
        // message experiment targeting this message + a treatment bucket renders
        // the treatment payload; control / non-bucketed / old-doc → active.
        var config = activeConfig
        if let experimentManager,
           case let .renderTreatment(_, _, payload) = experimentManager.resolveSurfacePresentation(surfaceType: "in_app_message", entityId: messageId),
           let treatment = remoteConfigManager.decodeMessagePayload(payload) {
            Log.info("In-app message \(messageId) rendering experiment treatment variant")
            config = treatment
        }

        // SPEC-070-C D10 — OPTIONAL async wrapper-veto. Awaited in ADDITION to
        // the synchronous delegate veto above so a cross-platform wrapper host
        // (Flutter) that can only answer asynchronously (round-trip to Dart)
        // can still suppress a message. When nil (every native host), the
        // remainder runs synchronously exactly as before — no behavior change.
        // `present()` already runs on the main queue (dispatched from onEvent).
        if let asyncVeto = AppDNA.inAppMessages.asyncShouldShowMessage {
            Task { @MainActor [weak self] in
                let allow = await asyncVeto(messageId)
                guard allow else {
                    Log.debug("In-app message \(messageId) suppressed by host asyncShouldShowMessage veto")
                    return
                }
                self?.presentBody(messageId: messageId, config: config, triggerEvent: triggerEvent)
            }
            return
        }

        presentBody(messageId: messageId, config: config, triggerEvent: triggerEvent)
    }

    /// The presentation remainder, extracted so the D10 async wrapper-veto can
    /// gate it behind an awaited decision. `config` is the experiment-resolved
    /// config computed by `present(...)`. Runs on the main queue.
    private func presentBody(messageId: String, config: MessageConfig, triggerEvent: String) {
        guard !isPresenting else { return }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            Log.warning("No root view controller available for in-app message")
            return
        }

        // Find topmost presented VC
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        isPresenting = true
        frequencyTracker.recordShown(messageId: messageId, frequency: config.trigger_rules?.frequency ?? .once)

        // Track shown
        eventTracker.track(event: "in_app_message_shown", properties: [
            "message_id": messageId,
            "message_type": config.message_type?.rawValue ?? "modal",
            "trigger_event": triggerEvent,
        ])

        // SPEC-400 — fire onMessageShown to the host's registered
        // delegate alongside the existing analytics track.
        DispatchQueue.main.async {
            AppDNA.inAppMessages.delegate?.onMessageShown(messageId: messageId, trigger: triggerEvent)
        }

        let messageView = MessageRenderer(
            messageId: messageId,
            config: config,
            onCTATap: { [weak self] in
                self?.eventTracker.track(event: "in_app_message_clicked", properties: [
                    "message_id": messageId,
                    "cta_action": config.content?.cta_action?.type?.rawValue ?? "dismiss",
                ])
                // SPEC-400 — fire onMessageAction with action type + cta_action data.
                let ctaActionType = config.content?.cta_action?.type?.rawValue ?? "dismiss"
                let ctaData: [String: Any]? = {
                    guard let cta = config.content?.cta_action, let url = cta.url else { return nil }
                    return ["url": url]
                }()
                DispatchQueue.main.async {
                    AppDNA.inAppMessages.delegate?.onMessageAction(messageId: messageId, action: ctaActionType, data: ctaData)
                }
                self?.handleCTAAction(config.content?.cta_action)
                topVC.dismiss(animated: true) {
                    self?.isPresenting = false
                    DispatchQueue.main.async {
                        AppDNA.inAppMessages.delegate?.onMessageDismissed(messageId: messageId)
                    }
                }
            },
            onDismiss: { [weak self] in
                self?.eventTracker.track(event: "in_app_message_dismissed", properties: [
                    "message_id": messageId,
                ])
                topVC.dismiss(animated: true) {
                    self?.isPresenting = false
                    // SPEC-400 — fire onMessageDismissed.
                    DispatchQueue.main.async {
                        AppDNA.inAppMessages.delegate?.onMessageDismissed(messageId: messageId)
                    }
                }
            }
        )

        let hostingVC = UIHostingController(rootView: messageView)
        hostingVC.modalPresentationStyle = config.message_type == .fullscreen ? .fullScreen : .overCurrentContext
        hostingVC.modalTransitionStyle = .crossDissolve
        hostingVC.view.backgroundColor = .clear
        topVC.present(hostingVC, animated: true)
    }

    // MARK: - Condition evaluation

    private func evaluateConditions(_ conditions: [TriggerCondition]?, properties: [String: Any]) -> Bool {
        guard let conditions, !conditions.isEmpty else { return true }

        return conditions.allSatisfy { condition in
            guard let field = condition.field, let propValue = properties[field] else { return false }
            guard let op = condition.`operator` else { return false }
            guard let condValue = condition.value?.value else { return false }
            return evaluateOperator(op, propValue: propValue, condValue: condValue)
        }
    }

    private func evaluateOperator(_ op: TriggerCondition.ConditionOperator, propValue: Any, condValue: Any) -> Bool {
        switch op {
        case .eq:
            return "\(propValue)" == "\(condValue)"
        case .gte:
            guard let pNum = toDouble(propValue), let cNum = toDouble(condValue) else { return false }
            return pNum >= cNum
        case .lte:
            guard let pNum = toDouble(propValue), let cNum = toDouble(condValue) else { return false }
            return pNum <= cNum
        case .gt:
            guard let pNum = toDouble(propValue), let cNum = toDouble(condValue) else { return false }
            return pNum > cNum
        case .lt:
            guard let pNum = toDouble(propValue), let cNum = toDouble(condValue) else { return false }
            return pNum < cNum
        case .contains:
            return "\(propValue)".contains("\(condValue)")
        }
    }

    private func toDouble(_ value: Any) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Date range

    private func checkDateRange(_ config: MessageConfig) -> Bool {
        let now = Date()
        if let startStr = config.start_date,
           let start = Self.parseWindowDate(startStr),
           now < start {
            return false
        }
        if let endStr = config.end_date,
           let end = Self.parseWindowDate(endStr),
           now > end {
            return false
        }
        return true
    }

    // MARK: - CTA actions

    private func handleCTAAction(_ action: CTAAction?) {
        guard let action, let actionType = action.type else { return }
        switch actionType {
        case .dismiss, .unknown:
            break // dismiss handled by caller
        case .deep_link, .open_url:
            // SPEC-070-B PN row 18 (W11): config-driven URL — scheme-checked before it reaches the OS.
            if let urlString = action.url, let url = URLSafety.sanitized(urlString) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}

// MARK: - In-app message presentation gate (SPEC-400 / SPEC-404)

/// The synchronous "may this message be shown at all?" decision. Extracted from
/// `MessageManager.present` because the three rules it folds together (already-presenting,
/// SDK runtime-locked, host `shouldShowMessage` veto) each suppress a message SILENTLY — a
/// regression in any of them is invisible except as a message that stops appearing on a device.
///
/// The async wrapper-veto (`asyncShouldShowMessage`) is deliberately NOT part of this gate: it is
/// awaited, so it cannot be a pure decision.
enum MessagePresentationGate {
    static func shouldPresent(
        messageId: String,
        isPresenting: Bool,
        runtimeLocked: Bool,
        delegate: AppDNAInAppMessageDelegate?
    ) -> Bool {
        if isPresenting { return false }
        // Messages already shown stay visible; no analytics event is emitted for the suppressed one.
        if runtimeLocked {
            Log.debug("In-app message \(messageId) suppressed — SDK in runtime-locked mode")
            return false
        }
        // The protocol's default extension returns `true`, so hosts that don't implement this method
        // are unaffected. The delegate is read fresh on every call by the caller.
        if let delegate, delegate.shouldShowMessage(messageId: messageId) == false {
            Log.debug("In-app message \(messageId) suppressed by host shouldShowMessage veto")
            return false
        }
        return true
    }
}
