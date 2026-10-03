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

    private func presentFeedbackForm(message: String?) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                  var rootVC = windowScene.windows
                .first(where: { $0.isKeyWindow })?
                .rootViewController else { return }

            while let presented = rootVC.presentedViewController {
                rootVC = presented
            }
            let topVC = rootVC

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
                self?.eventTracker.track(event: "feedback_form_submitted", properties: [
                    "feedback": feedback,
                ])
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.eventTracker.track(event: "feedback_form_dismissed", properties: nil)
            })
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

        // Emoji: last 2 = positive, first 2 = negative
        if (config.survey_type ?? "") == "emoji_scale" || answers.first?.answer is String {
            let emojis = ["😡", "😕", "😐", "😊", "😍"]
            if let first = answers.first, let emoji = first.answer as? String,
               let idx = emojis.firstIndex(of: emoji) {
                if idx >= 3 { return .positive }
                if idx <= 1 { return .negative }
                return .neutral
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
