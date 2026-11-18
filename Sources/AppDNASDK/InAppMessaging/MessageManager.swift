import Foundation
import UIKit
import SwiftUI

/// Where a config-driven in-app message is drawn. The default draws over the top view controller of a FOREGROUND
/// scene; a test passes its own.
struct MessageSurface {
    /// The view controller to present on, or nil when no foreground scene has a key window — a background launch (a
    /// content-available push, a background fetch) connects a scene in the BACKGROUND, and nobody can see it.
    var host: () -> UIViewController?
    /// Puts the message's hosting controller on screen over `host`.
    var show: (_ messageId: String, _ host: UIViewController, _ content: UIViewController) -> Void
    /// Takes the message down from `host`, then runs `done`.
    var close: (_ host: UIViewController, _ done: @escaping () -> Void) -> Void
    /// Runs `block` each time the app (one of its scenes) becomes active; the closure it returns stops that.
    var observeActivation: (_ block: @escaping () -> Void) -> (() -> Void)

    static var live: MessageSurface { MessageSurface(
        host: {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let index = PendingMessageListener.drawableSceneIndex(scenes.map(\.activationState)),
                  let root = scenes[index].windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        },
        show: { _, host, content in host.present(content, animated: true) },
        close: { host, done in host.dismiss(animated: true, completion: done) },
        observeActivation: PendingMessageListener.observeAppActivation
    ) }
}

/// Manages in-app message trigger evaluation, frequency tracking, and presentation.
///
/// A message triggered while the app has no foreground scene (a background launch) is HELD — not drawn, not counted
/// shown, its frequency not used up — and drawn the next time the app becomes active in the same process, if it is
/// still published, still inside its date window and still allowed by its frequency. A held message is held once
/// (a second trigger does not queue a second copy), and drawing it takes it off the hold, so it is drawn at most once.
final class MessageManager {
    private let remoteConfigManager: RemoteConfigManager
    private let eventTracker: EventTracker
    /// Consulted per-candidate (inside the present hook) for a
    /// running in-app-message experiment targeting the message being shown.
    private let experimentManager: ExperimentManager?
    private let frequencyTracker = MessageFrequencyTracker()
    private var isPresenting = false
    private let surface: MessageSurface

    /// A message triggered with no foreground scene to draw in, waiting for the app to become active.
    private struct Held { let messageId: String; let triggerEvent: String }
    /// In trigger order. Read and written on the main queue.
    private var held: [Held] = []
    private var stopActivation: (() -> Void)?
    /// Closes the message on screen as its dismiss control does — the test seam behind a fixture's `close`.
    private var dismissOnScreen: (() -> Void)?

    /// When true, suppresses display of in-app messages. Turning it off draws a held message if the app is active.
    var suppressDisplay = false {
        didSet {
            guard oldValue, !suppressDisplay else { return }
            DispatchQueue.main.async { [weak self] in self?.releaseHeld() }
        }
    }

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
        experimentManager: ExperimentManager? = nil,
        surface: MessageSurface = .live
    ) {
        self.remoteConfigManager = remoteConfigManager
        self.eventTracker = eventTracker
        self.experimentManager = experimentManager
        self.surface = surface
        self.stopActivation = surface.observeActivation({ [weak self] in self?.releaseHeld() })
    }

    deinit { stopActivation?() }

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

    // MARK: - Held messages

    /// The ids of the held messages, in trigger order (tests).
    var heldMessageIds: [String] { held.map(\.messageId) }

    /// No foreground scene: keep the message for the next activation. Nothing is recorded — it was not seen.
    private func hold(_ messageId: String, triggerEvent: String, atFront: Bool = false) {
        guard !held.contains(where: { $0.messageId == messageId }) else {
            Log.debug("[Messages] \(messageId) already held — not queued twice")
            return
        }
        let h = Held(messageId: messageId, triggerEvent: triggerEvent)
        if atFront { held.insert(h, at: 0) } else { held.append(h) }
        Log.debug("[Messages] No foreground scene — holding \(messageId) until the app is active")
    }

    /// The app became active, or a message was closed: draw the first held message that may still be shown. One at a
    /// time; the next is drawn when that one closes. Each is re-read from the current config, so a message
    /// unpublished, out of its date window, or used up by its frequency while it waited is dropped.
    func releaseHeld() {
        guard !isPresenting, !suppressDisplay, !held.isEmpty, surface.host() != nil else { return }
        let active = remoteConfigManager.getActiveMessages()
        while !held.isEmpty {
            let h = held.removeFirst()
            guard let config = active[h.messageId],
                  frequencyTracker.canShow(
                      messageId: h.messageId,
                      frequency: config.trigger_rules?.frequency ?? .once,
                      maxDisplays: config.trigger_rules?.max_displays
                  ),
                  checkDateRange(config) else {
                Log.debug("[Messages] Held \(h.messageId) is no longer showable — dropped")
                continue
            }
            Log.debug("[Messages] App active — presenting held \(h.messageId)")
            present(messageId: h.messageId, activeConfig: config, triggerEvent: h.triggerEvent, fromHold: true)
            return
        }
    }

    /// Closes the message on screen through its own dismiss path (tests).
    func dismissOnScreenForTesting() { dismissOnScreen?() }

    // MARK: - Presentation

    private func present(messageId: String, activeConfig: MessageConfig, triggerEvent: String, fromHold: Bool = false) {
        // The three synchronous suppression rules (already-presenting, SDK
        // runtime-locked, host `shouldShowMessage` veto), consulted BEFORE any analytics tracking or
        // view construction so a suppressed message produces no `in_app_message_shown` event. The
        // gate now also runs ahead of the experiment resolution below, which records an exposure as a
        // side effect — a message the host vetoed was never seen, so it must not count as exposed.
        guard MessagePresentationGate.shouldPresent(
            messageId: messageId,
            isPresenting: isPresenting,
            runtimeLocked: AppDNA.runtimeLock != nil,
            delegate: AppDNA.inAppMessages.delegate
        ) else {
            // A held message that lost the race to one now on screen: back on the hold, first.
            if fromHold, isPresenting { hold(messageId, triggerEvent: triggerEvent, atFront: true) }
            return
        }

        // No foreground scene (a background launch): held AFTER the gate above, so a message the host vetoes is
        // dropped as before, and BEFORE the experiment resolution (which records an exposure) and the async veto. The
        // gate is asked again when it is drawn.
        guard surface.host() != nil else {
            hold(messageId, triggerEvent: triggerEvent, atFront: fromHold)
            return
        }

        // Experiment-aware presentation, attached inside the
        // candidate/present path (not a host present() call). A running in-app-
        // message experiment targeting this message + a treatment bucket renders
        // the treatment payload; control / non-bucketed / old-doc → active.
        // The content on screen, from the SERVED message: an experiment treatment is told
        // apart by `context.experiment_exposures`, not by these keys (D6).
        let contentStamp = ContentStamp.props(for: activeConfig)
        var config = activeConfig
        if let experimentManager,
           case let .renderTreatment(_, _, payload) = experimentManager.resolveSurfacePresentation(surfaceType: "in_app_message", entityId: messageId),
           let treatment = remoteConfigManager.decodeMessagePayload(payload) {
            Log.info("In-app message \(messageId) rendering experiment treatment variant")
            config = treatment
        }

        // OPTIONAL async wrapper-veto. Awaited in ADDITION to
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
                self?.presentBody(messageId: messageId, config: config, triggerEvent: triggerEvent, fromHold: fromHold, contentStamp: contentStamp)
            }
            return
        }

        presentBody(messageId: messageId, config: config, triggerEvent: triggerEvent, fromHold: fromHold, contentStamp: contentStamp)
    }

    /// The presentation remainder, extracted so the D10 async wrapper-veto can
    /// gate it behind an awaited decision. `config` is the experiment-resolved
    /// config computed by `present(...)`. Runs on the main queue.
    private func presentBody(messageId: String, config: MessageConfig, triggerEvent: String, fromHold: Bool = false, contentStamp: [String: Any] = [:]) {
        guard !isPresenting else {
            // A held message that lost the race to another (an async veto answered late): back on the hold, first.
            if fromHold { hold(messageId, triggerEvent: triggerEvent, atFront: true) }
            return
        }

        // Only a FOREGROUND scene is somewhere to draw. `connectedScenes.first` was any scene, and a background launch
        // connects one in the background with a key window: the message was drawn where nobody could see it, counted
        // shown, and a `once` message was used up.
        guard let topVC = surface.host() else {
            hold(messageId, triggerEvent: triggerEvent, atFront: fromHold)
            return
        }

        // Drawn now: a held copy of the same message is this one, so it is not drawn again on the next activation.
        held.removeAll { $0.messageId == messageId }
        isPresenting = true
        frequencyTracker.recordShown(messageId: messageId, frequency: config.trigger_rules?.frequency ?? .once)

        // Track shown
        eventTracker.track(event: "in_app_message_shown", properties: ContentStamp.stamped([
            "message_id": messageId,
            "message_type": config.message_type?.rawValue ?? "modal",
            "trigger_event": triggerEvent,
        ], contentStamp))

        // Fire onMessageShown to the host's registered
        // delegate alongside the existing analytics track.
        DispatchQueue.main.async {
            AppDNA.inAppMessages.delegate?.onMessageShown(messageId: messageId, trigger: triggerEvent)
        }

        let messageView = MessageRenderer(
            messageId: messageId,
            config: config,
            onCTATap: { [weak self] in
                self?.eventTracker.track(event: "in_app_message_clicked", properties: ContentStamp.stamped([
                    "message_id": messageId,
                    "cta_action": config.content?.cta_action?.type?.rawValue ?? "dismiss",
                ], contentStamp))
                // Fire onMessageAction with action type + cta_action data.
                let ctaActionType = config.content?.cta_action?.type?.rawValue ?? "dismiss"
                let ctaData: [String: Any]? = {
                    guard let cta = config.content?.cta_action, let url = cta.url else { return nil }
                    return ["url": url]
                }()
                DispatchQueue.main.async {
                    AppDNA.inAppMessages.delegate?.onMessageAction(messageId: messageId, action: ctaActionType, data: ctaData)
                }
                self?.handleCTAAction(config.content?.cta_action)
                // A `share` CTA opens the share sheet once the message is gone, from the
                // screen underneath; a blank share is a plain dismiss.
                self?.closeOnScreen(topVC, messageId: messageId, share: MessageCTAShare.payload(config.content?.cta_action))
            },
            onDismiss: { [weak self] in
                self?.eventTracker.track(event: "in_app_message_dismissed", properties: ContentStamp.stamped([
                    "message_id": messageId,
                ], contentStamp))
                self?.closeOnScreen(topVC, messageId: messageId)
            }
        )

        dismissOnScreen = messageView.onDismiss
        let hostingVC = MessageHosting.makeHost(rootView: messageView, config: config)
        surface.show(messageId, topVC, hostingVC)
    }

    private func closeOnScreen(_ host: UIViewController, messageId: String, share: SharePayload? = nil) {
        dismissOnScreen = nil
        surface.close(host) { [weak self] in
            self?.isPresenting = false
            if let share { ShareAction.present(share) }
            // Fire onMessageDismissed.
            DispatchQueue.main.async {
                AppDNA.inAppMessages.delegate?.onMessageDismissed(messageId: messageId)
            }
            // The next held message, if one is waiting — not over a share sheet just opened; it waits for the next
            // activation instead.
            if share == nil { self?.releaseHeld() }
        }
    }

    // MARK: - Condition evaluation

    private func evaluateConditions(_ conditions: [TriggerCondition]?, properties: [String: Any]) -> Bool {
        guard let conditions, !conditions.isEmpty else { return true }

        return conditions.allSatisfy { condition in
            guard let field = condition.field, let propValue = properties[field] else { return false }
            guard let op = condition.`operator` else { return false }
            guard let condValue = condition.value?.value else { return false }
            return op.matches(propValue, condValue)
        }
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
        // dismiss / unknown / a link type with no link: nothing extra (the caller dismisses).
        // Config-driven URL — scheme-checked before it reaches the OS.
        guard let urlString = action?.linkToOpen, let url = URLSafety.sanitized(urlString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - In-app message presentation gate

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
