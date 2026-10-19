import Foundation
import UIKit

/// Manages survey trigger evaluation, display queue, frequency tracking, and presentation.
final class SurveyManager {
    private let remoteConfigManager: RemoteConfigManager
    private let eventTracker: EventTracker
    private let apiClient: APIClient?
    /// Consulted per-survey (inside the present path) for a
    /// running survey experiment targeting the survey being shown.
    private let experimentManager: ExperimentManager?
    private let frequencyTracker = SurveyFrequencyTracker()
    private let renderer = SurveyRenderer()
    private var isPresenting = false

    private var surveyConfigs: [String: SurveyConfig] = [:]

    init(
        remoteConfigManager: RemoteConfigManager,
        eventTracker: EventTracker,
        apiClient: APIClient? = nil,
        experimentManager: ExperimentManager? = nil
    ) {
        self.remoteConfigManager = remoteConfigManager
        self.eventTracker = eventTracker
        self.apiClient = apiClient
        self.experimentManager = experimentManager
    }

    /// Present a specific survey by ID.
    func present(surveyId: String) {
        guard let config = surveyConfigs[surveyId] else {
            Log.warning("Survey config not found for id: \(surveyId)")
            return
        }
        presentSurvey(surveyId: surveyId, config: config, triggerEvent: "manual")
    }

    /// Called by RemoteConfigManager when Firestore config/surveys updates.
    func updateConfigs(_ configs: [String: SurveyConfig]) {
        self.surveyConfigs = configs
    }

    /// Called by EventTracker on every tracked event.
    func onEvent(eventName: String, properties: [String: Any]?) {
        guard !isPresenting else { return }

        // Iterate in ASCENDING surveyId order for a DETERMINISTIC winner when
        // multiple surveys match one event. `surveyConfigs` is an unordered Dictionary, so the
        // plain `for-in ... break` picked a hash-order survey that varied run-to-run AND diverged
        // from Android. SurveyConfig has no priority field, so id-asc is the tie-break — the same
        // rule MessageManager uses (priority desc, then id asc). Both platforms now agree.
        for (surveyId, config) in surveyConfigs.sorted(by: { $0.key < $1.key }) {
            // 1. Event name match
            guard config.trigger_rules?.event == eventName else { continue }

            // 2. Conditions evaluation
            guard evaluateConditions(config.trigger_rules?.conditions, properties: properties ?? [:]) else { continue }

            // 3. Frequency check
            guard frequencyTracker.canShow(
                surveyId: surveyId,
                frequency: config.trigger_rules?.frequency ?? .once,
                maxDisplays: config.trigger_rules?.max_displays
            ) else { continue }

            // 4. Love score range check
            if let range = config.trigger_rules?.love_score_range {
                let loveScore = UserDefaults.standard.integer(forKey: "ai.appdna.sdk.love_score")
                guard loveScore >= (range.min ?? 0) && loveScore <= (range.max ?? 100) else { continue }
            }

            // 5. Min sessions check
            guard meetsMinSessions(config.trigger_rules?.min_sessions) else { continue }

            // 5. Present with optional delay
            let delay = config.trigger_rules?.delay_seconds ?? 0
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
                    self?.presentSurvey(surveyId: surveyId, config: config, triggerEvent: eventName)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentSurvey(surveyId: surveyId, config: config, triggerEvent: eventName)
                }
            }
            break // Only show one survey per event
        }
    }

    /// Reset session-level frequency tracking.
    func resetSession() {
        frequencyTracker.resetSession()
    }

    // MARK: - Presentation

    private func presentSurvey(surveyId: String, config activeConfig: SurveyConfig, triggerEvent: String) {
        guard !isPresenting else { return }

        // Pause new survey presentation while the SDK is
        // backend-locked (per-key suspended day 20+ OR org cancelled). No
        // analytics event, no delegate fire.
        if AppDNA.runtimeLock != nil {
            Log.debug("Survey \(surveyId) suppressed — SDK in runtime-locked mode")
            return
        }

        // Experiment-aware presentation, attached inside the
        // present path (surveys are event-auto-triggered, not host present()).
        // A running survey experiment targeting this survey + a treatment
        // bucket renders the treatment payload; control / none / old-doc →
        // active (cohort isolation).
        // resolveSurfacePresentation records an experiment_exposure as a side effect, so it
        // MUST run AFTER every synchronous suppression gate (isPresenting above + runtimeLock here): a
        // survey that is never shown must never count as exposed. Was above the runtimeLock guard, so a
        // runtime-locked (suspended/cancelled) org recorded exposures for surveys it never displayed.
        var config = activeConfig
        if let experimentManager,
           case let .renderTreatment(_, _, payload) = experimentManager.resolveSurfacePresentation(surfaceType: "survey", entityId: surveyId),
           let treatment = remoteConfigManager.decodeSurveyPayload(payload) {
            Log.info("Survey \(surveyId) rendering experiment treatment variant")
            config = treatment
        }

        isPresenting = true

        // Track survey shown
        eventTracker.track(event: "survey_shown", properties: [
            "survey_id": surveyId,
            "survey_type": config.survey_type ?? "",
            "trigger_event": triggerEvent,
        ])

        // Fire onSurveyPresented to the host's registered
        // survey delegate. Read fresh on every callback; no init-time
        // capture. Default extension (empty no-op) means hosts that
        // don't implement this method are unaffected.
        DispatchQueue.main.async {
            AppDNA.surveys.delegate?.onSurveyPresented(surveyId: surveyId)
        }

        renderer.present(config: config, onQuestionAnswered: { [weak self] surveyName, question, answer in
            self?.eventTracker.track(event: "survey_question_answered", properties: [
                "survey_id": surveyId,
                "question_id": question.id ?? "",
                "question_type": question.type ?? "",
                "answer": answer.answer,
            ])
        }) { [weak self] result in
            guard let self else { return }
            self.isPresenting = false

            switch result {
            case .completed(let answers):
                self.frequencyTracker.recordDisplay(surveyId: surveyId)
                self.trackSurveyCompleted(surveyId: surveyId, config: config, answers: answers)
                self.submitResponse(surveyId: surveyId, config: config, answers: answers)
                self.executeFollowUpAction(surveyId: surveyId, config: config, answers: answers)
                // Fire onSurveyCompleted with the responses
                // mapped to the public `[SurveyResponse]` shape.
                let responses = answers.map { SurveyResponse(questionId: $0.question_id, answer: $0.answer) }
                DispatchQueue.main.async {
                    AppDNA.surveys.delegate?.onSurveyCompleted(surveyId: surveyId, responses: responses)
                }

            case .dismissed(let answeredCount):
                self.frequencyTracker.recordDisplay(surveyId: surveyId)
                self.eventTracker.track(event: "survey_dismissed", properties: [
                    "survey_id": surveyId,
                    "questions_answered": answeredCount,
                ])
                // Fire onSurveyDismissed.
                DispatchQueue.main.async {
                    AppDNA.surveys.delegate?.onSurveyDismissed(surveyId: surveyId)
                }
            }
        }
    }

    // MARK: - Event tracking

    private func trackSurveyCompleted(surveyId: String, config: SurveyConfig, answers: [SurveyAnswer]) {
        let answersArray = answers.map { $0.asDictionary }
        eventTracker.track(event: "survey_completed", properties: [
            "survey_id": surveyId,
            "survey_type": config.survey_type ?? "",
            "answers": answersArray,
        ])
    }

    // MARK: - Response submission

    private func submitResponse(surveyId: String, config: SurveyConfig, answers: [SurveyAnswer]) {
        let body: [String: Any] = [
            "survey_id": surveyId,
            "user_id": AppDNA.currentUserId ?? "anonymous",
            "platform": "ios",
            "answers": answers.map { $0.asDictionary },
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "context": [
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "device_type": UIDevice.current.model,
                "session_count": UserDefaults.standard.integer(forKey: "ai.appdna.sdk.session_count"),
                "days_since_install": self.daysSinceInstall(),
            ],
        ]

        apiClient?.post(path: "/api/v1/feedback/responses", body: body) { result in
            switch result {
            case .success:
                Log.debug("Survey response submitted for \(surveyId)")
            case .failure(let error):
                Log.error("Failed to submit survey response: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Follow-up actions

    /// Survey follow-up actions.
    ///
    /// 🔴 This was half a feature. `.positive` fired ONLY for `prompt_review`, `.negative` ONLY for
    /// `show_feedback_form`, and `.neutral` was a bare `break` — `actions.on_neutral` (declared at
    /// SurveyConfig.swift:265, authorable in the console) was never read by any line of iOS code.
    /// `trigger_winback` — which the console offers as a first-class choice for detractors
    /// (`src/modules/feedback-loop/entities/Survey.ts:107`) — did LITERALLY NOTHING on iOS while
    /// Android fired it. And iOS emitted no follow-up analytics at all, so the whole
    /// `survey_followup_*` funnel was an Android-only dataset.
    ///
    /// Now mirrors Android `feedback/SurveyManager.kt:299-343` exactly: sentiment (including
    /// neutral) selects the action; the action string routes to prompt_review / show_feedback_form /
    /// trigger_winback / dismiss; and each fires the same event name with the same property keys.
    /// `internal`, not `private`: the follow-up dispatch had NO test seam at all, which is how half
    /// of it (neutral, trigger_winback, every follow-up event) stayed unimplemented on iOS while
    /// Android shipped it.
    internal func executeFollowUpAction(surveyId: String, config: SurveyConfig, answers: [SurveyAnswer]) {
        let sentiment = determineSentiment(config: config, answers: answers)
        guard let actions = config.follow_up_actions else { return }

        let followUp: FollowUpAction?
        switch sentiment {
        case .positive: followUp = actions.on_positive
        case .negative: followUp = actions.on_negative
        case .neutral: followUp = actions.on_neutral
        }
        guard let followUp else { return }

        // Android sends `sentiment.name.lowercase()` — "positive" / "negative" / "neutral".
        let sentimentName = sentiment.analyticsName

        /*
         #897 — A STORE REVIEW PROMPT IS NEVER CONDITIONED ON THE ANSWER.

         The sentiment branch above is the right shape for every OTHER follow-up: a feedback form
         for unhappy users and a thank-you for happy ones are ordinary product decisions. A store
         review is not, and both stores say so in almost the same words.

           Apple   don't ask the customer a question before, or while, presenting the rating
                   prompt, and don't filter who sees it by how they answered
           Google  "Don't ask the user any questions before presenting the rating button or card,
                   including questions about their opinion"

         `on_positive: {action: "prompt_review"}` is exactly that filter, and three production
         surveys were authored that way — because the console invited it. So if ANY branch asks for
         a review, every respondent who finishes the survey is eligible and the OS quota decides
         the rest. The respondent's own branch still runs below, unchanged.

         Mirrors Android `SurveyManager.kt` executeFollowUp.
         */
        let anyBranchAsksForReview = [actions.on_positive, actions.on_negative, actions.on_neutral]
            .contains { $0?.action == "prompt_review" }
        if anyBranchAsksForReview && followUp.action != "prompt_review" {
            ReviewPromptManager.shared.triggerReview()
            eventTracker.track(event: surveyFollowUpReviewEvent, properties: [
                "survey_id": surveyId,
                "sentiment": sentimentName,
            ])
        }

        switch followUp.action ?? "" {
        case "prompt_review":
            // Native review prompt first; the event lets the host handle the case where the OS
            // suppressed it (Android SurveyManager.kt:311-318).
            ReviewPromptManager.shared.triggerReview()
            eventTracker.track(event: surveyFollowUpReviewEvent, properties: [
                "survey_id": surveyId,
                "sentiment": sentimentName,
            ])

        case "show_feedback_form":
            presentFeedbackForm(message: followUp.message)
            eventTracker.track(event: surveyFollowUpFeedbackFormEvent, properties: [
                "survey_id": surveyId,
                "sentiment": sentimentName,
            ])

        case "trigger_winback":
            // The SDK signals; the host launches the winback campaign (Android SurveyManager.kt:329-336).
            eventTracker.track(event: surveyFollowUpWinbackEvent, properties: [
                "survey_id": surveyId,
                "sentiment": sentimentName,
                "message": followUp.message ?? "",
            ])

        case "dismiss":
            break

        default:
            break
        }
    }

    /**
     #901 — the controller a feedback form can ACTUALLY be presented on.

     The old walk took the topmost presented controller unconditionally. At the moment this runs
     the topmost one is the survey sheet, mid-dismissal — and UIKit does not leak the way Android
     did, it logs `Attempt to present … which is already presenting / being dismissed` and does
     **nothing**. So the form silently never appeared, on the branch a user takes when they have
     just said the experience was bad: the branch least likely to be exercised and the one where
     being asked nothing further matters most.

     The rule is Android's, in UIKit terms (`SurveyManager.kt` — prefer un-paused and alive, fall
     back to any ALIVE one): walk the presentation chain and stop ABOVE anything that is being
     dismissed, landing on the controller underneath, which is where a post-survey form belongs.

     `static` and taking its root as a parameter so a test can drive it with a real controller
     hierarchy instead of a simulator and a finger.
     */
    static func presentableController(from root: UIViewController) -> UIViewController {
        var current = root
        // `isBeingDismissed` is the one that matters here, but a controller whose own view has
        // already gone cannot present either.
        while let presented = current.presentedViewController,
              !presented.isBeingDismissed,
              presented.viewIfLoaded?.window != nil || presented.isViewLoaded == false {
            current = presented
        }
        return current
    }

    /**
     #901 — how many times to come back and look, and how long to wait between.

     Deferring once is not enough: `isBeingDismissed` is false again the instant the transition
     ends, but the PRESENTER is still busy until its `presentedViewController` clears, and that is
     one more run loop. Ten tries at 100ms is a second, comfortably longer than a sheet dismissal
     and short enough that a user who tapped "bad" is still looking at the screen.
     */
    /*
     #920 — A FORM THAT IS TAKEN AWAY IS NOT A FORM THE USER DISMISSED.

     #901 fixed the presentation: the form lands on the controller underneath, which is staying.
     The reverse was left open — a form that is UP when its presenter goes away for a reason of the
     host's own (a window torn down, a root view controller swapped, a deep link replacing the
     stack). UIKit takes the alert down with its presenter and nothing is recorded, so
     `feedback_form_dismissed` under-counts and the two outcomes are indistinguishable in analytics:
     a user who read the form and closed it, and a user who never saw it at all.

     Android gets this from its activity lifecycle. iOS has no equivalent for an alert presented
     from a framework, so the presenter's DEALLOCATION is the signal — observed by attaching an
     object whose own `deinit` fires when the controller is released.

     🔴 THE EVENT IS THE FIX. UIKit already removes the alert from the screen; what was missing was
     anybody knowing it had happened. Measured: a red control that deletes the dismissal below
     leaves the UI test green, and a red control that deletes the latch fails two unit tests.

     🔴 Everything here is weak or one-shot. The SDK must never keep a host's controller alive, and
     the event must fire exactly once: `feedbackFormResolved` is set by Submit, by Cancel, and by
     this path, whichever happens first.
    */
    private weak var feedbackFormAlert: UIAlertController?
    /// `true` means "no form is outstanding", which is the state before one is ever shown.
    var feedbackFormResolved = true

    /// Fires its closure when the object it is attached to is deallocated.
    ///
    /// Internal rather than private so a test can prove the mechanism without a window: driving the
    /// real `present(_:animated:)` in a hostless test target HANGS — there is no active window
    /// scene, so the transition never completes — which is why `FeedbackFormPresenterTests` tests
    /// the DECISION rather than the presentation. Same reasoning here.
    final class PresenterReleaseObserver {
        private let onRelease: () -> Void
        init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        // swiftlint:disable:next implicit_deinit
        deinit { onRelease() }
    }

    private nonisolated(unsafe) static var presenterObserverKey: UInt8 = 0

    /// Attach `observer` to `owner` so it is released when `owner` is. Internal for the test above.
    static func observeRelease(of owner: AnyObject, _ observer: PresenterReleaseObserver) {
        objc_setAssociatedObject(
            owner, &presenterObserverKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Record that the form has ended, once, with WHY. Internal so a test can prove "once".
    func resolveFeedbackForm(reason: String) {
        guard !feedbackFormResolved else { return }
        feedbackFormResolved = true
        eventTracker.track(event: "feedback_form_dismissed", properties: ["reason": reason])
    }

    private static let feedbackFormRetries = 10
    private static let feedbackFormRetryDelay: TimeInterval = 0.1

    private func presentFeedbackForm(message: String?, attempt: Int = 0) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                  let rootVC = windowScene.windows
                .first(where: { $0.isKeyWindow })?
                .rootViewController else { return }

            let topVC = Self.presentableController(from: rootVC)

            // Still finishing a dismissal: the chosen controller is correct but cannot present
            // until its own `presentedViewController` has gone. Come back rather than fire into a
            // warning and vanish.
            if topVC.presentedViewController != nil {
                guard attempt < Self.feedbackFormRetries else {
                    Log.warning("Feedback form skipped: \(type(of: topVC)) still presenting after "
                                + "\(Self.feedbackFormRetries) attempts")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackFormRetryDelay) {
                    self.presentFeedbackForm(message: message, attempt: attempt + 1)
                }
                return
            }

            let alert = UIAlertController(
                title: message ?? "We'd love your feedback",
                message: "What could we do better?",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.placeholder = "Tell us what you think..."
            }
            alert.addAction(UIAlertAction(title: "Submit", style: .default) { [weak self] _ in
                let feedback = alert.textFields?.first?.text ?? ""
                // Submitting ENDS the form, so the orphan path below must not also fire for it.
                self?.feedbackFormResolved = true
                self?.eventTracker.track(event: "feedback_form_submitted", properties: [
                    "feedback": feedback,
                ])
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                // #920 — the reason is new; `user` is what every form dismissed before this change
                // was, so a reader of old data can treat an absent reason as this one.
                self?.resolveFeedbackForm(reason: "user")
            })

            self.feedbackFormAlert = alert
            self.feedbackFormResolved = false
            /*
             #920 — when the PRESENTER is released, the alert goes with it and the user never
             answered. Attached to the controller rather than observed globally, so it cannot
             outlive what it is about, and holding only `[weak self]` so the SDK is not kept alive
             by a host's view controller either.
             */
            let observer = PresenterReleaseObserver { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    /*
                     🔴 DEFENSIVE, AND MEASURED TO BE SO. Removing this line leaves
                     `testAFormIsTakenDownWithItsPresenter` GREEN: UIKit already tears an alert down
                     when the controller that presented it is released, which is the common path and
                     was never the defect. Stated here because the obvious reading of this line is
                     that it is what makes the test pass, and a reader who believes that will delete
                     the EVENT below as redundant.
                     What this covers is the case UIKit does not: an alert retained elsewhere whose
                     presenter has gone. It targets the ALERT rather than `presentingViewController`,
                     which is nil by this point for exactly the reason the observer fired.
                    */
                    self.feedbackFormAlert?.dismiss(animated: false)
                    self.feedbackFormAlert = nil
                    self.resolveFeedbackForm(reason: "presenter_released")
                }
            }
            Self.observeRelease(of: topVC, observer)
            topVC.present(alert, animated: true)
        }
    }

    private func determineSentiment(config: SurveyConfig, answers: [SurveyAnswer]) -> SurveySentiment {
        // NPS: 9-10 = positive, 0-6 = negative, 7-8 = neutral
        if (config.survey_type ?? "") == "nps", let first = answers.first, let score = first.answer as? Int {
            if score >= 9 { return .positive }
            if score <= 6 { return .negative }
            return .neutral
        }

        // CSAT/Rating: >= 4 (out of 5) = positive, <= 2 = negative
        if ["csat", "rating"].contains(config.survey_type ?? ""), let first = answers.first, let rating = first.answer as? Int {
            if rating >= 4 { return .positive }
            if rating <= 2 { return .negative }
            return .neutral
        }

        /*
         * Emoji: above the middle of the scale is positive, below it negative, the middle itself
         * neutral.
         *
         * 🔴 THE SCALE IS THE AUTHORED ONE, not a hard-coded five. This compared the answer
         * against a literal list of the five DEFAULT emoji and gave up when the index was not
         * found — so an author who customised `emoji_config.emojis` at all (a three-emoji scale, a
         * different set of five) got `neutral` for every respondent, and `follow_up_actions`
         * silently stopped routing. Nothing failed; the feature just never fired. Found by reading
         * both emitters for the docs audit, and the same literal was in the Kotlin.
         *
         * The midpoint rule reproduces the old thresholds exactly for a five-emoji scale
         * (positive 3-4, negative 0-1, neutral 2) and is defined for every other length.
         */
        if (config.survey_type ?? "") == "emoji_scale" || answers.first?.answer is String {
            if let first = answers.first, let emoji = first.answer as? String {
                let authored = config.questions?
                    .first { ($0.id ?? "") == first.question_id }?
                    .emoji_config?.emojis
                let emojis = (authored?.isEmpty == false ? authored : nil)
                    ?? ["😡", "😕", "😐", "😊", "😍"]
                if let idx = emojis.firstIndex(of: emoji) {
                    let middle = Double(emojis.count - 1) / 2.0
                    if Double(idx) > middle { return .positive }
                    if Double(idx) < middle { return .negative }
                    return .neutral
                }
            }
        }

        return .neutral
    }

    // MARK: - Condition evaluation (shared with MessageManager pattern)

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

    // MARK: - Min sessions

    private func meetsMinSessions(_ minSessions: Int?) -> Bool {
        guard let min = minSessions, min > 0 else { return true }
        let sessionCount = UserDefaults.standard.integer(forKey: "ai.appdna.sdk.session_count")
        return sessionCount >= min
    }

    private func daysSinceInstall() -> Int {
        let installKey = "ai.appdna.sdk.install_date"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: installKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: installKey)
        }
        let installTs = defaults.double(forKey: installKey)
        let elapsed = Date().timeIntervalSince1970 - installTs
        return max(0, Int(elapsed / 86400))
    }
}

// MARK: - Survey follow-up events

/// The three analytics signals a survey follow-up raises. Names + property keys are Android's,
/// verbatim, from `feedback/SurveyManager.kt:316/325/331`. Constants rather than literals at the
/// call sites so a rename has to happen in one place — `scripts/check-event-name-parity.ts` resolves
/// constants, so these still count as iOS emits for the parity gate.
internal let surveyFollowUpReviewEvent = "survey_followup_prompt_review"
internal let surveyFollowUpFeedbackFormEvent = "survey_followup_feedback_form"
internal let surveyFollowUpWinbackEvent = "survey_followup_winback"
