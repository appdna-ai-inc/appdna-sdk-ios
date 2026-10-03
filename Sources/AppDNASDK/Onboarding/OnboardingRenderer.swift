import SwiftUI

/// Top-level SwiftUI host that manages onboarding flow state and step navigation.
struct OnboardingFlowHost: View {
    let flow: OnboardingFlowConfig
    weak var delegate: AppDNAOnboardingDelegate?
    let eventTracker: EventTracker?
    let onStepViewed: (_ stepId: String, _ stepIndex: Int) -> Void
    let onStepCompleted: (_ stepId: String, _ stepIndex: Int, _ data: [String: Any]?) -> Void
    let onStepSkipped: (_ stepId: String, _ stepIndex: Int) -> Void
    let onFlowCompleted: (_ responses: [String: Any]) -> Void
    let onFlowDismissed: (_ lastStepId: String, _ lastStepIndex: Int) -> Void

    /// A transient error shown over the flow.
    ///
    /// The auth actions (`email_login`, `login`, `request_otp`, …) need the HOST to perform the side
    /// effect — the SDK cannot sign anyone in. With no delegate registered it stays on the step, and
    /// it used to do so in complete silence: "Continue with email" was a dead button — tap it,
    /// nothing happens, no error, ever. The log line is for the developer; this is for the person
    /// holding the phone.
    @State private var errorToastMessage: String?

    @State private var currentIndex = 0
    @State private var navigationHistory: [Int] = [] // Stack of visited step indices for back navigation
    @State private var responses: [String: Any] = [:]

    // SPEC-083: Hook state
    @State private var isProcessing = false
    /// A step submission whose completion event is waiting on the hook's verdict. See
    /// `PendingStepCompletion` and `applyOutcome`.
    @State private var pendingStepCompletion: PendingStepCompletion?
    @State private var loadingText: String = "Processing..."
    @State private var errorMessage: String?
    @State private var showError = false
    // .stay(message:) success-banner state — distinct from showError so the
    // toast can render in success styling (green/info) instead of error (red).
    @State private var successMessage: String?
    @State private var showSuccess = false
    @State private var configOverrides: [String: StepConfigOverride] = [:]
    /// SPEC-496 §B0 — the host-data pending state machine, and the current step PRESENTATION (one
    /// arrival on a step; back-then-forward is a new one). Bumped wherever `currentIndex` changes, in
    /// the same transaction, so the new step's first frame is already pending.
    @StateObject private var hostDataCoordinator = HostDataPendingCoordinator()
    @State private var presentationSerial = 0
    /// SPEC-496 §5b C3 / C5.5 — the per-step interaction data layer, its stamps, the flow-level
    /// `callSeq`, the current presentation and one `InteractionCoordinator` per presentation. The SAME
    /// instance is handed to the step router (`@ObservedObject`), so a `dataContext`-only reply
    /// re-renders the step and is visible in the reply's own turn.
    @StateObject private var interactionStore = HostDataInteractionStore()

    /// True while the SDK is prefetching images for the NEXT step. During this
    /// time the current step remains visible (instead of showing an empty screen
    /// with unloaded image placeholders).
    @State private var isPreloadingNextStep = false

    /// True on the very first render until the first step's remote images are
    /// in the URL cache. Prevents the "one-frame flash with no background"
    /// effect when the onboarding is first presented.
    @State private var isInitialLoading = true
    // EPIC-2 — dynamic color flash on step-advance (the progress fill briefly animates to flash_color).
    @State private var progressFlashing = false
    // SPEC-419 STEP-2 — the in-flight guard for element interactions now lives in the PER-PRESENTATION
    // `InteractionCoordinator` (SPEC-496 §5b C5.3). The flow-level flag it replaced was held across
    // navigation, so a slow reply from a step the user had left blocked every interaction on the next.

    var body: some View {
        content.overlay(alignment: .bottom) {
            if let message = errorToastMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(12)
                    .padding(.bottom, 100)
                    .transition(.opacity)
            }
        }
    }

    /// Show a transient error. Auto-hides on the same 2.5 s timer the validation pill uses.
    private func showErrorToast(_ message: String) {
        withAnimation { errorToastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { errorToastMessage = nil }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Progress bar (hidden per-step via hide_progress while still counting in total)
            if flow.settings.show_progress && !(currentIndex < flow.steps.count && flow.steps[currentIndex].hide_progress == true) {
                progressBar
            }

            // Navigation bar — only render when back button or dismiss button is visible.
            // Per-step `hide_back` suppresses the back affordance on this step (mirrors hide_progress).
            if (flow.settings.allow_back && !navigationHistory.isEmpty && !currentStepHidesBack) || (flow.settings.dismiss_allowed ?? true) {
                navigationBar
            }

            // Step content — fills remaining space
            if currentIndex < flow.steps.count {
                let step = flow.steps[currentIndex]
                // §B0 "Applies" — the raw-JSON walk runs ONCE per host body, never per router read.
                let applies = hostDataApplies(step)

                ZStack {
                    OnboardingStepRouter(
                        step: step,
                        // SPEC-496 §A4 — the UN-merged step plus its override: the router applies
                        // `StepConfigOverrideMerger` itself, AFTER the raw host-data pass.
                        configOverride: configOverrides[step.id],
                        hostDataPending: hostDataPending(for: step, applies: applies),
                        // §5b C4 — the SAME answer, read live for THIS router's serial (bound now, not
                        // the live one): a reply folded through an older router copy must prune and
                        // gate with the current pending. `applies` is captured, so a read is a
                        // dictionary lookup — no raw-JSON walk per `resolvedStep`.
                        pendingProvider: Self.pendingProvider(
                            coordinator: hostDataCoordinator, serial: presentationSerial, applies: applies,
                            cached: { hostDataCached(step) }
                        ),
                        onNext: { data in
                            handleStepCompleted(step: step, data: data)
                        },
                        onSkip: {
                            handleStepSkipped(step: step)
                        },
                        flowId: flow.id,
                        currentStepIndex: currentIndex,
                        totalSteps: flow.steps.count,
                        savedResponses: responses[step.id] as? [String: Any],
                        // SPEC-401-A parity — the WHOLE response map, so block-level templates,
                        // bindings and visibility conditions can see prior steps' answers. Android
                        // has passed this since R11; iOS passed only `savedResponses` above.
                        accumulatedResponses: responses,
                        delegate: delegate,
                        eventTracker: eventTracker,
                        // SPEC-496 §5b — the router's presentation (its coordinator is looked up by
                        // this serial) and the flow-level interaction store.
                        presentation: presentationSerial,
                        interactionStore: interactionStore
                    )
                    // Chat steps use stable step.id so back-navigation preserves chat transcript;
                    // other steps use currentIndex to force view recreation for transition animations.
                    .id(step.type == .interactive_chat ? AnyHashable(step.id) : AnyHashable(currentIndex))
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))

                    // SPEC-083: Error banner
                    if showError, let msg = errorMessage {
                        VStack {
                            errorBanner(message: msg)
                            Spacer()
                        }
                    }

                    // .stay(message:) success banner — same layout as the error
                    // banner but rendered in success styling.
                    if showSuccess, let msg = successMessage {
                        VStack {
                            successBanner(message: msg)
                            Spacer()
                        }
                    }

                    // SPEC-083: Loading overlay
                    if isProcessing {
                        loadingOverlay
                    }
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    handleStepAppear(step: step)
                }
                // The step content view above is re-created per step via `.id(currentIndex)`, but this
                // container ZStack is NOT — its `.onAppear` fires only once (first step) and again only
                // when a modal (paywall) covers/uncovers the flow. Without this, `onBeforeStepRender`,
                // `onOnboardingStepChanged`, and the `onboarding_step_viewed` event never fire on steps
                // 2..N. `navigate(to:)` only mutates `currentIndex`, so observe it here and re-run the
                // step-appear side effects on every genuine transition (mirrors Android's
                // `LaunchedEffect(currentIndex)` in OnboardingActivity.kt:635).
                .onChange(of: currentIndex) { _ in
                    guard currentIndex < flow.steps.count else { return }
                    handleStepAppear(step: flow.steps[currentIndex])
                }
                // Hide step content on the very first render until the initial
                // image prefetch completes, so users never see an unstyled
                // frame before the background image arrives.
                .opacity(isInitialLoading ? 0 : 1)
            }
        }
        // Step background renders full-screen behind progress bar + nav bar + content
        .background(
            stepFullScreenBackground
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        // Universal tap-to-dismiss keyboard. Taps are bubble-up in SwiftUI:
        // buttons, text fields, and list rows consume their own taps, so this
        // root-level handler only fires for taps on empty areas (progress bar
        // gutter, space between blocks, pinned CTA gutter, nav bar empty
        // space). Prevents users from getting stuck with a keyboard open
        // after tapping somewhere that wasn't another input.
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        .task {
            guard isInitialLoading else { return }
            if currentIndex < flow.steps.count {
                let urls = collectImageURLs(from: flow.steps[currentIndex])
                if !urls.isEmpty {
                    await ImagePreloader.prefetch(urls: urls, timeout: 3.0)
                }
            }
            isInitialLoading = false
        }
    }

    // MARK: - Full-screen step background

    @ViewBuilder
    private var stepFullScreenBackground: some View {
        if currentIndex < flow.steps.count {
            let step = flow.steps[currentIndex]
            let cfg = applyOverrides(to: step.config, stepId: step.id)
            if let bg = cfg.background {
                // Step-level background (image, gradient, color)
                StyleEngine.backgroundView(bg)
            } else if let chatBg = cfg.chat_config?.style?.background_color {
                // Chat steps store background in chat style config
                Color(hex: chatBg)
            } else if step.type == .interactive_chat {
                // Chat step fallback default (dark)
                Color(hex: "#0F172A")
            } else {
                Color(.systemBackground)
            }
        } else {
            Color(.systemBackground)
        }
    }

    // MARK: - Progress bar

    @ViewBuilder
    private var progressBar: some View {
        let trackColor: Color = {
            if let hex = flow.settings.progress_track_color { return Color(hex: hex) }
            return Color.gray.opacity(0.2)
        }()
        // Per-step progress color override: step.config.progress_color > element_style.background.color > flow.settings.progress_color
        let normalFill: Color = {
            if currentIndex < flow.steps.count {
                let step = flow.steps[currentIndex]
                if let stepColor = step.config.progress_color, !stepColor.isEmpty {
                    return Color(hex: stepColor)
                }
                if let stepColor = step.config.element_style?.background?.color {
                    return Color(hex: stepColor)
                }
            }
            if let hex = flow.settings.progress_color { return Color(hex: hex) }
            return Color(hex: (AppDNA.brandAccentHex ?? "#6366F1"))
        }()
        // EPIC-2 — flash overrides the fill while progressFlashing (animated via .animation below).
        let flashCol = flow.settings.progress_flash_color.map { Color(hex: $0) }
        let fillColor: Color = (progressFlashing && flashCol != nil) ? flashCol! : normalFill
        let style = flow.settings.progress_style ?? "continuous_bar"
        let total = flow.steps.count
        let current = currentIndex
        // EPIC-2 — thin sizing (custom height) + multiple colors at once (gradient), flow-level progress.
        let barHeight = CGFloat(flow.settings.progress_height ?? 4)
        let gradCols = (flow.settings.progress_gradient_colors ?? []).map { Color(hex: $0) }
        let progressSkipLabel = flow.settings.progress_skip_label

        // EPIC-2 — optional "Skip" link beside the progress: Group(progress).frame(maxWidth:.infinity) | Skip.
        HStack(spacing: 0) {
            Group {
            switch style {
        case "dots":
            HStack(spacing: 8) {
                ForEach(0..<total, id: \.self) { i in
                    Circle()
                        .fill(i <= current ? fillColor : trackColor)
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
            .frame(height: 12)
            .padding(.horizontal)

        case "segmented_bar":
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i <= current ? fillColor : trackColor)
                        .frame(height: barHeight)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
            .frame(height: barHeight)
            .padding(.horizontal)

        case "fraction":
            Text("\(current + 1)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundColor(fillColor)
                .frame(height: 16)

        case "none":
            EmptyView()

        default: // continuous_bar
            // EPIC-2 — height-honoring custom bar (progress_height) + optional multi-color gradient
            // (progress_gradient_colors). Mirrors Android ContinuousProgressBar; snapshot-tested.
            ContinuousProgressBar(
                progress: progress,
                color: fillColor,
                trackColor: trackColor,
                height: barHeight,
                gradientColors: gradCols.count >= 2 ? gradCols : nil
            )
            .animation(.easeInOut(duration: 0.3), value: currentIndex)
            .padding(.horizontal)
        }
            }
            .frame(maxWidth: .infinity)
            if let skip = progressSkipLabel {
                Button { advanceOrComplete() } label: {
                    Text(skip)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(fillColor)
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
            }
        }
        .onChange(of: currentIndex) { _ in
            guard flow.settings.progress_flash_color != nil else { return }
            progressFlashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { progressFlashing = false }
        }
        .animation(.easeInOut(duration: 0.35), value: progressFlashing)
    }

    private var progress: CGFloat {
        guard flow.steps.count > 0 else { return 0 }
        return CGFloat(currentIndex + 1) / CGFloat(flow.steps.count)
    }

    // MARK: - Navigation bar

    private var navigationBar: some View {
        let backStyle = flow.settings.back_button_style
        let backSize = backStyle?.icon_size ?? 16
        let backColor: Color = backStyle?.icon_color.flatMap { Color(hex: $0) } ?? Color(hex: "#6B7280")
        let hasBack = flow.settings.allow_back && !navigationHistory.isEmpty && !currentStepHidesBack
        let dismissAllowed = flow.settings.dismiss_allowed ?? true
        // EPIC-2 — back⇄X switch: show the dismiss in the leading slot on the first/no-history step.
        let leadingIsClose = !hasBack && dismissAllowed && (backStyle?.close_on_first == true)

        return HStack {
            let _ = Log.debug("[Onboarding] Nav bar: allow_back=\(flow.settings.allow_back), currentIndex=\(currentIndex), isProcessing=\(isProcessing)")
            if hasBack {
                Button {
                    let previousIndex = navigationHistory.last ?? max(currentIndex - 1, 0)
                    Log.debug("[Onboarding] Back button tapped, going from \(currentIndex) to \(previousIndex)")
                    // 🔴 DISCARD A COMPLETION WAITING ON A HOOK. Tapping Log-in arms
                    // `pendingStepCompletion` and starts the hook (with a 300 ms grace before the spinner
                    // shows, during which Back is still tappable). Going back means the user did NOT
                    // complete this step — but the pending would otherwise be fired by the NEXT
                    // `applyOutcome`, recording a completion for the step they just abandoned. Clear it.
                    pendingStepCompletion = nil
                    HapticEngine.triggerIfEnabled(flow.settings.haptic?.triggers?.on_step_advance, config: flow.settings.haptic)
                    navigationHistory.removeLast()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        let nextSerial = OnboardingPresentation.serial(presentationSerial, from: currentIndex, to: previousIndex)
                        presentationSerial = nextSerial
                        // §5b C5.5 — the store's current presentation moves in the SAME transaction.
                        interactionStore.setCurrentPresentation(nextSerial)
                        currentIndex = previousIndex
                    }
                } label: {
                    Group {
                        // EPIC-2 — custom back glyph (any char) when set, else the SF chevron.
                        if let glyph = backStyle?.icon, !glyph.isEmpty {
                            NavGlyph(glyph: glyph, color: backColor, size: backSize)
                        } else {
                            Image(systemName: "chevron.left")
                                .font(.system(size: backSize, weight: .semibold))
                                .foregroundColor(backColor)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(isProcessing)
            } else if leadingIsClose {
                // EPIC-2 — back⇄X switch: dismiss in the leading slot on the first step.
                Button {
                    let step = flow.steps[currentIndex]
                    // Same race as Back/Skip: dismissing during the 300 ms hook grace-window must
                    // discard a completion waiting on that hook, or the next `applyOutcome` records
                    // a phantom completion for the step the user dismissed away from.
                    pendingStepCompletion = nil
                    HapticEngine.triggerIfEnabled(flow.settings.haptic?.triggers?.on_button_tap, config: flow.settings.haptic)
                    // §5b C5.5 — no late interaction reply may act on a dismissed flow.
                    interactionStore.setCurrentPresentation(-1)
                    onFlowDismissed(step.id, currentIndex)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: backSize, weight: .semibold))
                        .foregroundColor(backColor)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isProcessing)
            } else {
                Spacer().frame(width: 44)
            }

            Spacer()

            // Dismiss button
            if dismissAllowed && !leadingIsClose {
                Button {
                    let step = flow.steps[currentIndex]
                    // See leading-close above: clear a hook-pending completion before dismissing.
                    pendingStepCompletion = nil
                    HapticEngine.triggerIfEnabled(flow.settings.haptic?.triggers?.on_button_tap, config: flow.settings.haptic)
                    // §5b C5.5 — no late interaction reply may act on a dismissed flow.
                    interactionStore.setCurrentPresentation(-1)
                    onFlowDismissed(step.id, currentIndex)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
                .disabled(isProcessing)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - SPEC-083: Loading overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                Text(loadingText)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(Color.black.opacity(0.7))
            .cornerRadius(16)
        }
    }

    // MARK: - SPEC-083: Error banner

    private func errorBanner(message: String) -> some View {
        HStack {
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)

            Spacer()

            Button {
                withAnimation { showError = false; errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red)
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation { showError = false; errorMessage = nil }
            }
        }
    }

    // MARK: - .stay(message:) success banner

    /// Non-error banner used by `StepAdvanceResult.stay(message:)`. Same layout
    /// shape as `errorBanner` but rendered in success styling (green) so users
    /// don't read it as a failure. Auto-dismisses after 4 seconds (slightly
    /// shorter than error since success messages are less critical to read).
    private func successBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(.white)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)

            Spacer()

            Button {
                withAnimation { showSuccess = false; successMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.18, green: 0.62, blue: 0.32)) // #2E9E51 success green
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { showSuccess = false; successMessage = nil }
            }
        }
    }

    // MARK: - Config overrides (SPEC-083)

    private func applyOverrides(to config: StepConfig, stepId: String) -> StepConfig {
        StepConfigOverrideMerger.apply(configOverrides[stepId], to: config)
    }

    // MARK: - Element interaction (SPEC-419 STEP-2 / SPEC-496 §5b)

    // The round trip used to live here, as `performInteraction`, guarded by a FLOW-level
    // `interactionInFlight` with no timeout, and it told the host `flow.steps[currentIndex].id` — which
    // during the exit transition is the INCOMING step. It now lives in the step router, through that
    // presentation's `InteractionCoordinator` (the coordinator's own step id, a presentation-scoped
    // lock, generation tokens and the 8 s refresh deadline).

    // MARK: - Step lifecycle

    /// True when the current step's `hide_back` flag (authored in the step's `layout`) is set.
    /// Mirrors the per-step `hide_progress` treatment in `content`.
    private var currentStepHidesBack: Bool {
        currentIndex < flow.steps.count && flow.steps[currentIndex].hide_back == true
    }

    /// SPEC-448 §B — how long the host gets before the step renders without its override.
    ///
    /// Deliberately shorter than the server-hook default of 10s: a hook is a background call, this
    /// one is between the user and a visible screen.
    private static let overrideTimeout: TimeInterval = 3.0

    /// SPEC-496 §B0 — is the CURRENT presentation of `step` waiting on host data? True from the first
    /// frame (before the call starts in `onAppear`) when a delegate is set, the step's raw blocks
    /// reference `hook_data`, and no override for it is cached yet.
    private func hostDataPending(for step: OnboardingStep, applies: Bool) -> Bool {
        hostDataCoordinator.isPending(
            presentation: presentationSerial,
            applies: applies,
            cached: hostDataCached(step)
        )
    }

    /// §B0 "Applies" — a delegate is set and the step's raw blocks reference `hook_data`.
    private func hostDataApplies(_ step: OnboardingStep) -> Bool {
        delegate != nil && OnboardingStepPipeline.referencesHookData(step)
    }

    /// SPEC-496 §5b C3 — cached = a base, OR a layer VALUE under a key the step references (a page
    /// loaded with "Show more" is there on a revisit's first frame). The coordinator samples this ONCE
    /// per presentation and latches it.
    private func hostDataCached(_ step: OnboardingStep) -> Bool {
        interactionStore.isCached(step, hasBase: configOverrides[step.id] != nil)
    }

    /// SPEC-496 §5b C4 — the router's live pending read. `serial` and `applies` are bound at
    /// construction: the router's OWN presentation, never the flow host's live one. `cached` is only
    /// evaluated for a serial with no latch yet.
    /// Capturing `applies` is intentional: if the weak delegate deallocates mid-presentation, an older
    /// router copy stays pending until the reply or the deadline ends it, exactly as §B0 defines.
    static func pendingProvider(coordinator: HostDataPendingCoordinator, serial: Int, applies: Bool,
                                cached: @escaping () -> Bool = { false }) -> () -> Bool {
        { coordinator.isPending(presentation: serial, applies: applies, cached: cached()) }
    }

    private func handleStepAppear(step: OnboardingStep) {
        // 🔴 BOUNDED. This `await` used to have no timeout at all, which was mostly harmless
        // while few hosts did real work in this hook — SPEC-448 §B asks every host to FETCH
        // DATA here, so a customer awaiting their own backend on a bad connection, with no
        // timeout of their own, would hang the step indefinitely and it would look like our bug.
        // The SDK's own server hooks have always bounded themselves; this one now matches.
        //
        // SPEC-496 §B0 — the deadline is a timer INDEPENDENT of the host call (a host that never
        // resumes and ignores cancellation still ends pending at 3 s), only the latest call of this
        // presentation may end pending, and the end of pending is a re-resolve even when the host
        // returned nil (the coordinator publishes the change).
        let flowId = flow.id
        let stepIndex = currentIndex
        let stepType = step.type.rawValue
        let responsesSnapshot = responses
        let host = delegate
        let store = interactionStore
        hostDataCoordinator.start(
            presentation: presentationSerial,
            timeout: Self.overrideTimeout,
            // SPEC-496 §5b C3 — every call (and every re-fire) draws the flow-level `callSeq` at START.
            seq: { store.nextCallSeq() },
            call: {
                await host?.onBeforeStepRender(
                    flowId: flowId,
                    stepId: step.id,
                    stepIndex: stepIndex,
                    stepType: stepType,
                    responses: responsesSnapshot
                )
            },
            // §B0 — fires once for every call that finished, EVEN IF the user already left the step
            // (a superseded generation). Riding on `onFinish` (latest generation only) dropped
            // `onboarding_step_viewed` / `onOnboardingStepChanged` for every step left before the
            // delegate replied, host data or not. The index is the one the step was viewed at.
            onSettled: {
                onStepViewed(step.id, stepIndex)
            },
            onFinish: { override, seq in
                // Latest generation only. A reply is applied only if the user is STILL on this step.
                // Dropping it into a step they have left would rewrite a screen they are no longer
                // looking at.
                if let override, currentIndex < flow.steps.count, flow.steps[currentIndex].id == step.id {
                    configOverrides[step.id] = override
                    // §5b C3 — the base's stamp is its call's `callSeq`; interaction entries for the
                    // keys it sets that started earlier are deleted. Same turn as the write above.
                    store.recordBase(stepId: step.id, override: override, stamp: seq)
                }
            }
        )
    }

    private func handleStepCompleted(step: OnboardingStep, data: [String: Any]?) {
        // Auth-style actions require a delegate to perform the side effect
        // (sign in, register, send OTP, etc.) before the user advances past
        // the credential-collection step. Without a delegate the SDK has
        // nowhere to route the credentials, so it stays on the step and
        // logs a warning rather than silently advancing.
        let actionString = (data?["action"] as? String) ?? ""
        let requiresDelegate = AuthActionPolicy.delegateRequiredActions.contains(actionString)
        let hasServerHook = (step.hook?.enabled == true)

        // 🔴 THE BLOCKED PATH RUNS FIRST, AND RUNS NOTHING ELSE.
        //
        // This gate used to sit at the BOTTOM of the method, so a credential tap with no delegate
        // still (1) wrote the credentials into `responses`, (2) PERSISTED them to SessionDataStore,
        // and (3) fired `onStepCompleted` — whose closure emits `onboarding_step_completed`
        // (OnboardingFlowManager.swift:86). The step did not complete: it refused to advance. So
        // iOS's step-completion counts and onboarding funnel conversion were inflated by every
        // misconfigured auth tap, and the credentials the gate exists to contain were written to
        // disk anyway. Nothing is emitted or stored now — the user sees the toast, and that is all.
        if requiresDelegate && delegate == nil && !hasServerHook {
            Log.warning("[Onboarding] '\(actionString)' action received but no delegate is set. Implement AppDNAOnboardingDelegate to handle the action.")
            showErrorToast("Sign-in isn't available right now. Please try again later.")
            return
        }

        // 🔴 THE USER'S PASSWORD WAS BEING UPLOADED TO THE ANALYTICS BACKEND.
        //
        // Two sinks took the raw `data` map — which, on a `login` / `register` / `change_password`
        // step, is the field map the user just typed, PASSWORD INCLUDED:
        //
        //   1. `responses` → `SessionDataStore` (UserDefaults, plaintext, on disk, every attempt).
        //      And `TemplateEngine.buildContext()` folds that bucket into the `{{…}}` namespace — the
        //      same path that once rendered one user's name into another user's paywall copy. The
        //      password was one `{{onboarding.password}}` away from being DISPLAYED.
        //
        //   2. `onStepCompleted` → `onboarding_step_completed`, whose properties carry
        //      `"selection_data": data` verbatim (OnboardingFlowManager.swift:90). That event is
        //      enqueued, uploaded, and lands in `raw.sdk_events` — so every login attempt shipped the
        //      end-user's plaintext password into the warehouse, and kept it.
        //
        // Both sinks now get the REDACTED map. The host still receives the credentials in full:
        // `executeClientHook` hands the delegate the raw `data` as `stepData` below, which is how it
        // actually signs the user in. Nobody else needs them, so nobody else gets them.
        let safeData = AuthSecretRedactor.redact(data, in: step)
        if let safeData {
            responses[step.id] = safeData
            // A flag CTA's key is ALSO collected flat under `responses["flags"]`, so a host routing
            // after `onOnboardingCompleted` reads one bucket instead of walking every step of the
            // flow looking for it. The step's own copy above is untouched — `next_step_rules` and
            // `{{responses.*}}` still find the flag exactly where they find every other answer.
            //
            // Which keys count as flags comes from the step's own CTA CONFIG, not from the data map.
            // Reading the map would let a form field named `flags` — or a field whose id happened to
            // match a flag key — write into the bucket the host makes routing decisions on. Same
            // structural discipline as `AuthSecretRedactor` one block up, and for the same reason.
            responses = OnboardingCTAFlag.applyTo(responses: responses, step: step, stepData: safeData)
        }
        // SPEC-087: Persist responses incrementally so TemplateEngine has fresh data for next step.
        // The persist stays here even for a hook step: the hook is HANDED `responses`, and if it blocks
        // we stay on the step and the user's typed values must survive the re-render.
        SessionDataStore.shared.setOnboardingResponses(responses)

        // SPEC-083: Determine hook type — client delegate takes priority over server hook
        if delegate != nil {
            // 🔴 `onboarding_step_completed` USED TO FIRE HERE — BEFORE THE HOOK HAD DECIDED ANYTHING.
            //
            // On a hook step the hook is what decides whether the step completes. A `login` step whose
            // delegate answers `.block("Wrong password")` does NOT complete: the user stays exactly
            // where they were. But the event had already gone out. Mistype your password three times
            // and the funnel records FOUR completions of a step you never completed — and the next
            // one, on success, makes five.
            //
            // The metric this corrupts is the one the product is sold on: onboarding step-completion
            // and funnel conversion. It over-counts worst precisely where the funnel matters most —
            // the credential step, the step users actually fail at — so the flows that convert badly
            // are the ones that look healthiest.
            //
            // The emit now happens in `applyOutcome`, the single place where the pure machine's
            // decision becomes navigation, and only when the flow ACTUALLY LEAVES the step. Same for
            // the server-hook path below; both converge on `handleHookResult`.
            pendingStepCompletion = PendingStepCompletion(stepId: step.id, index: currentIndex, data: safeData)
            executeClientHook(step: step, data: data)
        } else if let hook = step.hook, hook.enabled == true {
            pendingStepCompletion = PendingStepCompletion(stepId: step.id, index: currentIndex, data: safeData)
            executeServerHook(step: step, data: data, hookConfig: hook)
        } else {
            // No hook — nothing can veto, so the step completes the moment it is submitted. (The
            // auth-action-without-delegate case cannot reach here: it returned at the top, before
            // anything was emitted or stored.)
            onStepCompleted(step.id, currentIndex, safeData)
            advanceOrComplete()
        }
    }

    /// A step submission whose completion event is waiting on the hook's verdict.
    ///
    /// Nil unless a hook is in flight. `applyOutcome` fires it if — and only if — the outcome actually
    /// navigates away from the step, and clears it otherwise so a blocked attempt cannot leak into the
    /// next one. `@State` because a `View` is a value type: a plain stored property cannot be mutated
    /// from the view's own methods.
    struct PendingStepCompletion {
        let stepId: String
        let index: Int
        let data: [String: Any]?
    }

    // MARK: - Client-side hook execution

    private func executeClientHook(step: OnboardingStep, data: [String: Any]?) {
        loadingText = step.hook?.loading_text ?? "Processing..."

        let startTime = Date()
        trackHookEvent("onboarding_hook_started", step: step, extra: ["hook_type": "client"])

        // Only show loading after a delay — avoids flash for instant responses
        let showLoadingTimer = DispatchWorkItem { [self] in
            isProcessing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: showLoadingTimer)

        Task {
            let result = await delegate?.onBeforeStepAdvance(
                flowId: flow.id,
                fromStepId: step.id,
                stepIndex: currentIndex,
                stepType: step.type.rawValue,
                responses: responses,
                stepData: data
            ) ?? .proceed

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            await MainActor.run {
                showLoadingTimer.cancel()
                isProcessing = false
                trackHookEvent("onboarding_hook_completed", step: step, extra: [
                    "hook_type": "client",
                    "result": resultName(result),
                    "duration_ms": durationMs,
                ])
                handleHookResult(result, step: step)
            }
        }
    }

    // MARK: - Server-side hook execution (P1)

    private func executeServerHook(step: OnboardingStep, data: [String: Any]?, hookConfig: StepHookConfig) {
        loadingText = hookConfig.loading_text ?? "Processing..."
        isProcessing = true

        trackHookEvent("onboarding_hook_started", step: step, extra: [
            "hook_type": "server",
            "webhook_url": hookConfig.webhook_url,
        ])

        let startTime = Date()

        Task {
            let result = await executeWebhook(
                step: step,
                data: data,
                hookConfig: hookConfig,
                attempt: 0
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            await MainActor.run {
                isProcessing = false
                trackHookEvent("onboarding_hook_completed", step: step, extra: [
                    "hook_type": "server",
                    "result": resultName(result),
                    "duration_ms": durationMs,
                ])
                handleHookResult(result, step: step)
            }
        }
    }

    private func executeWebhook(
        step: OnboardingStep,
        data: [String: Any]?,
        hookConfig: StepHookConfig,
        attempt: Int
    ) async -> StepAdvanceResult {
        guard let webhookUrl = hookConfig.webhook_url, let url = URL(string: webhookUrl) else {
            return .block(message: hookConfig.error_text ?? "Invalid webhook URL.")
        }

        // Build request body
        let body: [String: Any] = [
            "flow_id": flow.id,
            "step_id": step.id,
            "step_index": currentIndex,
            "step_type": step.type.rawValue,
            "step_data": data ?? [:],
            "responses": responses,
            "user_id": AppDNA.currentUserId ?? "",
            "app_id": AppDNA.currentAppId ?? "",
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(hookConfig.timeout_ms ?? 10000) / 1000.0

        // Apply custom headers with variable interpolation
        if let headers = hookConfig.headers {
            for (key, value) in headers {
                let resolved = interpolateVariables(value)
                request.setValue(resolved, forHTTPHeaderField: key)
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = TimeInterval(hookConfig.timeout_ms ?? 10000) / 1000.0
            let session = URLSession(configuration: config)

            let (responseData, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw APIError.httpError(
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    data: nil
                )
            }

            return parseWebhookResponse(responseData, hookConfig: hookConfig)

        } catch let error as URLError where error.code == .timedOut {
            // Timeout — retry or block
            let maxRetries = min(hookConfig.retry_count ?? 0, 3)
            if attempt < maxRetries {
                trackHookEvent("onboarding_hook_retry", step: step, extra: [
                    "attempt_number": attempt + 1,
                ])
                let delay = pow(2.0, Double(attempt)) // 1s, 2s, 4s
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return await executeWebhook(step: step, data: data, hookConfig: hookConfig, attempt: attempt + 1)
            }
            trackHookEvent("onboarding_hook_error", step: step, extra: [
                "hook_type": "server",
                "error_type": "timeout",
                "error_message": "Request timed out",
            ])
            return .block(message: hookConfig.error_text ?? "Request timed out. Please try again.")

        } catch {
            // Network error — retry or block
            let maxRetries = min(hookConfig.retry_count ?? 0, 3)
            if attempt < maxRetries {
                trackHookEvent("onboarding_hook_retry", step: step, extra: [
                    "attempt_number": attempt + 1,
                ])
                let delay = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return await executeWebhook(step: step, data: data, hookConfig: hookConfig, attempt: attempt + 1)
            }
            trackHookEvent("onboarding_hook_error", step: step, extra: [
                "hook_type": "server",
                "error_type": "network",
                "error_message": error.localizedDescription,
            ])
            return .block(message: hookConfig.error_text ?? "Network error. Please check your connection.")
        }
    }

    private func parseWebhookResponse(_ data: Data, hookConfig: StepHookConfig) -> StepAdvanceResult {
        WebhookResponseParser.parse(data, errorText: hookConfig.error_text)
    }

    // MARK: - Variable interpolation (SPEC-083 §6.5, SPEC-088: delegates to shared TemplateEngine)

    private func interpolateVariables(_ value: String) -> String {
        let ctx = TemplateEngine.shared.buildContext()
        return TemplateEngine.shared.interpolate(value, context: ctx)
    }

    // MARK: - Hook result handling

    /// Folds a hook result through the pure `OnboardingAdvance` state machine and executes the
    /// resulting outcome. The decision logic itself is no longer in the view — see
    /// `Onboarding/OnboardingAdvance.swift` (mirrors Android `OnboardingAdvance.kt`).
    private func handleHookResult(_ result: StepAdvanceResult, step: OnboardingStep) {
        applyOutcome(OnboardingAdvance.apply(
            result: result,
            flow: flow,
            currentIndex: currentIndex,
            responses: responses,
            configOverrides: configOverrides,
            previousStepId: previousStepId
        ))
    }

    /// Execute an `OnboardingAdvance.Outcome`: the ONLY place the pure machine's decisions become
    /// side effects (state write-back, SessionDataStore, analytics, banner, navigation).
    private func applyOutcome(_ outcome: OnboardingAdvance.Outcome) {
        // 🔴 THE STEP COMPLETES WHEN THE FLOW LEAVES IT — NOT WHEN THE USER TAPS THE BUTTON.
        //
        // A hook step's completion is the hook's to decide. `.stay` means the hook said no (a wrong
        // password, a failed sign-in, a validation error), the user is still looking at the same step,
        // and nothing completed. Emitting here — and only on a navigating outcome — is what makes
        // `onboarding_step_completed` mean what its name says.
        //
        // The pending value is cleared either way: a blocked attempt must not leak into the next one,
        // and a user who fixes their password and succeeds emits exactly ONE completion.
        if let pending = pendingStepCompletion {
            pendingStepCompletion = nil
            if outcome.navigation.completesStep {
                onStepCompleted(pending.stepId, pending.index, pending.data)
            }
        }

        if outcome.responsesChanged {
            responses = outcome.responses
        }
        // SPEC-088: Persist computed data for cross-module access.
        if let computed = outcome.computedData {
            SessionDataStore.shared.mergeComputedData(computed)
        }
        for event in outcome.events {
            eventTracker?.track(event: event.name, properties: event.props)
        }
        if let banner = outcome.banner {
            switch banner {
            case .error(let message):
                errorMessage = message
                withAnimation { showError = true }
            case .success(let message):
                successMessage = message
                withAnimation { showSuccess = true }
            }
        }
        switch outcome.navigation {
        case .stay:
            break
        case .goToIndex(let index):
            navigate(to: index)
        case .completeFlow(let finalResponses):
            interactionStore.setCurrentPresentation(-1)
            onFlowCompleted(finalResponses)
        case .presentPaywallTrigger(let nodeId):
            presentPaywallTrigger(nodeId)
        }
    }

    // MARK: - Hook event tracking

    private func trackHookEvent(_ event: String, step: OnboardingStep, extra: [String: Any] = [:]) {
        var props: [String: Any] = [
            "flow_id": flow.id,
            "step_id": step.id,
        ]
        props.merge(extra) { _, new in new }
        eventTracker?.track(event: event, properties: props)
    }

    private func resultName(_ result: StepAdvanceResult) -> String {
        StepAdvanceResultNaming.name(result)
    }

    // MARK: - Navigation helpers

    private func handleStepSkipped(step: OnboardingStep) {
        // Skipping is not completing: discard any completion waiting on an in-flight hook, or the
        // `advanceOrComplete()` below would fire it and record this step as completed AND skipped.
        pendingStepCompletion = nil
        onStepSkipped(step.id, currentIndex)
        advanceOrComplete()
    }

    /// Evaluate next-step rules and route. All decision logic lives in the pure
    /// `OnboardingAdvance` state machine; this is the execute half.
    private func advanceOrComplete() {
        // Console-configured step-advance haptic (mirrors Android's on_step_advance). iOS onboarding
        // fired no haptics at all before `settings.haptic` was wired.
        HapticEngine.triggerIfEnabled(flow.settings.haptic?.triggers?.on_step_advance, config: flow.settings.haptic)
        applyOutcome(OnboardingAdvance.advance(
            flow: flow,
            currentIndex: currentIndex,
            responses: responses,
            configOverrides: configOverrides,
            previousStepId: previousStepId
        ))
    }

    // MARK: - Navigation with image preload

    /// Advance to the given step index, prefetching any remote images referenced
    /// in the target step's content blocks BEFORE updating currentIndex. This
    /// prevents the new screen from flashing with empty image placeholders while
    /// the network downloads the assets.
    private func navigate(to targetIndex: Int, appendHistory: Bool = true) {
        guard targetIndex >= 0 && targetIndex < flow.steps.count else { return }
        let targetStep = flow.steps[targetIndex]
        let urls = collectImageURLs(from: targetStep)

        let performNavigation: () -> Void = {
            if appendHistory { navigationHistory.append(currentIndex) }
            withAnimation {
                // A self-route (target == current) is NOT a new presentation: `.onChange(of:
                // currentIndex)` would not fire, `handleStepAppear` would never start the new
                // presentation's call, and the step would sit on "Loading…" forever.
                let nextSerial = OnboardingPresentation.serial(presentationSerial, from: currentIndex, to: targetIndex)
                presentationSerial = nextSerial
                // §5b C5.5 — the store's current presentation moves in the SAME transaction.
                interactionStore.setCurrentPresentation(nextSerial)
                currentIndex = targetIndex
            }
        }

        if urls.isEmpty {
            performNavigation()
            return
        }

        isPreloadingNextStep = true
        ImagePreloader.prefetch(urls: urls, timeout: 3.0) {
            isPreloadingNextStep = false
            performNavigation()
        }
    }

    /// Walk a step's content to collect every remote image URL that will be
    /// rendered when the step displays. Static so the flow manager can call
    /// it to kick off prefetching before the host view is even created.
    static func collectImageURLs(from step: OnboardingStep) -> [URL] {
        var urls: [URL] = []

        // Step-level image (welcome/value_prop/custom layouts)
        if let s = step.config.image_url, let u = URL(string: s) {
            urls.append(u)
        }

        // Step background image
        if let bg = step.config.background?.image_url, let u = URL(string: bg) {
            urls.append(u)
        }

        // Recurse content blocks
        if let blocks = step.config.content_blocks {
            for block in blocks {
                urls.append(contentsOf: collectImageURLs(from: block))
            }
        }

        return urls
    }

    private func collectImageURLs(from step: OnboardingStep) -> [URL] {
        Self.collectImageURLs(from: step)
    }

    /// Recursive helper to walk nested content blocks (stack/row containers) and
    /// collect their image URLs.
    static func collectImageURLs(from block: ContentBlock) -> [URL] {
        var urls: [URL] = []
        if let s = block.image_url, let u = URL(string: s) {
            urls.append(u)
        }
        if let s = block.placeholder_image_url, let u = URL(string: s) {
            urls.append(u)
        }
        if let options = block.field_options {
            for opt in options {
                if let s = opt.image_url, let u = URL(string: s) {
                    urls.append(u)
                }
            }
        }
        // Container children (stack / row / card)
        let kids = (block.children ?? []) + (block.stack_children ?? [])
        for child in kids {
            urls.append(contentsOf: collectImageURLs(from: child))
        }
        return urls
    }

    // MARK: - Condition evaluation inputs

    /// The step ID the user navigated FROM to reach the current step, or nil
    /// if there is no previous step (i.e. this is the first step).
    private var previousStepId: String? {
        guard let lastIdx = navigationHistory.last,
              lastIdx >= 0, lastIdx < flow.steps.count else { return nil }
        return flow.steps[lastIdx].id
    }

    /// Look up a graph node's `type` from `graph_nodes` (the lightweight
    /// extract synced for runtime). Lets the renderer route by type
    /// instead of by ID prefix — necessary because the editor switched
    /// from `paywall_trigger_<timestamp>` IDs to short `paywall<N>` IDs
    /// and the prefix check would silently fall through. Returns nil
    /// when the ID is unknown (legacy flows or actual step IDs).
    private func graphNodeType(for nodeId: String) -> String? {
        return OnboardingAdvance.graphNodeType(for: nodeId, flow: flow)
    }

    /// Resolve paywall ID from a paywall_trigger graph node.
    private func resolvePaywallFromTrigger(_ triggerNodeId: String) -> String? {
        return resolvePaywallTriggerData(triggerNodeId)?["paywall_id"] as? String
            ?? resolvePaywallTriggerData(triggerNodeId)?["paywallId"] as? String
    }

    /// Returns the data dict for a paywall_trigger node.
    /// Checks graph_nodes first (lightweight, always synced), then falls back to graph_layout.
    private func resolvePaywallTriggerData(_ triggerNodeId: String) -> [String: Any]? {
        // Prefer graph_nodes (lightweight dict keyed by node ID)
        if let graphNodes = flow.graph_nodes?.value as? [String: Any],
           let node = graphNodes[triggerNodeId] as? [String: Any] {
            return node
        }
        // Fallback to full graph_layout for backward compatibility
        if let graphLayout = flow.graph_layout?.value as? [String: Any],
           let nodes = graphLayout["nodes"] as? [[String: Any]],
           let node = nodes.first(where: { ($0["id"] as? String) == triggerNodeId }) {
            return node["data"] as? [String: Any]
        }
        return nil
    }

    /// Route to any target — step id, paywall_trigger node, end node, or
    /// analytics_event. Resolves graph nodes by `type` (looked up in the
    /// `graph_nodes` lightweight extract) AND by legacy ID prefix, so
    /// both modern (`paywall1`, `end1`) and legacy
    /// (`paywall_trigger_<timestamp>`, `end_<timestamp>`) IDs route
    /// correctly. Centralizes what used to be duplicated across
    /// advanceOrComplete and post-paywall outcome closures. Previously
    /// `skipToStep` (called from an outcome like on_dismiss_target)
    /// couldn't present a paywall, so dismiss → winback chains silently
    /// fell through to `advanceOrComplete` on the step underneath,
    /// looping the user back to paywall #1.
    private func navigateToTarget(_ target: String) {
        let nodeType = graphNodeType(for: target)

        if target.hasPrefix("end_") || nodeType == "end" {
            interactionStore.setCurrentPresentation(-1)
            onFlowCompleted(responses)
            return
        }
        if target.hasPrefix("paywall_trigger_") || nodeType == "paywall_trigger" {
            presentPaywallTrigger(target)
            return
        }
        if let targetIndex = flow.steps.firstIndex(where: { $0.id == target }) {
            navigate(to: targetIndex)
            return
        }
        // Unknown target: fall back to the step-level advance logic so
        // we at least follow next_step_rules instead of silently stalling.
        advanceOrComplete()
    }

    /// Present a paywall_trigger node with full per-outcome routing
    /// (on_success_target / on_fail_target / on_dismiss_target). Safe to
    /// call both from `advanceOrComplete`'s rule loop (initial entry) and
    /// from a prior paywall's outcome closure (winback chain). Every
    /// outcome routes through `navigateToTarget(_)`, so targets that
    /// point at yet another paywall_trigger node keep the chain alive
    /// instead of collapsing to `skipToStep` (which couldn't resolve
    /// them and looped back).
    private func presentPaywallTrigger(_ target: String) {
        guard let paywallId = resolvePaywallFromTrigger(target) else {
            interactionStore.setCurrentPresentation(-1)
            onFlowCompleted(responses)
            return
        }
        let triggerData = resolvePaywallTriggerData(target)
        let onSuccessTarget = PaywallTriggerSkipResolver.nonEmpty(triggerData?["on_success_target"])
        let onFailTarget = PaywallTriggerSkipResolver.nonEmpty(triggerData?["on_fail_target"])
        let onDismissTarget = PaywallTriggerSkipResolver.nonEmpty(triggerData?["on_dismiss_target"])
        // SPEC-403 — the skip-when-subscribed decision (gate + target chain). Resolved OUTSIDE the
        // Task below so the raw `triggerData` dictionary is never captured by the concurrent closure.
        let skipIfSubscribed = PaywallTriggerSkipResolver.skipIfSubscribed(triggerData: triggerData)
        let subscribedSkip = PaywallTriggerSkipResolver.decision(
            triggerData: triggerData,
            hasActiveSubscription: true
        )
        // Legacy fallback: on_dismiss enum + next_target edge.
        let legacyDismiss = triggerData?["on_dismiss"] as? String ?? "continue"
        let edgeTarget = triggerData?["next_target"] as? String
        // §5b C5.5 — the paywall-then-complete path: the presentation ends exactly when completion fires.
        let completeFlow = onFlowCompleted
        let storeForCompletion = interactionStore
        let flowCompleted: ([String: Any]) -> Void = { r in
            storeForCompletion.setCurrentPresentation(-1)
            completeFlow(r)
        }
        let currentResponses = responses
        let tracker = eventTracker
        let flowId = flow.id
        let renderer = self

        let routeOutcome: (String?, String, String) -> Void = { configured, defaultBehavior, reason in
            let chosen = configured ?? defaultBehavior
            switch chosen {
            case "stay":
                tracker?.track(event: "onboarding_paywall_stay", properties: [
                    "flow_id": flowId, "paywall_id": paywallId, "reason": reason,
                ])
            case "complete_flow", "":
                tracker?.track(event: "onboarding_completed", properties: [
                    "flow_id": flowId, "paywall_id": paywallId, "completed_via": reason,
                ])
                flowCompleted(currentResponses)
            case "continue":
                if let edge = edgeTarget, !edge.isEmpty {
                    renderer.navigateToTarget(edge)
                } else {
                    tracker?.track(event: "onboarding_completed", properties: [
                        "flow_id": flowId, "paywall_id": paywallId, "completed_via": reason,
                    ])
                    flowCompleted(currentResponses)
                }
            default:
                renderer.navigateToTarget(chosen)
            }
        }

        let legacyDismissDefault = PaywallTriggerSkipResolver.legacyDismissDefault(legacyDismiss)

        // SPEC-404 — runtime lock skip. When the backend has signalled the
        // SDK is in locked mode (per-key suspended at day 20+ or org
        // cancelled), every paywall_trigger auto-skips via the SPEC-403
        // resolver chain. Reuses the same routing so existing flow targets
        // (`on_subscribed_skip_target` → `on_success_target` → "continue")
        // keep working. Tracker fires with reason='sdk_runtime_locked' so
        // analytics can distinguish this from organic subscribed-skips.
        if AppDNA.runtimeLock != nil {
            tracker?.track(event: "onboarding_paywall_skip", properties: [
                "flow_id": flowId,
                "paywall_id": paywallId,
                "reason": "sdk_runtime_locked",
            ])
            routeOutcome(subscribedSkip.skipTarget, "continue", "sdk_runtime_locked")
            return
        }

        // SPEC-401 Fix 1A — entitlement-aware skip gate.
        // Default `true` matches the new SDK contract: paywalls auto-skip
        // for already-subscribed users unless the author explicitly opts
        // out (upsell paywalls). Older flows that never authored the field
        // resolve to nil → defaults to true here. The check is wrapped in
        // a Task because BillingModule.hasActiveSubscription is async; if
        // the cache isn't loaded yet, falls through false → paywall
        // presents normally (acceptable defensive fallback per spec edge
        // cases).
        Task { @MainActor in
            // Pull the entitlement state into a `let` first — `&&` is an
            // autoclosure and Swift forbids `await` inside it. Short-
            // circuit at the call site preserves the same semantics
            // (skip the network/cache read when the gate is disabled).
            let isSubscribed: Bool = skipIfSubscribed
                ? await AppDNA.billing.hasActiveSubscription()
                : false
            if skipIfSubscribed && isSubscribed {
                let reason = subscribedSkip.reason ?? "user_already_subscribed"
                tracker?.track(event: "onboarding_paywall_skip", properties: [
                    "flow_id": flowId,
                    "paywall_id": paywallId,
                    "reason": reason,
                ])
                // SPEC-403 resolver chain: on_subscribed_skip_target wins,
                // falls back to on_success_target (back-compat with SPEC-401
                // 1.0.61 workaround flows), then to "continue" (legacy edge).
                routeOutcome(subscribedSkip.skipTarget, "continue", reason)
                return
            }
            // 0.1s present delay preserved — matches pre-SPEC-401 timing
            // so existing visual cadence (host fade-out + paywall appear)
            // is unchanged for non-subscribed users.
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Present on top of the onboarding host so the renderer stays
            // mounted; post-dismiss routing needs a live view to transition
            // to. Dismissing the host first used to strand the user in the
            // app after a paywall closed.
            guard let presenter = AppDNA.topViewController() else {
                flowCompleted(currentResponses)
                return
            }
            let bridge = OnboardingPaywallBridge(
                onPurchased: {
                    routeOutcome(onSuccessTarget, "continue", "paywall_purchased")
                },
                onFailed: {
                    routeOutcome(onFailTarget, "stay", "paywall_payment_failed")
                },
                onDismissedWithoutPurchase: {
                    routeOutcome(onDismissTarget, legacyDismissDefault, "paywall_dismissed")
                }
            )
            AppDNA.presentPaywall(id: paywallId, from: presenter, delegate: bridge)
        }
    }
}

// MARK: - SPEC-087: Template interpolation helper

/// Interpolates `{{variable}}` patterns in onboarding text fields via shared TemplateEngine.
extension String {
    func interpolated() -> String {
        guard self.contains("{{") else { return self }
        let ctx = TemplateEngine.shared.buildContext()
        return TemplateEngine.shared.interpolate(self, context: ctx)
    }
}

// MARK: - Step router

/// SPEC-496 §B0 — step presentations. A presentation is one ARRIVAL on a step, and the only thing that
/// starts one is `currentIndex` changing (the `.onChange(of: currentIndex)` that runs
/// `handleStepAppear`). So the serial moves only when the index does.
enum OnboardingPresentation {
    static func serial(_ serial: Int, from currentIndex: Int, to targetIndex: Int) -> Int {
        targetIndex == currentIndex ? serial : serial + 1
    }
}

/// Routes to the appropriate step view based on step type.
struct OnboardingStepRouter: View {
    let step: OnboardingStep
    /// SPEC-496 §A4 — `configOverrides[step.id]`, UN-merged. The router applies
    /// `StepConfigOverrideMerger` itself, after the raw pass (never twice, never before resolve).
    var configOverride: StepConfigOverride? = nil
    /// SPEC-496 §B0 — this presentation is still waiting on `onBeforeStepRender`.
    var hostDataPending: Bool = false
    let onNext: ([String: Any]?) -> Void
    let onSkip: () -> Void
    /// Flow ID for chat webhook context
    var flowId: String = ""
    /// Current step index (0-based) for auto-binding page_indicator / progress_bar.
    var currentStepIndex: Int = 0
    /// Total steps in the flow for auto-binding page_indicator / progress_bar.
    var totalSteps: Int = 1
    /// Previously saved responses for this step (for input retention on back navigation).
    var savedResponses: [String: Any]? = nil
    /// 🔴 Accumulated responses across ALL prior steps — NOT the same thing as `savedResponses`,
    /// which is only this step's own values for input retention.
    ///
    /// Without this, every block-level `{{responses.x}}`, every `bindings` entry pointing at
    /// `responses.…`, and every block `visibility_condition` testing a PRIOR step's answer resolved
    /// against an empty map, because `ThreeZoneStepLayout.responses` took its `[:]` default. Android
    /// has passed the real map since SPEC-401-A R11 (`accumulatedResponses = responses.toMap()`); iOS
    /// never got the same wiring, so this was a silent one-platform divergence.
    ///
    /// Step TITLES were unaffected and still interpolated, which is why it went unnoticed: they go
    /// through `loc()` → `TemplateEngine` → `SessionDataStore`, a different resolver with different
    /// roots than the block-level one.
    var accumulatedResponses: [String: Any] = [:]
    /// SPEC-452 — host data for this step, addressable as `{{hook_data.…}}` and as a `bindings`
    /// target. Nil until a host returns one.
    ///
    /// SPEC-496 §5b C3 — the EFFECTIVE map: the `onBeforeStepRender` base with the interaction data
    /// layer applied, read from the store's LIVE values (never this router's copied `configOverride`,
    /// which only refreshes on the flow host's next body pass). Every reader uses this one map.
    var hostDataContext: [String: Any]? {
        interactionStore.effectiveHookData(stepId: step.id, fallbackBase: configOverride?.dataContext)
    }
    /// SPEC-496 §5b C3 — `configOverrides[step.id]` read LIVE from the store (the flow host records it
    /// there in the same turn it writes it), so a reply folded through an older router copy — a `fire`
    /// closure the environment kept — still resolves, prunes and gates against the current base.
    private var liveConfigOverride: StepConfigOverride? {
        Self.liveOverride(store: interactionStore, stepId: step.id, copied: configOverride)
    }
    /// The live base, else this copy's own `configOverride` (a router built without the flow host).
    static func liveOverride(store: HostDataInteractionStore, stepId: String, copied: StepConfigOverride?) -> StepConfigOverride? {
        store.baseOverride(stepId: stepId) ?? copied
    }
    /// SPEC-496 §5b C4 — the flow host's pending answer for THIS router's serial, read live. Nil for a
    /// router built without the flow host, which then uses its copied `hostDataPending`.
    var pendingProvider: (() -> Bool)? = nil
    private var livePending: Bool { Self.livePending(provider: pendingProvider, copied: hostDataPending) }
    static func livePending(provider: (() -> Bool)?, copied: Bool) -> Bool { provider?() ?? copied }
    /// SPEC-421 — flow host delegate + analytics tracker, needed for the permission pipeline
    /// (pre-hook, `onPermissionResult`, and the five `permission_*` analytics literals).
    weak var delegate: AppDNAOnboardingDelegate?
    var eventTracker: EventTracker?
    /// SPEC-496 §5b — this router's presentation serial (the flow host's `presentationSerial`).
    let presentation: Int
    /// SPEC-496 §5b C3 — the flow-level owner of the interaction layer, stamps and `callSeq`.
    @ObservedObject private var interactionStore: HostDataInteractionStore
    /// SPEC-496 §5b C5.5 — THIS presentation's coordinator, looked up once in `init` (a reused router
    /// whose presentation changed is re-initialised by its parent's body and picks up the new one).
    /// `body` and every method use only this property, never `coordinator(for:)`.
    @ObservedObject private var coordinator: InteractionCoordinator

    @State private var toggleValues: [String: Bool] = [:]
    /// SPEC-421 — async per-type OS permission requester (retained across re-renders so a
    /// pending location/notification prompt's continuation isn't dropped).
    @State private var permissionManager = PermissionManager()
    /// SPEC-421 — drives the optional "Open Settings" affordance when a permission is denied and
    /// the step authored `show_settings_fallback_on_denied`.
    @State private var permissionSettingsAlert: PermissionSettingsAlert?
    @State private var inputValues: [String: Any]
    @State private var showValidationToast = false
    /// SPEC-419 STEP-2 — per-block `field_config` overrides pushed back by the host delegate
    /// (`ElementInteractionResult.fieldConfigPatches`). Keyed by blockId → (key → value). Layered at
    /// render time on top of the resolved block; empty = zero change.
    ///
    /// SPEC-496 §5b C4 — keyed by PRESENTATION first, and read / written only under this router's
    /// `presentation`: a router reused for a new presentation (a 0→1→0 inside the exit animation
    /// keeps `.id(currentIndex)`) reads an empty entry on its very first frame.
    @State private var fieldConfigOverridesByPresentation: [Int: [String: [String: Any]]] = [:]
    /// #657 — per-block replacement options pushed back by a refresh interaction. Layered at read
    /// time like `fieldConfigOverrides`, because `ContentBlock` is immutable. Keyed by presentation.
    @State private var fieldOptionsOverridesByPresentation: [Int: [String: [InputOption]]] = [:]

    private var fieldConfigOverrides: [String: [String: Any]] { fieldConfigOverridesByPresentation[presentation] ?? [:] }
    private var fieldOptionsOverrides: [String: [InputOption]] { fieldOptionsOverridesByPresentation[presentation] ?? [:] }
    /// SPEC-496 — memo of the step pipeline (raw pass → decode → override merge → layering).
    @State private var pipelineMemo = OnboardingStepPipelineMemo()

    init(step: OnboardingStep, configOverride: StepConfigOverride? = nil, hostDataPending: Bool = false, pendingProvider: (() -> Bool)? = nil, onNext: @escaping ([String: Any]?) -> Void, onSkip: @escaping () -> Void, flowId: String = "", currentStepIndex: Int = 0, totalSteps: Int = 1, savedResponses: [String: Any]? = nil, accumulatedResponses: [String: Any] = [:], delegate: AppDNAOnboardingDelegate? = nil, eventTracker: EventTracker? = nil, presentation: Int = 0, interactionStore: HostDataInteractionStore? = nil) {
        self.step = step
        self.configOverride = configOverride
        self.hostDataPending = hostDataPending
        self.pendingProvider = pendingProvider
        self.onNext = onNext
        self.onSkip = onSkip
        self.flowId = flowId
        self.currentStepIndex = currentStepIndex
        self.totalSteps = totalSteps
        self.savedResponses = savedResponses
        self.accumulatedResponses = accumulatedResponses
        self.delegate = delegate
        self.eventTracker = eventTracker
        self.presentation = presentation
        let store = interactionStore ?? HostDataInteractionStore()
        self._interactionStore = ObservedObject(wrappedValue: store)
        // §5b C5.5 — the get-or-create runs HERE, during the flow host's body; its dictionary write
        // is plain, so nothing is published during a view update.
        self._coordinator = ObservedObject(wrappedValue: store.coordinator(for: presentation, stepId: step.id))
        // Pre-populate inputValues from saved responses so child views see data immediately
        _inputValues = State(initialValue: savedResponses ?? [:])
    }

    // MARK: - SPEC-496 step pipeline

    /// The presented step after the ONE pipeline: raw host-data pass → typed decode (per-key revert)
    /// → `StepConfigOverrideMerger` → interaction layering. Every reader below — rendering, the
    /// required gate, the toast, the OTP resolver, the consent-CTA gate — reads THIS.
    private var resolvedStep: ResolvedOnboardingStep {
        pipelineMemo.resolve(OnboardingStepPipeline.Input(
            step: step,
            override: liveConfigOverride,
            pending: livePending,
            inputValues: inputValues,
            responses: accumulatedResponses,
            templateContext: TemplateEngine.shared.buildContext(),
            selected: SelectedOptionStore.shared.snapshot,
            fieldConfigOverrides: fieldConfigOverrides,
            fieldOptionsOverrides: fieldOptionsOverrides,
            // §5b C3 — the effective map (base + interaction layer), from the store's live values.
            hookDataSource: .effective(hostDataContext)
        ))
    }

    /// The effective config every reader uses (was handed in pre-merged by the flow host).
    private var effectiveConfig: StepConfig { resolvedStep.config }

    // SPEC-084: Localization helper for step text
    // SPEC-087: Also interpolates {{variables}} after localization
    // SPEC-496: …except for a raw-resolved block, where it is LOOKUP-ONLY (no re-scan).
    private func loc(_ key: String, _ fallback: String) -> String {
        OnboardingStepPipeline.loc(key, fallback, resolved: resolvedStep, context: { TemplateEngine.shared.buildContext() })
    }

    /// SPEC-496 §B0 — drop selections a §B0-scoped Select no longer renders.
    private func clearVanishedSelections() {
        let r = resolvedStep
        let out = OnboardingStepPipeline.clearVanishedSelections(blocks: r.blocks, rawResolvedIds: r.rawResolvedIds, inputValues: inputValues)
        guard !out.changes.isEmpty else { return }
        inputValues = out.inputValues
        OnboardingStepPipeline.applySelectionChanges(out.changes)
    }

    /// Changes whenever the rendered options of a scoped Select change.
    private var scopedSelectionSignature: String {
        let r = resolvedStep
        return OnboardingStepPipeline.allStepBlocks(r.blocks).compactMap { b -> String? in
            guard let st = OnboardingStepPipeline.resolveState(b, rawResolvedIds: r.rawResolvedIds) else { return nil }
            return "\(b.id)|\(st)|" + (b.field_options ?? []).map(\.resolvedValue).joined(separator: ",")
        }.joined(separator: ";")
    }

    var body: some View {
        Group {
            if let blocks = effectiveConfig.content_blocks, !blocks.isEmpty {
                blockBasedStepView(blocks: blocks)
                    // SPEC-496 §5b C5.1 — the step's interaction channel for `refresh_step` buttons at
                    // any depth (three zones, lifted maps, containers, carousel pages). Rebuilt on
                    // every change of the coordinator's published state.
                    .environment(\.appdnaStepInteraction, StepInteraction.make(
                        presentation: presentation, coordinator: coordinator,
                        pending: livePending, fire: handleInteract
                    ))
            } else {
                legacyStepView
            }
        }
        // Background is rendered at the OnboardingFlowHost level (full-screen behind nav bar)
        // Keyboard dismiss handled by ScrollView .scrollDismissesKeyboard in ThreeZoneStepLayout
        // Intercept links to open in-app instead of Safari
        .environment(\.openURL, OpenURLAction { url in
            InAppBrowser.present(url: url)
            return .handled
        })
        // inputValues pre-populated from savedResponses in init()
        // Validation toast overlay
        .overlay(alignment: .bottom) {
            if showValidationToast {
                let r = resolvedStep
                let blocks = r.blocks
                let verdict = RequiredFieldGate.evaluate(blocks: blocks, inputValues: inputValues, rawResolvedIds: r.rawResolvedIds)
                let missingBlock = blocks.first(where: { b in
                    guard b.field_required == true else { return false }
                    if OnboardingStepPipeline.resolveState(b, rawResolvedIds: r.rawResolvedIds) == "empty_in_scope" { return false }
                    let fieldId = b.field_id ?? b.id
                    let v = inputValues[fieldId]
                    return v == nil || (v as? String)?.isEmpty == true
                })
                // SPEC-496 — while host data is pending the answer is "Loading…", not "fill this in".
                Text(verdict.blockedByPending ? "Loading…" : "Please fill in \(missingBlock?.field_label ?? "required fields")")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(12)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .entryAnimation(effectiveConfig.animation?.entry_animation, durationMs: effectiveConfig.animation?.entry_duration_ms)
        // SPEC-496 §B0 — a scoped Select whose rendered options no longer contain the selection
        // drops it (inputValues, the view's state, SelectedOptionStore).
        .onAppear { clearVanishedSelections() }
        .onChange(of: scopedSelectionSignature) { _ in clearVanishedSelections() }
        // SPEC-421 — settings fallback for a denied permission (opt-in via `show_settings_fallback_on_denied`).
        .alert(
            "Permission needed",
            isPresented: Binding(
                get: { permissionSettingsAlert != nil },
                set: { if !$0 { permissionSettingsAlert = nil } }
            ),
            presenting: permissionSettingsAlert
        ) { alert in
            Button(alert.label) {
                permissionManager.openSettings()
                permissionSettingsAlert = nil
                advancePermissionStep(type: alert.type)
            }
            Button("Continue", role: .cancel) {
                permissionSettingsAlert = nil
                advancePermissionStep(type: alert.type)
            }
        } message: { _ in
            Text("You can enable this in Settings.")
        }
    }

    // MARK: - Block-based step view (SPEC-084)

    @ViewBuilder
    private func blockBasedStepView(blocks: [ContentBlock]) -> some View {
        let variant = effectiveConfig.layout_variant ?? "no_image"

        /*
         SPEC-495 §C — the two map placements that are NOT blocks in the column.

         A `fullscreen` map is the step's BACKGROUND, and a `top`/`bottom` anchored map is pinned to
         a step edge with the content flowing past it. Neither can be rendered from inside the
         three-zone layout, which lays its children out in a scrolling stack — so they are lifted out
         here and the zones render what is left.

         🔴 Lifted, not COPIED. The filter below removes them, or a fullscreen map would be drawn
         twice: once behind the content and once as an 844pt block inside it.

         Only the FIRST of each is honoured. Two backgrounds is not a thing an author can mean, and
         silently stacking them is how you get a map nobody can explain. Mirrors the Android hoist in
         `BlockBasedStepView`.
         */
        let backdropMap = blocks.first { $0.type == .map && mapPlacementOf($0) == .backdrop }
        let topMap = blocks.first { $0.type == .map && mapPlacementOf($0) == .anchorTop }
        let bottomMap = blocks.first { $0.type == .map && mapPlacementOf($0) == .anchorBottom }
        let hoisted = [backdropMap?.id, topMap?.id, bottomMap?.id].compactMap { $0 }
        let blocks = hoisted.isEmpty ? blocks : blocks.filter { !hoisted.contains($0.id) }

        stepMapFrame(backdrop: backdropMap, top: topMap, bottom: bottomMap) {
            switch variant {
            case "image_fullscreen":
                // image_fullscreen: background image is rendered in parent ZStack via step.background.
                // The layout_variant image_url is a legacy field — skip it here to avoid double-rendering.
                // Just use the three-zone layout which fills the parent ZStack.
                threeZoneLayout(blocks: blocks)

            case "image_split":
                // 40/60 image-to-content split (SPEC-084 Gap #15)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if let url = effectiveConfig.image_url {
                            BundledAsyncPhaseImage(url: URL(string: url)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                }
                            }
                            .frame(width: geometry.size.width * 0.4)
                            .clipped()
                        }
                        threeZoneLayout(blocks: blocks)
                            .frame(width: geometry.size.width * 0.6)
                    }
                }

            case "image_bottom", "image_top":
                // image_top/image_bottom: background images rendered by parent ZStack.
                // layout_variant image_url is legacy — background.image_url is the source of truth.
                threeZoneLayout(blocks: blocks)

            default: // no_image
                threeZoneLayout(blocks: blocks)
            }
        }
    }

    // MARK: - Three-zone layout helper

    /**
     SPEC-495 §C — the step, with its map placements around it.

     🔴 THE CONTENT SLOT IS `maxHeight: .infinity`, AND THAT IS THE WHOLE POINT.

     SPEC-495 §C says a fullscreen or anchored map must not break scrolling. A map that ate the
     available height and left the content unbounded would do exactly that — and #671 was a map that
     only LOOKED like it had broken scrolling, so the real version is not a subtle bug to ship on top
     of it. The content keeps the whole remaining height; the anchored strips take their own.

     With no placements at all this is the identity function — no ZStack, no VStack, no layout change
     on the overwhelming majority of steps that have no map.
     */
    @ViewBuilder
    private func stepMapFrame<Content: View>(
        backdrop: ContentBlock?,
        top: ContentBlock?,
        bottom: ContentBlock?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if backdrop == nil, top == nil, bottom == nil {
            content()
        } else {
            ZStack {
                if let backdrop {
                    mapPlacementView(backdrop, .backdrop)
                }
                VStack(spacing: 0) {
                    if let top {
                        mapPlacementView(top, .anchorTop)
                    }
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let bottom {
                        mapPlacementView(bottom, .anchorBottom)
                    }
                }
            }
        }
    }

    /// One map block, rendered through the SAME renderer the column uses — placement is the only
    /// difference. A second copy of the map's 70 lines is exactly the drift the parity gates exist
    /// to catch, so there isn't one.
    private func mapPlacementView(_ block: ContentBlock, _ placement: MapPlacement) -> some View {
        let r = resolvedStep
        return ContentBlockRendererView(
            blocks: [block],
            onAction: handleBlockAction,
            toggleValues: $toggleValues,
            loc: loc,
            responses: accumulatedResponses,
            hookData: hostDataContext,
            inputValues: $inputValues,
            currentStepIndex: currentStepIndex,
            totalSteps: totalSteps,
            onInteract: handleInteract,
            // SPEC-496 §A4 — interaction options / patches are already layered into the ONE list.
            mapPlacement: placement,
            rawResolvedIds: r.rawResolvedIds,
            gateBlocks: r.blocks
        )
    }

    @ViewBuilder
    private func threeZoneLayout(blocks: [ContentBlock]) -> some View {
        let r = resolvedStep
        ThreeZoneStepLayout(
            blocks: blocks,
            onAction: handleBlockAction,
            toggleValues: $toggleValues,
            loc: loc,
            // Both of these defaulted to empty/nil here, which made every `{{responses.x}}` and
            // every `{{hook_data.x}}` below this point resolve to nothing.
            responses: accumulatedResponses,
            hookData: hostDataContext,
            inputValues: $inputValues,
            currentStepIndex: currentStepIndex,
            totalSteps: totalSteps,
            onInteract: handleInteract,
            // SPEC-496 §A4 — interaction options / patches are already layered into the ONE list
            // (`resolvedStep`), so nothing is layered again at draw time.
            rawResolvedIds: r.rawResolvedIds,
            gateBlocks: r.blocks
        )
    }

    // MARK: - Legacy step view (backward compat)

    @ViewBuilder
    private var legacyStepView: some View {
        VStack {
            switch step.type {
            case .welcome:
                WelcomeStepView(config: effectiveConfig, onNext: { onNext(nil) })
            case .question:
                QuestionStepView(config: effectiveConfig, onNext: onNext)
            case .value_prop:
                ValuePropStepView(config: effectiveConfig, onNext: { onNext(nil) })
            case .custom:
                CustomStepView(config: effectiveConfig, onNext: { onNext(nil) })
            case .form:
                FormStepView(config: effectiveConfig, onNext: onNext, apiClient: AppDNA.geocodeClient, savedValues: savedResponses)
            case .interactive_chat:
                ChatStepView(step: step, flowId: flowId, onNext: { data in onNext(data) }, onSkip: onSkip, savedTranscript: savedResponses)
            }

            if step.config.skip_enabled == true {
                Button("Skip") { onSkip() }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Block action handler

    /// Check if all required input blocks have values.
    /// SPEC-419 STEP-2 — delegates to the pure `RequiredFieldGate` so the walk is unit-testable and the
    /// interaction-driven advance path can't bypass required-field validation.
    private var canAdvance: Bool {
        let r = resolvedStep
        return RequiredFieldGate.evaluate(blocks: r.blocks, inputValues: inputValues, rawResolvedIds: r.rawResolvedIds).canAdvance
    }

    // MARK: - Element interaction (SPEC-419 STEP-2)

    /// Closure threaded down the block tree; an interactive element calls this with its
    /// `(blockId, action, value)`. SPEC-496 §5b — the call goes through THIS presentation's
    /// `InteractionCoordinator` (presentation check at start and at arrival, a presentation-scoped
    /// in-flight lock, generation tokens, the 8 s refresh deadline), and the host is told the
    /// coordinator's OWN step id. Any `advance` funnels through `handleBlockAction("next")` (the ONLY
    /// entry that runs `canAdvance`).
    private func handleInteract(_ blockId: String, _ action: String, _ value: String?) {
        let host = delegate
        let flowId = flowId
        let stepId = coordinator.stepId
        // The TAP-TIME snapshot is only what the host is SENT. It is never written back (C4.1).
        let snapshot = inputValues
        coordinator.start(
            blockId: blockId,
            action: action,
            value: value,
            pending: livePending,
            hasDelegate: host != nil,
            call: {
                await host?.onElementInteraction(
                    flowId: flowId, stepId: stepId, blockId: blockId,
                    action: action, value: value, inputValues: snapshot
                )
            },
            onReply: { result, seq in
                applyInteractionReply(result, seq: seq, snapshot: snapshot)
            }
        )
    }

    /// SPEC-496 §5b C4 — the four outputs of one reply touch disjoint state and are written TOGETHER,
    /// in this one main-thread turn; then exactly one re-resolve (`resolvedStep` reads the state just
    /// written, the layer included), the §B0 prune, and — if asked — the gated advance.
    private func applyInteractionReply(_ result: ElementInteractionResult, seq: Int, snapshot: [String: Any]) {
        InteractionReplyFold.apply(
            result, seq: seq, snapshot: snapshot, stepId: step.id, presentation: presentation,
            store: interactionStore,
            current: .init(inputValues: inputValues,
                           fieldConfigOverridesByPresentation: fieldConfigOverridesByPresentation,
                           fieldOptionsOverridesByPresentation: fieldOptionsOverridesByPresentation),
            commit: { w in
                inputValues = w.inputValues
                fieldConfigOverridesByPresentation = w.fieldConfigOverridesByPresentation
                fieldOptionsOverridesByPresentation = w.fieldOptionsOverridesByPresentation
            },
            // `resolvedStep` re-resolves synchronously from the state just written (live store base
            // and layer included); the prune must run before the gate judges a vanished value —
            // `.onChange(of: scopedSelectionSignature)` only fires after the next body pass.
            resolveAndPrune: { clearVanishedSelections() },
            advance: { handleBlockAction("next", nil) }
        )
    }

    /// The advance every CTA shares: gate on required fields, collect the step's answers, hand them
    /// up. `extra` is merged last so a flag CTA cannot be silently overwritten by a form field.
    ///
    /// Extracted so `next` and `flag` cannot drift. They did drift in an earlier draft of this: the
    /// flag path skipped `canAdvance`, which let a CTA advance past an unanswered required field
    /// purely because it also set a flag.
    private func advanceCollectingStepData(extra: [String: Any] = [:]) {
        // SPEC-496 §B0 — every CTA gates on the pruned selection, not one the step no longer renders.
        // Idempotent, and never touches a pending / Option-Set / out-of-scope block.
        clearVanishedSelections()
        guard canAdvance else {
            withAnimation { showValidationToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation { showValidationToast = false }
            }
            return
        }
        // Collect toggle values and input values into response
        var data: [String: Any] = [:]
        for (key, value) in toggleValues {
            data["toggle_\(key)"] = value
        }
        // SPEC-089d Phase 3: Include form input values in step response
        for (key, value) in inputValues {
            data[key] = value
        }
        for (key, value) in extra {
            data[key] = value
        }
        onNext(data.isEmpty ? nil : data)
    }

    private func handleBlockAction(_ action: String, _ actionValue: String?) {
        switch action {
        case "next":
            // SPEC-421 — a permission step whose CTA is authored as plain `action:"next"`
            // (instead of `action:"permission"`) must STILL honor the step's `permission_type`
            // and run the permission pipeline rather than silently advancing. Reuse
            // PermissionManager's own support check — do not invent a new list. Non-permission
            // "next" steps (empty/unsupported type) fall through to the normal advance below.
            let nextPermissionType = effectiveConfig.permission_type ?? (effectiveConfig.layout?["permission_type"]?.value as? String) ?? ""
            if !nextPermissionType.isEmpty, PermissionManager.isSupported(nextPermissionType) {
                runPermissionPipeline(nextPermissionType)
                return
            }
            advanceCollectingStepData()
        case OnboardingCTAFlag.actionName:
            // A CTA that RECORDS A CHOICE and continues.
            //
            // The case it exists for: a summary step offers an upsell ("book a workshop", "go
            // premium"). Routing to that destination DURING onboarding tears the user out of a flow
            // they are halfway through, and every host that tried it ended up rebuilding the flow
            // state by hand on the way back. So the CTA writes one key and advances exactly like
            // `next` — same required-field gate, same step data, same next-step rules. Where the
            // user goes is the host's decision, made once, at `onOnboardingCompleted`.
            //
            // Deliberately NOT a branch: a flag must not change which step comes next. An author who
            // wants the flow itself to fork already has `next_step_rules`, which can read the very
            // key this writes.
            guard let flag = OnboardingCTAFlag.parse(actionValue) else {
                // An author selected "Flag & continue" and left the key blank. Advancing without
                // recording anything is the honest behaviour — silently doing nothing at all would
                // look like a dead button.
                //
                // A LOG, not `reportInitDegraded`: this fires on every tap, and the degraded-init
                // delegate is for "a subsystem will not work", not for an authoring slip. Android
                // logs the same line at the same point.
                Log.warning(
                    "A CTA is configured to set a flag but has no flag key; " +
                    "it will advance without recording one."
                )
                advanceCollectingStepData()
                return
            }
            advanceCollectingStepData(extra: [flag.key: flag.value])
        case "skip":
            onSkip()
        case "link":
            if let urlString = actionValue, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    InAppBrowser.present(url: url)
                }
            }
            // Don't advance — user will return from in-app browser
        case PendingCompletionRoute.actionName:
            // Record the destination and advance exactly like `next` — same required-field gate,
            // same step data, same next-step rules. `OnboardingCompletion` opens it once the flow
            // is finished.
            //
            // Advancing is the whole point: this exists for a cross-sell the user meets BEFORE the
            // end ("book a workshop"), and opening it on tap would abandon the rest of the flow.
            // `link` already covers "open it now" for a terms or privacy URL.
            if actionValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                // An author chose "Open link after onboarding" and left the URL blank. Advancing is
                // the honest behaviour — a button that does nothing at all reads as broken. A LOG,
                // not `reportInitDegraded`: this is an authoring slip, not a dead subsystem, and it
                // fires on every tap. Android logs the same line at the same point.
                Log.warning(
                    "A CTA is configured to open a link after onboarding but has no URL; " +
                    "it will advance without recording a destination."
                )
            } else {
                PendingCompletionRoute.shared.record(actionValue)
            }
            advanceCollectingStepData()
        case "social_login":
            // Social login: pass provider info via onNext but mark as social_login.
            // The flow host's handleStepCompleted will fire onBeforeStepAdvance hook.
            // The delegate handles auth and returns:
            //   - .proceedWithData to advance with auth data
            //   - .block("Signing in...") to stay on step while auth happens
            //   - .proceed to advance immediately
            // The data includes "action": "social_login" so the flow host knows not to
            // auto-advance if no delegate is set.
            onNext(SocialLoginStepData.build(provider: actionValue, inputValues: inputValues))
        case permissionActionName:
            // SPEC-421 + SPEC-070-B: resolve the type (config → layout → the BUTTON'S OWN value, which
            // this used to ignore), tell the host the permission CTA was acted on (every other CTA
            // does; this one never did), and only then decide.
            //   • supported type  → the real OS pipeline owns the advance (it must wait for the OS).
            //   • unsupported/blank → `emitPermissionAction` has already emitted, and that emission IS
            //     the advance, so a typo'd permission can never dead-end the flow on an inert button.
            let permissionDecision = emitPermissionAction(
                configType: effectiveConfig.permission_type,
                layoutType: effectiveConfig.layout?["permission_type"]?.value as? String,
                actionValue: actionValue,
                toggleValues: toggleValues,
                inputValues: inputValues,
                onNext: { onNext($0) }
            )
            if case .runPipeline(let permissionType) = permissionDecision {
                runPermissionPipeline(permissionType)
            }

        // MARK: Auth actions (entry)
        case "login", "register", "reset_password", "magic_link",
             "verify_email", "resend_verification", "enable_biometric",
             "email_login":
            emitAuthAction(action, actionValue: actionValue)
        case "request_otp", "verify_otp":
            emitAuthAction(action, actionValue: actionValue, includeChannel: true)

        // MARK: Account lifecycle
        case "logout", "change_password", "set_new_password",
             "delete_account", "update_profile":
            emitAuthAction(action, actionValue: actionValue)

        default:
            onNext(nil)
        }
    }

    /// Strict-typed auth/account action emitter. Validates required fields,
    /// then emits `{action, [channel?], [recipient?], ...inputValues}` so the
    /// host can route via `onBeforeStepAdvance`. Stays on the step (no auto-
    /// advance) so the host can show a "Signing in..." spinner via `.block(...)`.
    ///
    /// Merge order: inputValues are placed first so the SDK-controlled keys
    /// (`action`, `channel`, `recipient`) always win. A field id collision
    /// (e.g. customer named an input "action") cannot mask the button identity.
    /// `channel` is omitted entirely when nil rather than wrapped as `Any`,
    /// since wrapping `Optional.none` breaks JSONSerialization downstream.
    private func emitAuthAction(_ action: String, actionValue: String?, includeChannel: Bool = false) {
        // Required-field validation runs first — same gate as `next`.
        guard canAdvance else {
            withAnimation { showValidationToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation { showValidationToast = false }
            }
            return
        }
        var data: [String: Any] = [:]
        for (key, value) in inputValues {
            data[key] = value
        }
        data["action"] = action
        if includeChannel {
            let resolved = resolveOtpChannel(actionValue: actionValue)
            if let channel = resolved.channel {
                data["channel"] = channel
            }
            if let recipient = resolved.recipient {
                data["recipient"] = recipient
            }
        }
        onNext(data)
    }

    /// Resolve the OTP delivery channel for `request_otp` / `verify_otp`.
    /// Thin wrapper around the pure `OtpChannelResolver.resolve` so the view
    /// can pass its own state in and the resolver stays unit-testable.
    private func resolveOtpChannel(actionValue: String?) -> (channel: String?, recipient: String?) {
        OtpChannelResolver.resolve(
            actionValue: actionValue,
            blocks: effectiveConfig.content_blocks ?? [],
            inputValues: inputValues,
        )
    }

    // MARK: - Permission pipeline (SPEC-421)

    /// Analytics props attached to every `permission_*` literal.
    private func permissionProps(_ type: String) -> [String: Any] {
        ["permission_type": type, "flow_id": flowId, "step_id": step.id]
    }

    /// Store the resolved value under `permission_{type}` (routable by `next_step_rules`) and
    /// fire the observe-only delegate callback. Does NOT advance — callers advance explicitly.
    private func storePermissionResult(_ type: String, granted: Bool) {
        inputValues["permission_" + type] = granted ? "granted" : "denied"
        delegate?.onPermissionResult(flowId: flowId, stepId: step.id, permissionType: type, granted: granted)
    }

    /// Advance via the same collect-and-`onNext` path the step's primary CTA uses, so the freshly
    /// stored `permission_{type}` value rides along in the step response.
    ///
    /// Round-12 Finding 2 — build the payload via `permissionActionPayload` so it carries `action` +
    /// `action_value` (the button identity), matching Android's runPipeline path AND iOS's own
    /// safeFallbackAdvance path (and the contract in PermissionAction.swift). Previously this path
    /// omitted those keys, so a permission step that actually prompted advanced with a different
    /// `selection_data` shape than Android and than the same step's fallback path.
    private func advancePermissionStep(type: String) {
        let data = permissionActionPayload(type: type, toggleValues: toggleValues, inputValues: inputValues)
        onNext(data.isEmpty ? nil : data)
    }

    private func presentSettingsFallback(type: String, label: String) {
        permissionSettingsAlert = PermissionSettingsAlert(type: type, label: label)
    }

    /// The full async permission pipeline for a `permission` CTA. Reads `layout.permission_type`,
    /// runs the optional host pre-hook, status check, native OS request, analytics + delegate
    /// callbacks, stores the result, and advances. Never crashes on a missing usage-description key
    /// (`PermissionManager.status` returns `.unavailable` → we emit + advance without calling the OS).
    private func runPermissionPipeline(_ type: String) {
        let mgr = permissionManager
        Task {
            // 1. Optional host pre-hook — host may resolve without prompting.
            if let handling = await delegate?.onPermissionRequest(type) {
                switch handling {
                case .handledByHost(let granted):
                    await MainActor.run {
                        if granted {
                            eventTracker?.track(event: "permission_granted", properties: permissionProps(type))
                        } else {
                            eventTracker?.track(event: "permission_denied", properties: permissionProps(type))
                        }
                        storePermissionResult(type, granted: granted)
                        advancePermissionStep(type: type)
                    }
                    return
                case .proceed:
                    break
                }
            }

            // 2. Status check (async where the OS requires it).
            let status = await mgr.status(type)
            switch status {
            case .granted:
                await MainActor.run {
                    eventTracker?.track(event: "permission_already_granted", properties: permissionProps(type))
                    storePermissionResult(type, granted: true)
                    advancePermissionStep(type: type)
                }

            case .denied:
                let showFallback = (effectiveConfig.show_settings_fallback_on_denied ?? (effectiveConfig.layout?["show_settings_fallback_on_denied"]?.value as? Bool)) == true
                let label = effectiveConfig.settings_fallback_label ?? (effectiveConfig.layout?["settings_fallback_label"]?.value as? String) ?? "Open Settings"
                await MainActor.run {
                    eventTracker?.track(event: "permission_denied", properties: permissionProps(type))
                    storePermissionResult(type, granted: false)
                    if showFallback {
                        // Offer an "Open Settings" affordance; advance on the user's choice.
                        presentSettingsFallback(type: type, label: label)
                    } else {
                        advancePermissionStep(type: type)
                    }
                }

            case .unavailable:
                await MainActor.run {
                    eventTracker?.track(event: "permission_unavailable", properties: permissionProps(type))
                    Log.warning("[Permission] '\(type)' unavailable (missing Info.plist usage description or unsupported type) — advancing without prompting.")
                    advancePermissionStep(type: type)
                }

            case .undetermined:
                await MainActor.run {
                    eventTracker?.track(event: "permission_prompted", properties: permissionProps(type))
                }
                let granted = await mgr.request(type)
                await MainActor.run {
                    if granted {
                        eventTracker?.track(event: "permission_granted", properties: permissionProps(type))
                    } else {
                        eventTracker?.track(event: "permission_denied", properties: permissionProps(type))
                    }
                    storePermissionResult(type, granted: granted)
                    advancePermissionStep(type: type)
                }
            }
        }
    }
}

/// SPEC-421 — identifies a pending "Open Settings" affordance for a denied permission.
struct PermissionSettingsAlert: Identifiable {
    let id = UUID()
    let type: String
    let label: String
}

// MARK: - Required-field gate (SPEC-419 STEP-2)

/// Pure required-field validation used by `handleBlockAction("next")`. Extracted so the advance gate is
/// unit-testable without a live host, proving an interaction-driven advance can't bypass validation.
enum RequiredFieldGate {
    /// SPEC-496 — the gate's verdict, plus WHY it is blocked: `blockedByPending` means a required /
    /// minimum-selection field is still waiting on host data (the toast says "Loading…").
    struct Verdict {
        let canAdvance: Bool
        let firstMissing: String?
        let blockedByPending: Bool
    }

    static func evaluate(blocks: [ContentBlock], inputValues: [String: Any]) -> (canAdvance: Bool, firstMissing: String?) {
        let v = evaluate(blocks: blocks, inputValues: inputValues, rawResolvedIds: [])
        return (v.canAdvance, v.firstMissing)
    }

    /// SPEC-496 §A1 "Required gate input" — the raw pass's `field_config.resolve_state` markers,
    /// honoured ONLY on blocks the raw pass produced (`rawResolvedIds`):
    ///   - `pending`        → unanswered for BOTH loops (required and `min_selections`), even with a
    ///                        saved value; the toast is the loading one.
    ///   - `empty_in_scope` → satisfied for both loops (a Select with nothing to pick never traps).
    ///   - `scoped`         → the effective minimum is `min(min_selections, rendered option count)`.
    static func evaluate(blocks: [ContentBlock], inputValues: [String: Any], rawResolvedIds: Set<String>) -> Verdict {
        func marker(_ b: ContentBlock) -> String? { OnboardingStepPipeline.resolveState(b, rawResolvedIds: rawResolvedIds) }
        // Pending first: while host data is in flight the answer is "loading", not "fill this in".
        for block in blocks where marker(block) == "pending" {
            let minimum = cfgDouble(block.field_config?["min_selections"]).map { Int($0) } ?? 0
            if block.field_required == true || minimum > 0 {
                return Verdict(canAdvance: false, firstMissing: block.field_id ?? block.id, blockedByPending: true)
            }
        }
        let legacy = evaluateAuthored(blocks: blocks, inputValues: inputValues, marker: marker)
        return Verdict(canAdvance: legacy.canAdvance, firstMissing: legacy.firstMissing, blockedByPending: false)
    }

    private static func evaluateAuthored(
        blocks: [ContentBlock], inputValues: [String: Any], marker: (ContentBlock) -> String?
    ) -> (canAdvance: Bool, firstMissing: String?) {
        // SPEC-446 §3 — a Summary Screen can host inputs INSIDE its stats, so one block may carry
        // several field ids. This loop reads exactly one key per block (`field_id ?? id`), so
        // without this pass it sees none of them — and if an author set block-level
        // `field_required` on such a block it would read a key nothing ever writes and the CTA
        // could never enable: an unadvanceable step, the class this gate's own history records
        // fixing twice. Required-ness is therefore PER STAT, and block-level `field_required` on a
        // summary_screen is ignored rather than honoured.
        for block in blocks where block.type == .summary_screen {
            let stats = (block.field_config?["summary_stats"]?.value as? [Any]) ?? []
            for (statIndex, entry) in stats.enumerated() {
                guard let stat = entry as? [String: Any],
                      let input = stat["input"] as? String, input != "none",
                      String(describing: stat["required"] ?? "") == "true"
                else { continue }
                // #595 — a stat with no authored `field_id` used to be skipped here, so `required`
                // was silently dropped. It now falls back to the same derived key the renderer's
                // control writes; deriving it anywhere but `summaryStatFieldId` would gate on a key
                // nothing writes.
                let fieldId = summaryStatFieldId(blockId: block.id, index: statIndex, stat: stat)
                // An authored `default` SATISFIES the requirement, and is checked here rather than
                // relying on the control having seeded it. The control seeds on appear, so a summary
                // block below the fold in a scrolling step has not run that code yet — the value
                // would be missing, the CTA would stay disabled, and the user would have to scroll
                // to a control they never needed to touch before Continue lit up. The gate must not
                // depend on view lifecycle to agree with what the screen will show.
                if stat["default"] != nil { continue }
                let value = inputValues[fieldId]
                if value == nil { return (false, fieldId) }
                if let s = value as? String, s.isEmpty { return (false, fieldId) }
            }
        }

        // #585 — a MINIMUM selection count gates the CTA.
        //
        // 🔴 `min_selections` has been in the Zod schema since EPIC-5, with a console control on
        // form fields, and NOTHING on any platform ever read it. An author could set "Min
        // selections: 3", publish, and the CTA advanced on zero — a control that lied. This branch
        // is what makes it true.
        //
        // Deliberately INDEPENDENT of `field_required`: setting a minimum IS the requirement, and
        // making an author tick a separate box to arm it is the same trap one layer up. A missing
        // or non-array value counts as zero selections rather than passing, so a step whose control
        // has not been touched yet blocks rather than advances.
        //
        // `min_selections <= 0` is not a gate — the console writes 0 for "no minimum", and treating
        // that as "at least zero, always satisfied" is both correct and what an author means.
        for block in blocks {
            guard let raw = block.field_config?["min_selections"]?.value else { continue }
            var minimum = (raw as? Int) ?? (raw as? Double).map { Int($0) } ?? 0
            // SPEC-496 — a §B0-scoped Select: nothing to pick is satisfied; fewer rendered options
            // than the minimum lowers the minimum to what can actually be picked.
            switch marker(block) {
            case "empty_in_scope": continue
            case "scoped": minimum = min(minimum, block.field_options?.count ?? 0)
            default: break
            }
            guard minimum > 0 else { continue }
            let fieldId = block.field_id ?? block.id
            let count = (inputValues[fieldId] as? [Any])?.count ?? 0
            if count < minimum { return (false, fieldId) }
        }

        for block in blocks where block.field_required == true {
            if block.type == .summary_screen { continue } // see above — per-stat, never block-level
            // SPEC-496 — a required §B0-scoped Select that renders 0 options is satisfied.
            if marker(block) == "empty_in_scope" { continue }
            let fieldId = block.field_id ?? block.id
            let value = inputValues[fieldId]
            if value == nil { return (false, fieldId) }
            if let str = value as? String, str.isEmpty { return (false, fieldId) }
            if let dict = value as? [String: Any], dict.isEmpty { return (false, fieldId) }
            // Multi-select / chips write `[selectedValues]`; select-then-deselect-all leaves `[]`, which
            // must NOT satisfy a required field. Android's ContentBlockRenderer already blocks empty lists;
            // iOS lacked this branch and advanced past a required question with zero selections.
            if let arr = value as? [Any], arr.isEmpty { return (false, fieldId) }
            // Device QA (2026-08-04, s1) — a required `agreement`/consent checkbox is satisfied
            // ONLY when checked; an unchecked box reports a non-nil `false` that would otherwise slip
            // past the gate. Scoped to `.agreement` so pre-existing required `input_toggle`/`toggle`
            // fields keep their behavior. Parity with Android's `is Boolean` branch.
            if block.type == .agreement, let b = value as? Bool, b == false { return (false, fieldId) }
        }
        return (true, nil)
    }
}

// MARK: - Element-interaction fold (SPEC-419 STEP-2)

/// Key-level merge of new per-block `field_config` patches over existing overrides (override wins).
/// Never blind-replaces a block's override bag — merges key by key.
func mergeFieldConfigOverrides(_ current: [String: [String: Any]], with patches: [String: [String: Any]]) -> [String: [String: Any]] {
    var out = current
    for (id, patch) in patches {
        out[id, default: [:]].merge(patch) { _, new in new }
    }
    return out
}

/// Pure composition of the flow-host + step-scope interaction fold: awaits the delegate, applies the
/// `ElementInteractionResult` to `inputValues`, key-level-merges field_config overrides, and reports whether
/// an advance was requested. The production path is `OnboardingStepRouter.handleInteract` →
/// `InteractionCoordinator` → `applyInteractionReply` (SPEC-496 §5b); this mirror exists so the composed
/// fold is unit-testable without a live SwiftUI host.
func fireElementInteraction(
    delegate: AppDNAOnboardingDelegate?,
    flowId: String,
    stepId: String,
    blockId: String,
    action: String,
    value: String?,
    inputValues: [String: Any],
    overrides: [String: [String: Any]]
) async -> (inputValues: [String: Any], overrides: [String: [String: Any]], advanceRequested: Bool) {
    guard let result = await delegate?.onElementInteraction(
        flowId: flowId,
        stepId: stepId,
        blockId: blockId,
        action: action,
        value: value,
        inputValues: inputValues
    ) else {
        return (inputValues, overrides, false)
    }
    let applied = applyInteractionResult(result, inputValues: inputValues)
    // SPEC-496 §5b C4.1 — the raw patches onto the values handed in, exactly as the step scope applies
    // them to its CURRENT values; never `applied.inputValues` (the tap-time snapshot merge).
    var current = inputValues
    for (k, v) in applied.inputValuePatches ?? [:] { current[k] = v }
    let mergedOverrides = mergeFieldConfigOverrides(overrides, with: applied.fieldConfigOverrides)
    return (current, mergedOverrides, applied.advance)
}

// MARK: - Social login step data

/// The step data a `social_login` tap hands to `onNext`: the step's input values, then the SDK's own
/// `provider` and `action` keys LAST, so an input field whose id happens to be `action` or `provider`
/// cannot override them. It used to be the other way round — an input named `action` replaced
/// `"social_login"`, which also took the tap out of the sign-in gate (`AuthActionPolicy`) and the
/// bridges' 120 s sign-in floor. Android builds the map in the same order.
enum SocialLoginStepData {
    static func build(provider: String?, inputValues: [String: Any]) -> [String: Any] {
        var data = inputValues
        data["provider"] = provider ?? "unknown"
        data["action"] = "social_login"
        return data
    }
}

// MARK: - Auth Action Policy

/// Single source of truth for which button actions REQUIRE an
/// `AppDNAOnboardingDelegate` to be set before the SDK will advance the user
/// past a credential-collection step. If a host fires one of these actions
/// without a delegate, `handleStepCompleted` logs a warning and stays on the
/// step — credentials never silently flow into `responses` without a side
/// effect (sign in, register, send OTP, etc.) actually being performed.
enum AuthActionPolicy {
    static let delegateRequiredActions: Set<String> = [
        // existing
        "social_login",
        // entry
        "login", "register", "reset_password", "magic_link",
        "request_otp", "verify_otp", "verify_email", "resend_verification",
        "enable_biometric",
        "email_login",
        // lifecycle
        "logout", "change_password", "set_new_password",
        "delete_account", "update_profile",
    ]

    /// The actions a wrapper bridge must wait at least
    /// `StepAdvanceResult.authBridgeTimeout` for. On iOS this is exactly the delegate-required set
    /// (which already includes `social_login`); `check:auth-action-parity` pins this definition.
    static let bridgeFloorActions = delegateRequiredActions
}

// MARK: - Secret redaction

/// 🔴 THE USER'S PASSWORD WAS WRITTEN TO PLAINTEXT `UserDefaults` — ON EVERY LOGIN ATTEMPT.
///
/// `handleStepCompleted` did `responses[step.id] = data` and then persisted the whole map to
/// `SessionDataStore` (backed by `UserDefaults`). For a `login` / `register` / `change_password` step,
/// `data` is the field map the user just typed — **including the password**. It landed on disk before
/// the delegate had even been asked to authenticate, and it stayed there.
///
/// Worse than the storage: `TemplateEngine.buildContext()` feeds the onboarding-responses bucket into
/// the `{{…}}` namespace. That is the same path that rendered one user's name into another user's
/// paywall copy — so a password was one `{{onboarding.password}}` away from being *displayed*.
///
/// The delegate still receives the credentials in full: `onBeforeStepAdvance` is handed the raw
/// `stepData`, which is how a host signs the user in. What it does NOT get is a copy on disk.
///
/// The discriminator is STRUCTURAL, from the console's own schema (`flow.schema.ts`): a content block
/// of type `input_password`, or a form field of type `password`. It is deliberately NOT a name match on
/// the field id — `field_id.contains("password")` would miss `pwd` and would happily redact a field
/// called `password_hint`, and a substring oracle is exactly the kind of guess this codebase has been
/// bitten by before.
enum AuthSecretRedactor {

    /// Block/field types whose VALUE is a secret and must never be persisted or templated.
    /// Both are typed enums, so a new secret-bearing type cannot be added as a bare string.
    ///
    /// 🔴 `otp_input` WAS MISSING. A `verify_otp` step captures the one-time code in an `otp_input`
    /// block, which writes it into the SAME `inputValues` map — so the code (and, via the auth-action
    /// payload, the recipient phone/email) shipped to `selection_data` → `raw.sdk_events`, unredacted.
    /// A one-time code is a credential; it belongs here beside `input_password`.
    static let secretBlockTypes: Set<ContentBlockType> = [.input_password, .otp_input]
    static let secretFieldTypes: Set<FormFieldType> = [.password]

    /// The field ids on this step whose values are secrets — INCLUDING nested blocks.
    ///
    /// 🔴 THE ORIGINAL SCAN WAS TOP-LEVEL ONLY, so a password inside a `row` / `stack` (its
    /// `children` / `stack_children`) sailed past it. The renderers recurse into nested blocks and write
    /// every input into the SAME shared `inputValues` map regardless of depth, and `flow.schema.ts`
    /// validates content blocks as `z.array(z.unknown())` — nothing rejects a nested `input_password`
    /// from the AI generator, an import, a template, or a direct API POST. So "structural for flat
    /// layouts only" was not structural. This walks the whole tree.
    static func secretFieldIds(in step: OnboardingStep) -> Set<String> {
        var ids: Set<String> = []
        collectSecretBlockIds(step.config.content_blocks ?? [], into: &ids)
        for field in step.config.fields ?? [] where secretFieldTypes.contains(field.type) {
            ids.insert(field.id)
        }
        return ids
    }

    private static func collectSecretBlockIds(_ blocks: [ContentBlock], into ids: inout Set<String>) {
        for block in blocks {
            if secretBlockTypes.contains(block.type) {
                ids.insert(block.field_id ?? block.id)
            }
            if let children = block.children { collectSecretBlockIds(children, into: &ids) }
            if let stackChildren = block.stack_children { collectSecretBlockIds(stackChildren, into: &ids) }
        }
    }

    /// `data` with every secret value removed. The keys are dropped entirely rather than masked: a
    /// `"password": "••••"` in the template namespace is still a lie a host could render.
    static func redact(_ data: [String: Any]?, in step: OnboardingStep) -> [String: Any]? {
        guard let data else { return nil }
        let secrets = secretFieldIds(in: step)
        guard !secrets.isEmpty else { return data }
        return data.filter { !secrets.contains($0.key) }
    }
}

// MARK: - OTP Channel Resolver

/// Pure resolver for the OTP delivery channel used by `request_otp` /
/// `verify_otp` buttons. Extracted from the view so unit tests can verify
/// the explicit-channel + auto-detect logic without instantiating SwiftUI.
enum OtpChannelResolver {
    /// Resolution order:
    ///   1) Explicit `actionValue` from the button config
    ///      (`"sms" | "email" | "whatsapp" | "voice"`, case-insensitive)
    ///   2) Auto-detect: step has exactly one phone-typed input → `"sms"`;
    ///      exactly one email-typed input → `"email"`
    ///   3) `nil` — ambiguous (both or neither). Host must fail explicitly
    ///      rather than guess.
    /// Recipient is derived from the matching `inputValues` field when present.
    static func resolve(
        actionValue: String?,
        blocks: [ContentBlock],
        inputValues: [String: Any],
    ) -> (channel: String?, recipient: String?) {
        let supported: Set<String> = ["sms", "email", "whatsapp", "voice"]
        let phoneBlocks = blocks.filter { $0.type == .input_phone }
        let emailBlocks = blocks.filter { $0.type == .input_email }

        if let raw = actionValue?.lowercased(), supported.contains(raw) {
            let recipient: String?
            switch raw {
            case "sms", "whatsapp", "voice":
                if let id = phoneBlocks.first?.field_id ?? phoneBlocks.first?.id {
                    recipient = inputValues[id] as? String
                } else {
                    recipient = nil
                }
            case "email":
                if let id = emailBlocks.first?.field_id ?? emailBlocks.first?.id {
                    recipient = inputValues[id] as? String
                } else {
                    recipient = nil
                }
            default:
                recipient = nil
            }
            return (raw, recipient)
        }

        if phoneBlocks.count == 1 && emailBlocks.isEmpty {
            let id = phoneBlocks[0].field_id ?? phoneBlocks[0].id
            return ("sms", inputValues[id] as? String)
        }
        if emailBlocks.count == 1 && phoneBlocks.isEmpty {
            let id = emailBlocks[0].field_id ?? emailBlocks[0].id
            return ("email", inputValues[id] as? String)
        }
        return (nil, nil)
    }
}

// MARK: - Paywall Bridge for Onboarding Flow Continuation

/// SPEC-203 follow-up — bridges three distinct paywall outcomes back
/// into the onboarding flow:
///   - purchase completed (→ `onPurchased`, routed via on_success_target)
///   - purchase attempted but failed / declined (→ `onFailed`, routed
///     via on_fail_target; default = do nothing, paywall stays visible)
///   - user tapped X without a purchase attempt (→ `onDismissed`,
///     routed via on_dismiss_target / legacy on_dismiss enum)
///
/// Paywall SDK already emits `onPaywallPurchaseFailed` — previous
/// onboarding bridge simply didn't wire it. Onboarding used to collapse
/// all three into "complete flow" which swallowed real user intent.
/// SPEC-400 Phase 1 — 12-method forwarding bridge.
///
/// Forwards every `AppDNAPaywallDelegate` callback to the host's
/// registered global delegate at `AppDNA.paywall.delegate` BEFORE
/// running the onboarding chain routing. The host delegate is read
/// fresh on every callback (never captured at init) so a host that
/// registers `AppDNA.paywall.setDelegate(...)` AFTER the onboarding
/// flow is presented still receives forwards.
///
/// Routing side-effects (`didPurchase`, `didFail`, `onPurchased()`,
/// `onFailed()`, `onDismissedWithoutPurchase()`) preserve the existing
/// `on_success_target` / `on_fail_target` / `on_dismiss_target`
/// chaining exactly. Onboarding routing must NOT depend on host
/// delegate availability.
///
/// Each instance handles exactly one paywall presentation; flags
/// initialize to false on every fresh init so no manual reset is
/// needed between paywall opens.
private class OnboardingPaywallBridge: AppDNAPaywallDelegate {
    private let onPurchased: () -> Void
    private let onFailed: () -> Void
    private let onDismissedWithoutPurchase: () -> Void
    // Per-instance state (one bridge per paywall presentation).
    private var didPurchase = false
    private var didFail = false

    init(
        onPurchased: @escaping () -> Void,
        onFailed: @escaping () -> Void,
        onDismissedWithoutPurchase: @escaping () -> Void
    ) {
        self.onPurchased = onPurchased
        self.onFailed = onFailed
        self.onDismissedWithoutPurchase = onDismissedWithoutPurchase
    }

    // MARK: - AppDNAPaywallDelegate (forward then route)

    func onPaywallPresented(paywallId: String) {
        forwardOnMain { $0.onPaywallPresented(paywallId: paywallId) }
    }

    func onPaywallAction(paywallId: String, action: PaywallAction) {
        forwardOnMain { $0.onPaywallAction(paywallId: paywallId, action: action) }
    }

    func onPaywallPurchaseStarted(paywallId: String, productId: String) {
        forwardOnMain { $0.onPaywallPurchaseStarted(paywallId: paywallId, productId: productId) }
    }

    func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
        forwardOnMain { $0.onPaywallPurchaseCompleted(paywallId: paywallId, productId: productId, transaction: transaction) }
        didPurchase = true
    }

    func onPaywallPurchaseFailed(paywallId: String, error: Error) {
        // Legacy entry point (direct callers). Derives the discriminator so the host always receives
        // the typed callback, whichever entry point fired.
        onPaywallPurchaseFailed(
            paywallId: paywallId,
            error: error,
            errorType: billingErrorType(error),
            productId: nil
        )
    }

    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String) {
        onPaywallPurchaseFailed(paywallId: paywallId, error: error, errorType: errorType, productId: nil)
    }

    /// The full variant the SDK actually calls. The bridge MUST override this one: the protocol's
    /// default would forward down to the three-argument method and drop `productId` on the floor
    /// before it ever reached the host — the exact bug this parameter exists to fix.
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
        forwardOnMain {
            $0.onPaywallPurchaseFailed(
                paywallId: paywallId,
                error: error,
                errorType: errorType,
                productId: productId
            )
        }
        // Paywall stays on screen (iOS convention — error toast, retry
        // allowed). Mark the intent; the onboarding router decides what
        // to do if `on_fail_target` requests navigating away.
        didFail = true
        onFailed()
    }

    func onPaywallDismissed(paywallId: String) {
        forwardOnMain { $0.onPaywallDismissed(paywallId: paywallId) }
        if didPurchase {
            onPurchased()
        } else {
            // A failed purchase is NOT the same as a dismiss. If the
            // paywall stays visible after a failure and the user later
            // taps X, they've now dismissed — route the dismiss branch.
            onDismissedWithoutPurchase()
        }
    }

    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void) {
        // Synchronous forward — the SDK depends on the completion
        // handler being called. If the host hasn't registered a
        // delegate, fall through to the protocol's default behavior
        // (completion(false)) so standalone and onboarding-embedded
        // paywalls behave identically.
        if let host = AppDNA.paywall.delegate {
            host.onPromoCodeSubmit(paywallId: paywallId, code: code, completion: completion)
        } else {
            completion(false)
        }
    }

    func onPostPurchaseDeepLink(paywallId: String, url: String) {
        forwardOnMain { $0.onPostPurchaseDeepLink(paywallId: paywallId, url: url) }
    }

    func onPostPurchaseNextStep(paywallId: String) {
        forwardOnMain { $0.onPostPurchaseNextStep(paywallId: paywallId) }
    }

    func onPaywallRestoreStarted(paywallId: String) {
        forwardOnMain { $0.onPaywallRestoreStarted(paywallId: paywallId) }
    }

    func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) {
        forwardOnMain { $0.onPaywallRestoreCompleted(paywallId: paywallId, productIds: productIds) }
        // SPEC-401 Fix 1B — treat a non-empty restore as equivalent to a
        // successful purchase so the subsequent dismiss routes via
        // on_success instead of on_dismiss. Mirrors the existing
        // onPaywallPurchaseCompleted pattern at line 1741: just flip the
        // flag here, let the dismiss path call onPurchased() once.
        // SPEC-401 R1 audit: do NOT call onPurchased() directly here —
        // PaywallManager auto-dismiss (Fix 1C) will fire
        // onPaywallDismissed which reads didPurchase and routes once.
        // Calling onPurchased() here too would route twice. Empty
        // productIds means "restore call succeeded but found no
        // entitlements" — leave didPurchase=false.
        if !productIds.isEmpty {
            didPurchase = true
        }
    }

    func onPaywallRestoreFailed(paywallId: String, error: Error) {
        forwardOnMain { $0.onPaywallRestoreFailed(paywallId: paywallId, error: error) }
    }

    /// Read `AppDNA.paywall.delegate` fresh on every call (no init-time
    /// capture). Reading the slot is performed on the main thread for
    /// both branches to avoid a data race against `setDelegate(...)`
    /// (which is `internal var`, mutable, non-atomic).
    private func forwardOnMain(_ block: @escaping (AppDNAPaywallDelegate) -> Void) {
        if Thread.isMainThread {
            if let host = AppDNA.paywall.delegate { block(host) }
        } else {
            DispatchQueue.main.async {
                if let host = AppDNA.paywall.delegate { block(host) }
            }
        }
    }
}

// EPIC-2 — flow-level continuous progress bar. A custom bar (replaces the fixed 4pt rectangle) so
// progress_height honours any thickness, plus an optional multi-color gradient fill
// (progress_gradient_colors). Mirrors Android ContinuousProgressBar; rendered standalone so the
// SPEC-419 visual-snapshot harness can capture it.
struct ContinuousProgressBar: View {
    let progress: CGFloat
    let color: Color
    let trackColor: Color
    let height: CGFloat
    var gradientColors: [Color]? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(trackColor)
                    .frame(height: height)
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(fillStyle)
                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: height)
            }
        }
        .frame(height: height)
    }

    private var fillStyle: AnyShapeStyle {
        if let g = gradientColors, g.count >= 2 {
            return AnyShapeStyle(LinearGradient(colors: g, startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(color)
    }
}

// EPIC-2 — nav-bar glyph (custom back arrow / close ✕) as a single Text. Mirrors Android NavGlyph;
// rendered standalone so the custom-glyph + back⇄X switch render is snapshot-testable.
struct NavGlyph: View {
    let glyph: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Text(glyph)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(color)
    }
}

// MARK: - Webhook response parsing

/// Pure translation of a step webhook's JSON body into a `StepAdvanceResult`. Extracted from
/// `OnboardingFlowHost.parseWebhookResponse` so the contract (which server `action` produces which
/// advance result, and which error text wins) is testable without a live SwiftUI host + URLSession.
enum WebhookResponseParser {
    static func parse(_ data: Data, errorText: String?) -> StepAdvanceResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return .block(message: errorText ?? "Invalid server response.")
        }

        let responseData = json["data"] as? [String: Any]
        let message = json["message"] as? String
        let targetStepId = json["target_step_id"] as? String

        switch action {
        case "proceed":
            if let responseData {
                return .proceedWithData(responseData)
            }
            return .proceed

        case "proceed_with_data":
            return .proceedWithData(responseData ?? [:])

        case "block":
            return .block(message: message ?? errorText ?? "Request blocked by server.")

        case "stay":
            // Server can return action: "stay" to keep the user on the step.
            // Optional `message` field renders in success styling. Empty/nil message
            // is silent (server-side handler did its work; SDK shows nothing).
            return .stay(message: message)

        case "skip_to":
            guard let targetStepId else {
                return .proceed
            }
            if let responseData {
                return .skipToWithData(stepId: targetStepId, data: responseData)
            }
            return .skipTo(stepId: targetStepId)

        default:
            return .proceed
        }
    }
}

// MARK: - Step advance result naming

/// The analytics name of a `StepAdvanceResult`. Extracted so the wire names emitted on
/// `onboarding_hook_*` events are pinned by a test — they are consumed by BigQuery and cannot drift.
enum StepAdvanceResultNaming {
    static func name(_ result: StepAdvanceResult) -> String {
        switch result {
        case .proceed: return "proceed"
        case .proceedWithData: return "proceed_with_data"
        case .block: return "block"
        case .stay: return "stay"
        case .skipTo: return "skip_to"
        case .skipToWithData: return "skip_to"
        }
    }
}

// MARK: - Step config override merge (SPEC-083)

/// Field-by-field merge of a host-supplied `StepConfigOverride` onto a step's authored `StepConfig`.
/// Extracted from the view so the "which fields an override may replace" contract is testable — an
/// override that silently stops applying is otherwise only visible on a device.
// `withOverrideTimeout` moved to HostData/HostDataPendingCoordinator.swift (SPEC-496 §B0 rewrite).

enum StepConfigOverrideMerger {
    /// 🔴 NON-DESTRUCTIVE: copy the authored config, then assign only the fields the override NAMES.
    ///
    /// This used to REBUILD a `StepConfig` through its 26-parameter memberwise init, forwarding every
    /// field by hand — and it forgot `chat_config`. Forgetting a field in a rebuild does not fail to
    /// compile and does not log; it DELETES the field. So any host with an override on an
    /// `interactive_chat` step lost the authored chat background and the renderer fell back to a
    /// hardcoded `#0F172A`.
    ///
    /// And on the React Native path there was no such thing as "a host with no override": the wrapper's
    /// veto decoder turned the `__appdna_unhandled` sentinel — the reply meaning "this host registered
    /// no `onBeforeStepRender`" — into a real, all-nil `StepConfigOverride`. Every step of every flow
    /// therefore ran through this merger, and every `interactive_chat` step lost its background, in the
    /// DEFAULT integration.
    ///
    /// A merger that lists fields can only ever be as correct as the last person to add one remembered
    /// to be. This one cannot forget: `StepConfig`'s fields are `var`, and anything not assigned below
    /// is carried over by the copy.
    static func apply(_ override: StepConfigOverride?, to config: StepConfig) -> StepConfig {
        guard let override else { return config }
        var merged = config
        if let title = override.title { merged.title = title }
        if let subtitle = override.subtitle { merged.subtitle = subtitle }
        if let ctaText = override.ctaText { merged.cta_text = ctaText }
        // Only replaced when the override actually carries defaults. The rebuild assigned this
        // unconditionally, so an override that set ONLY a title also wiped a previous override's
        // field defaults.
        if let fieldDefaults = override.fieldDefaults {
            merged.field_defaults = fieldDefaults.mapValues { AnyCodable($0) }
        }
        // SPEC-448 §B — host-supplied options.
        //
        // ⚠️ This is NOT another assignment like the four above. Those replace flat scalars on the
        // step; options live at `content_blocks[i].field_options`, one level down inside an array.
        // So it locates each named block by id and rebuilds THAT block's option list, leaving every
        // sibling block untouched. A merge that rebuilt the array from only the named blocks would
        // silently delete the rest of the step — invisible until an author noticed a missing block,
        // which is exactly why the fixture asserts the untouched siblings survive.
        //
        // SPEC-451 adds a second block-level override in the same pass. They compose: a step may
        // legitimately have host-supplied options on one block and a host-supplied route on
        // another, so this applies both rather than choosing between them.
        let hasBlockOverrides = !(override.fieldOptions?.isEmpty ?? true) || !(override.mapRoutes?.isEmpty ?? true)
        if hasBlockOverrides, let blocks = merged.content_blocks {
            merged.content_blocks = blocks.map { block in
                var copy = block
                if let replacement = override.fieldOptions?[block.id] {
                    copy.field_options = replacement
                }
                // SPEC-451 — the host's route is written into `field_config` under the SAME keys
                // the console authors, so the renderer has exactly one code path and a delegate
                // route cannot render differently from an authored one.
                if let route = override.mapRoutes?[block.id] {
                    var cfg = copy.field_config ?? [:]
                    if let polyline = route.polyline {
                        cfg["map_route_polyline"] = AnyCodable(polyline)
                        // A host that answered with a route outranks a `{{token}}` the author wired
                        // as the fallback. Clearing it here is what makes that ordering true —
                        // leaving it would let a stale variable win over a live answer.
                        cfg["map_route_variable"] = AnyCodable("")
                    }
                    if !route.stops.isEmpty {
                        cfg["map_stops"] = AnyCodable(route.stops.map { s -> [String: Any] in
                            var m: [String: Any] = ["lat": s.lat, "lng": s.lng]
                            if let t = s.title { m["title"] = t }
                            return m
                        })
                    }
                    copy.field_config = cfg
                }
                return copy
            }
        }
        return merged
    }
}

// MARK: - Paywall trigger skip resolver (SPEC-401 / SPEC-403)

/// Decides whether a `paywall_trigger` node presents its paywall or auto-skips, and where an
/// auto-skip routes. Extracted from `presentPaywallTrigger`'s Task closure — the closure is
/// unreachable from a test, which is why the SPEC-403 chain was previously covered by a test that
/// re-implemented the ternaries instead of calling them.
enum PaywallTriggerSkipResolver {
    /// A trigger field is "set" only when it is a non-empty string; the console writes "" for cleared
    /// dropdowns, and "" must fall through the chain rather than route to a nonexistent node.
    static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Default `true` matches the SDK contract: paywalls auto-skip for already-subscribed users
    /// unless the author explicitly opts out (upsell paywalls). Older flows that never authored the
    /// field resolve to nil → true.
    static func skipIfSubscribed(triggerData: [String: Any]?) -> Bool {
        triggerData?["skip_if_subscribed"] as? Bool ?? true
    }

    /// `skipTarget` is the SPEC-403 resolver chain (on_subscribed_skip_target → on_success_target →
    /// nil, i.e. follow the legacy "continue" edge). It is resolved regardless of `present` because
    /// the SPEC-404 runtime-lock skip routes through the same chain without consulting the
    /// subscription state.
    static func decision(
        triggerData: [String: Any]?,
        hasActiveSubscription: Bool
    ) -> (present: Bool, skipTarget: String?, reason: String?) {
        let target = nonEmpty(triggerData?["on_subscribed_skip_target"])
            ?? nonEmpty(triggerData?["on_success_target"])
        if skipIfSubscribed(triggerData: triggerData) && hasActiveSubscription {
            return (false, target, "user_already_subscribed")
        }
        return (true, target, nil)
    }

    /// Legacy `on_dismiss` enum → routeOutcome default behavior.
    static func legacyDismissDefault(_ legacyDismiss: String?) -> String {
        switch legacyDismiss {
        case "block": return "complete_flow"
        case "skip_to_end": return "complete_flow"
        case "continue": return "continue"
        default: return "continue"
        }
    }
}
