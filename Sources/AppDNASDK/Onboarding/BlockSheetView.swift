import SwiftUI

/// A bottom sheet of ordinary content blocks over the step: the engine behind an option's
/// `sheet_blocks` (`OptionBottomSheetView` wraps it) and the `add_widget` how-to (`howto_blocks_ios`;
/// `howto_blocks_android` is Android's, and iOS never draws it).
///
/// A sheet's buttons do exactly two things, plus one in an option sheet:
/// - `next` (Done; `continue` is its synonym) → `onDone`;
/// - `dismiss` (Close) → `onClose`;
/// - `link`, in an OPTION sheet only (`opensLinks`) → opens its URL in the in-app browser and keeps the
///   sheet open, exactly as a `link` button on a step does (and as Android always has: its option sheet
///   leaves `link` to the button itself).
///
/// EVERY button action inside the sheet is forwarded here — a `link`, a `refresh_step`, an
/// `add_widget`, a typo — and anything else is logged and ignored, so a how-to cannot open a
/// browser, refresh the step underneath or start a second attempt. The step's channels
/// (`appdnaWidgetAction`, `appdnaStepInteraction`) are cut off explicitly: SwiftUI's environment
/// reaches `.sheet` content, so without that a button in the sheet would act on the step.
struct BlockSheetView: View {
    /// What a button inside the sheet does.
    enum Route: Equatable { case done, close, openLink(URL), ignored }

    /// `opensLinks` is true for an option sheet and false for the `add_widget` how-to. A `link` with no
    /// URL, or one `URLSafety` refuses, does nothing.
    static func route(_ action: String, value: String? = nil, opensLinks: Bool = false) -> Route {
        switch action {
        case "next", "continue": return .done
        case "dismiss": return .close
        case "link" where opensLinks:
            // Scheme-checked before anything opens it, as Android's option sheet does (`URLSafety.sanitized`).
            guard let url = value.flatMap({ URLSafety.sanitized($0) }) else { return .ignored }
            return .openLink(url)
        default: return .ignored
        }
    }

    let blocks: [ContentBlock]
    /// The step's localisation, so `block.<id>.<field>` translations apply inside the sheet. Nil →
    /// authored text as-is (an option sheet has always drawn without it).
    let loc: ((String, String) -> String)?
    let onDone: () -> Void
    let onClose: () -> Void
    /// An option sheet opens a `link` button's URL; the `add_widget` how-to does not.
    var opensLinks: Bool = false
    /// The blocks came out of the raw host-data pass: they are already resolved, and the renderer must
    /// not re-scan them (only `sheet_step_paths` resolve here, against the sheet's own inputs).
    var rawResolved: Bool = false
    /// Whether the sheet's own text shows a Google answer's content, given the sheet's inputs — the
    /// sheet then draws Google's attribution itself, as the container that text is drawn in.
    var showsGoogleCredit: (([String: Any]) -> Bool)? = nil

    @State private var sheetToggles: [String: Bool] = [:]
    @State private var sheetInputs: [String: Any]

    /// What the sheet draws behind its content: the system sheet background (no fill of its own).
    static let backdrop: GoogleMapsAttribution.Backdrop = .plain(hex: nil)
    @SwiftUI.Environment(\.appdnaDeviceColorScheme) private var deviceScheme
    @SwiftUI.Environment(\.colorScheme) private var currentScheme

    /// `inputs`: the sheet's own inputs when it opens — empty in production; a render test seeds one.
    init(blocks: [ContentBlock], loc: ((String, String) -> String)?, onDone: @escaping () -> Void,
         onClose: @escaping () -> Void, rawResolved: Bool = false, inputs: [String: Any] = [:],
         showsGoogleCredit: (([String: Any]) -> Bool)? = nil, opensLinks: Bool = false) {
        self.blocks = blocks
        self.opensLinks = opensLinks
        self.loc = loc
        self.onDone = onDone
        self.onClose = onClose
        self.rawResolved = rawResolved
        self.showsGoogleCredit = showsGoogleCredit
        _sheetInputs = State(initialValue: inputs)
    }

    /// A button inside the sheet was tapped.
    func handle(_ action: String, _ value: String? = nil) {
        switch Self.route(action, value: value, opensLinks: opensLinks) {
        case .done: onDone()
        case .close: onClose()
        case .openLink(let url):
            // The step's own `link` path: the in-app browser over whatever is on top (here, the sheet).
            DispatchQueue.main.async { InAppBrowser.present(url: url) }
        case .ignored:
            Log.debug("[Onboarding] a sheet button with action \"\(action)\" does nothing inside a sheet — "
                + "only next / continue (Done), dismiss (Close) and, in an option sheet, link act there")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle.
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            ScrollView {
                ContentBlockRendererView(
                    blocks: blocks,
                    onAction: { action, value in handle(action, value) },
                    toggleValues: $sheetToggles,
                    loc: loc,
                    inputValues: $sheetInputs,
                    // A `refresh_step` button reaches `onInteract` when no step channel is set: it is
                    // forwarded like every other action, and does nothing here.
                    onInteract: { _, action, _ in handle(action) }
                )
                .environment(\.appdnaRawResolved, rawResolved)
                .environment(\.appdnaStepInteraction, nil)
                .environment(\.appdnaWidgetAction, nil)
                // The sheet is filled with the system background, whatever the step underneath
                // draws: a Google logo inside the sheet picks its variant from the sheet.
                .environment(\.googleAttributionBackdrop, Self.backdrop)
                .environment(\.colorScheme, deviceScheme ?? currentScheme)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            if showsGoogleCredit?(sheetInputs) == true {
                GoogleMapsTextAttribution(backdrop: Self.backdrop)
                    .padding(.bottom, 12)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
