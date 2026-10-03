import SwiftUI
import UIKit

/// Renders surveys as SwiftUI views and presents them in the appropriate style.
final class SurveyRenderer {

    func present(config: SurveyConfig, onQuestionAnswered: ((String, SurveyQuestion, SurveyAnswer) -> Void)? = nil, completion: @escaping (SurveyResult) -> Void) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                Log.warning("No root view controller available for survey presentation")
                return
            }

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            var view = SurveyContainerView(config: config, completion: completion)
            view.onQuestionAnswered = onQuestionAnswered
            let hostingVC = UIHostingController(rootView: view)

            switch config.appearance?.presentation ?? "modal" {
            case "fullscreen":
                hostingVC.modalPresentationStyle = .fullScreen
            case "modal":
                hostingVC.modalPresentationStyle = .pageSheet
            default: // bottom_sheet
                if #available(iOS 16.0, *) {
                    hostingVC.modalPresentationStyle = .pageSheet
                    if let sheet = hostingVC.sheetPresentationController {
                        sheet.detents = [.medium(), .large()]
                        sheet.prefersGrabberVisible = true
                    }
                } else {
                    hostingVC.modalPresentationStyle = .pageSheet
                }
            }

            hostingVC.view.backgroundColor = .clear
            topVC.present(hostingVC, animated: true)
        }
    }
}

// MARK: - Survey Container View

struct SurveyContainerView: View {
    let config: SurveyConfig
    let completion: (SurveyResult) -> Void
    var onQuestionAnswered: ((String, SurveyQuestion, SurveyAnswer) -> Void)?

    @State private var currentQuestionIndex = 0
    @State private var answers: [String: SurveyAnswer] = [:] // keyed by question_id
    @State private var visibleQuestions: [SurveyQuestion] = []
    @SwiftUI.Environment(\.dismiss) private var dismiss
    // Adapt survey styling to system dark/light mode.
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    // Rich media state
    @State private var showIntro = true
    @State private var showThankYou = false
    @State private var showConfetti = false

    /// Resolved theme for the current color scheme. In dark
    /// mode, any field set on theme.dark overrides theme.light;
    /// unset dark fields fall back to light (sparse overrides).
    private var theme: SurveyTheme? {
        config.appearance?.theme?.resolved(for: colorScheme == .dark ? .dark : .light)
    }

    private var backgroundColor: Color {
        Color(hex: theme?.background_color ?? (colorScheme == .dark ? "#1a1a1a" : "#FFFFFF"))
    }

    /// Background view honors a theme-level gradient when supplied
    /// (including when the dark variant provides one); otherwise falls back
    /// to the solid color. Safe-area handling is deliberately symmetric —
    /// both paths rely on the host container's padding so the gradient doesn't
    /// bleed under the status bar while the solid fill stays contained.
    @ViewBuilder
    private var backgroundView: some View {
        if let gradient = theme?.gradient {
            StyleEngine.linearGradient(from: gradient)
        } else {
            backgroundColor
        }
    }

    /// Button background honors theme.button_gradient when set.
    @ViewBuilder
    private func buttonBackground(enabled: Bool) -> some View {
        if enabled, let gradient = theme?.button_gradient {
            StyleEngine.linearGradient(from: gradient)
        } else {
            enabled ? buttonColor : Color.gray.opacity(0.3)
        }
    }

    private var textColor: Color {
        Color(hex: theme?.text_color ?? (colorScheme == .dark ? "#FFFFFF" : "#1a1a1a"))
    }

    private var accentColor: Color {
        Color(hex: theme?.accent_color ?? "#6366f1")
    }

    private var buttonColor: Color {
        Color(hex: theme?.button_color ?? "#6366f1")
    }

    private var buttonTextColor: Color {
        Color(hex: theme?.button_text_color ?? "#FFFFFF")
    }

    /// Resolve font from theme. Honors question_font_size
    /// and font_weight when the (possibly dark-merged) theme supplies them.
    private var themeFont: Font? {
        let fontFamily = theme?.font_family
        let size = theme?.question_font_size
        let weight: Int? = {
            switch theme?.font_weight {
            case "medium": return 500
            case "semibold": return 600
            case "bold": return 700
            case "normal": return 400
            default: return nil
            }
        }()
        if fontFamily == nil && size == nil && weight == nil { return nil }
        return FontResolver.font(family: fontFamily, size: size, weight: weight)
    }

    /// Text alignment honored when theme declares it.
    private var themeTextAlignment: TextAlignment {
        switch theme?.text_align {
        case "left": return .leading
        case "right": return .trailing
        case "center": return .center
        default: return .leading
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // Intro Lottie animation
                if showIntro, let introUrl = theme?.intro_lottie_url {
                    LottieBlockView(block: LottieBlock(
                        lottie_url: introUrl, lottie_json: nil,
                        autoplay: true, loop: false, speed: 1.0,
                        width: nil, height: 120, alignment: "center",
                        play_on_scroll: nil, play_on_tap: nil, color_overrides: nil
                    ))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation { showIntro = false }
                        }
                    }
                }

                // Thank-you screen with Lottie + confetti
                if showThankYou {
                    VStack(spacing: 16) {
                        if let thankUrl = theme?.thankyou_lottie_url {
                            LottieBlockView(block: LottieBlock(
                                lottie_url: thankUrl, lottie_json: nil,
                                autoplay: true, loop: false, speed: 1.0,
                                width: nil, height: 140, alignment: "center",
                                play_on_scroll: nil, play_on_tap: nil, color_overrides: nil
                            ))
                        }
                        // Interpolate thank-you text
                        Text(TemplateEngine.shared.interpolate(
                            theme?.thank_you_text ?? "Thank you!",
                            context: TemplateEngine.shared.buildContext()
                        ))
                            .font(.title2.bold())
                            .foregroundColor(textColor)
                    }
                } else if !showIntro || theme?.intro_lottie_url == nil {
                    // Progress indicator
                    if (config.appearance?.show_progress ?? false) && !visibleQuestions.isEmpty {
                        ProgressView(value: Double(currentQuestionIndex + 1), total: Double(visibleQuestions.count))
                            .tint(accentColor)
                    }

                    Spacer()

                    // Question-level image
                    if currentQuestionIndex < visibleQuestions.count,
                       let imageUrl = visibleQuestions[currentQuestionIndex].image_url {
                        MediaImageView(url: imageUrl, maxHeight: 140, cornerRadius: 8)
                            .padding(.horizontal)
                    }

                    // Current question: apply style engine + theme font
                    // Honor theme.text_align.
                    if currentQuestionIndex < visibleQuestions.count {
                        questionView(for: visibleQuestions[currentQuestionIndex])
                            .applyTextStyle(config.appearance?.question_text_style)
                            .font(themeFont)
                            .foregroundColor(textColor)
                            .multilineTextAlignment(themeTextAlignment)
                    }

                    Spacer()

                    // Navigation buttons
                    HStack {
                        if currentQuestionIndex > 0 {
                            Button("Back") {
                                currentQuestionIndex -= 1
                            }
                            .foregroundColor(accentColor)
                        }

                        Spacer()

                        if currentQuestionIndex < visibleQuestions.count - 1 {
                            Button("Next") {
                                advanceQuestion()
                                // Haptic on step advance
                                HapticEngine.triggerIfEnabled(
                                    theme?.haptic?.triggers?.on_step_advance,
                                    config: theme?.haptic
                                )
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(buttonBackground(enabled: canAdvance))
                            .foregroundColor(buttonTextColor)
                            .cornerRadius(8)
                            .disabled(!canAdvance)
                        } else {
                            Button("Submit") {
                                submitSurvey()
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(buttonBackground(enabled: canAdvance))
                            .foregroundColor(buttonTextColor)
                            .cornerRadius(8)
                            .disabled(!canAdvance)
                        }
                    }

                    // Dismiss button
                    if config.appearance?.dismiss_allowed ?? true {
                        Button("Not now") {
                            let answered = answers.count
                            dismiss()
                            completion(.dismissed(answeredCount: answered))
                        }
                        .foregroundColor(.secondary)
                        .font(.footnote)
                    }
                }
            }
            .padding()
            // Extend the survey background into the BOTTOM safe area (home-indicator
            // strip) so a bottom-sheet survey has no uncolored gap below the content.
            // Only the bottom is extended — the top stays contained so a gradient
            // never bleeds under the status bar (see backgroundView note above).
            .background(backgroundView.ignoresSafeArea(.container, edges: .bottom))
            .applyBlurBackdrop(theme?.blur_backdrop)
            .tint(accentColor)
            .onAppear {
                computeVisibleQuestions()
                // Skip intro if no lottie URL
                if theme?.intro_lottie_url == nil {
                    showIntro = false
                }
            }

            // Confetti overlay on completion
            if showConfetti, let effect = theme?.thankyou_particle_effect {
                ConfettiOverlay(effect: effect)
            }
        }
    }

    // MARK: - Question routing

    @ViewBuilder
    func questionView(for question: SurveyQuestion) -> some View {
        let binding = answerBinding(for: question)
        // Interpolate question text, option text, and NPS labels
        let q = interpolatedQuestion(question)

        switch q.type ?? "" {
        case "nps":
            // Thread the resolved theme colors so the selected score honors accent_color.
            NPSQuestionView(question: q, answer: binding, accentColor: accentColor, buttonTextColor: buttonTextColor, textColor: textColor)
        case "csat":
            CSATQuestionView(question: q, answer: binding)
        case "rating":
            // Thread the resolved accent so filled rating icons honor accent_color.
            RatingQuestionView(question: q, answer: binding, accentColor: accentColor)
        case "single_choice":
            // Gap #19 — pass option_style from appearance to option card views
            // Thread the resolved theme accent/text colors so the selected radio +
            // option label honor SurveyTheme.accent_color / text_color (console parity).
            SingleChoiceView(question: q, answer: binding, optionStyle: config.appearance?.option_style, accentColor: accentColor, textColor: textColor)
        case "multi_choice":
            // Gap #19 — pass option_style from appearance to option card views
            // Thread the resolved theme accent/text colors (console parity).
            MultiChoiceView(question: q, answer: binding, optionStyle: config.appearance?.option_style, accentColor: accentColor, textColor: textColor)
        case "free_text":
            FreeTextView(question: q, answer: binding)
        case "yes_no":
            // Thread the resolved theme colors so the selected button honors accent_color.
            YesNoView(question: q, answer: binding, accentColor: accentColor, buttonTextColor: buttonTextColor, textColor: textColor)
        case "emoji_scale":
            EmojiScaleView(question: q, answer: binding)
        default:
            EmptyView()
        }
    }

    /// Create an interpolated copy of a survey question.
    private func interpolatedQuestion(_ question: SurveyQuestion) -> SurveyQuestion {
        let ctx = TemplateEngine.shared.buildContext()
        let e = TemplateEngine.shared
        return SurveyQuestion(
            id: question.id,
            type: question.type,
            text: e.interpolate(question.text ?? "", context: ctx),
            required: question.required,
            show_if: question.show_if,
            nps_config: question.nps_config.map { nps in
                NPSConfig(
                    low_label: nps.low_label.map { e.interpolate($0, context: ctx) },
                    high_label: nps.high_label.map { e.interpolate($0, context: ctx) }
                )
            },
            csat_config: question.csat_config,
            rating_config: question.rating_config,
            options: question.options?.map { opt in
                SurveyQuestionOption(
                    id: opt.id,
                    text: e.interpolate(opt.text ?? "", context: ctx),
                    icon: opt.icon
                )
            },
            emoji_config: question.emoji_config,
            free_text_config: question.free_text_config,
            image_url: question.image_url
        )
    }

    // MARK: - Logic

    private var canAdvance: Bool {
        guard currentQuestionIndex < visibleQuestions.count else { return false }
        let q = visibleQuestions[currentQuestionIndex]
        if q.required ?? false {
            return answers[q.id ?? ""] != nil
        }
        return true
    }

    private func advanceQuestion() {
        computeVisibleQuestions()
        if currentQuestionIndex < visibleQuestions.count - 1 {
            currentQuestionIndex += 1
        }
    }

    private func submitSurvey() {
        // Haptic on submit
        HapticEngine.triggerIfEnabled(
            theme?.haptic?.triggers?.on_form_submit,
            config: theme?.haptic
        )

        let allAnswers = visibleQuestions.compactMap { answers[$0.id ?? ""] }

        // Show thank-you animation + confetti if configured
        if theme?.thankyou_lottie_url != nil || theme?.thankyou_particle_effect != nil {
            withAnimation { showThankYou = true }
            if theme?.thankyou_particle_effect != nil {
                showConfetti = true
                HapticEngine.triggerIfEnabled(.success, config: theme?.haptic)
            }
            // Dismiss after thank-you animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                dismiss()
                completion(.completed(answers: allAnswers))
            }
        } else {
            dismiss()
            completion(.completed(answers: allAnswers))
        }
    }

    func computeVisibleQuestions() {
        visibleQuestions = (config.questions ?? []).filter { question in
            guard let showIf = question.show_if else { return true }
            // A show_if whose question_id is blank/missing references no real
            // question — a half-configured condition, or a condition left on the
            // first question where nothing precedes it. Treat it as "no condition"
            // and SHOW the question; otherwise the survey silently renders with no
            // visible questions (an empty sheet).
            guard let questionId = showIf.question_id, !questionId.isEmpty else { return true }
            guard let prevAnswer = answers[questionId] else { return false }

            return (showIf.answer_in ?? []).contains(where: { condValue in
                matches(prevAnswer.answer, condValue.value)
            })
        }
    }

    private func matches(_ answer: Any, _ condValue: Any) -> Bool {
        "\(answer)" == "\(condValue)"
    }

    private func answerBinding(for question: SurveyQuestion) -> Binding<SurveyAnswer?> {
        let qId = question.id ?? ""
        return Binding(
            get: { answers[qId] },
            set: { newValue in
                answers[qId] = newValue
                // Track individual question answer
                if let answer = newValue {
                    // Fire the on_option_select haptic like Android (SurveyActivity onAnswer).
                    // iOS never invoked this configurable survey trigger.
                    HapticEngine.triggerIfEnabled(theme?.haptic?.triggers?.on_option_select, config: theme?.haptic)
                    onQuestionAnswered?(config.name ?? "", question, answer)
                }
                // Recompute visible questions when answers change (for conditional show_if)
                computeVisibleQuestions()
            }
        )
    }
}

