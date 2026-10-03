import SwiftUI

/// A SwiftUI view that renders a server-driven screen's sections inline.
/// Growth teams assign screens to named slots from the console; the SDK renders them here.
///
/// Usage:
/// ```swift
/// struct HomeView: View {
///     var body: some View {
///         VStack {
///             AppDNAScreenSlot("home_hero")
///             // ... app content ...
///             AppDNAScreenSlot("home_bottom")
///         }
///     }
/// }
/// ```
public struct AppDNAScreenSlot: View {
    let name: String
    @State private var screenConfig: ScreenConfig?
    @State private var isLoading = true
    @State private var isEmpty = false
    /// The slot name already loaded, so `onAppear` runs `loadSlotContent()` (which emits
    /// slot_registered/_rendered/_empty) ONCE per name — not on every SwiftUI re-appearance.
    @State private var loadedName: String?

    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        Group {
            if !AppDNA.isConsentGranted() {
                // Slots render nothing when consent denied
                EmptyView()
            } else if isLoading {
                placeholderView
            } else if let config = screenConfig {
                slotContent(config)
            } else if isEmpty {
                // AC-040c: Empty slot renders nothing
                EmptyView()
            }
        }
        .onAppear {
            // Match Android's `LaunchedEffect(name)` — load + emit telemetry ONCE per slot name, not on
            // every re-appearance (scroll back into view, nav return, tab switch). Bare `onAppear`
            // re-fired on each, re-emitting slot_registered/_rendered/_empty and inflating slot-impression
            // counts relative to Android.
            guard loadedName != name else { return }
            loadedName = name
            loadSlotContent()
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        // Shimmer placeholder while loading
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.1))
            .frame(height: 100)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }

    @ViewBuilder
    private func slotContent(_ config: ScreenConfig) -> some View {
        let slotConfig = config.slot_config
        let maxHeight = slotConfig?.max_height

        let context = SectionContext(
            screenId: config.id ?? "",
            onAction: { action in
                // Consult the host onScreenAction veto (+ async wrapper) before performing
                // a slot action, matching Android AppDNAScreenSlot + the full-screen path. Previously
                // slot actions bypassed the veto entirely, so a host returning false was ignored.
                ScreenManager.shared.dispatchSlotAction(action, screenId: config.id ?? "") {
                    handleSlotAction(action, config: config)
                }
            }
        )
        let contextHolder = ScreenContextHolder(context: context)

        VStack(spacing: CGFloat(config.layout?.spacing ?? 12)) {
            ForEach(config.sections ?? []) { section in
                SectionRegistry.shared.render(section: section, context: context)
                    .applySectionStyle(section.style)
            }
        }
        .frame(maxHeight: maxHeight.map { CGFloat($0) })
        .clipped()
        .onTapGesture {
            if slotConfig?.tap_to_expand == true || slotConfig?.presentation == "overlay" {
                ScreenPresenter.present(config: config, context: context)
            }
        }
    }

    private func loadSlotContent() {
        // Track slot registration
        AppDNA.track(event: "slot_registered", properties: [
            "slot_name": name,
            "platform": "ios",
        ])

        // Look up slot assignment from ScreenManager
        if let (screenId, config) = ScreenManager.shared.screenForSlot(name) {
            self.screenConfig = config
            self.isLoading = false

            AppDNA.track(event: "slot_rendered", properties: [
                "slot_name": name,
                "screen_id": screenId,
                "screen_name": config.name,
            ])
        } else {
            self.isEmpty = true
            self.isLoading = false

            AppDNA.track(event: "slot_empty", properties: [
                "slot_name": name,
            ])
        }
    }

    private func handleSlotAction(_ action: SectionAction, config: ScreenConfig) {
        switch action {
        case .dismiss:
            break // Can't dismiss inline content
        // Config-driven URLs — scheme-checked before they reach the OS.
        case .openURL(let url):
            if let url = URLSafety.sanitized(url) { UIApplication.shared.open(url) }
        case .deepLink(let url):
            if let url = URLSafety.sanitized(url) { UIApplication.shared.open(url) }
        case .showScreen(let id):
            ScreenManager.shared.showScreen(id)
        case .showPaywall(let id):
            if let paywallId = id { AppDNA.showPaywall(paywallId) }
        case .showSurvey(let id):
            // Parity with Android's slot handler (AppDNAScreenSlot.kt) — a slot button configured with
            // a showSurvey action did nothing on iOS (fell to `default`), while Android presented it.
            if let surveyId = id { AppDNA.showSurvey(surveyId) }
        default:
            break
        }
    }
}
