import SwiftUI

// MARK: - Three-Zone Step Layout
//
// Apple HIG pattern: ScrollView.safeAreaInset(edge: .bottom) for pinned CTA.
// Background uses .background() modifier, content stays in normal safe area.

struct ThreeZoneStepLayout: View {
    let blocks: [ContentBlock]
    let onAction: (_ action: String, _ actionValue: String?) -> Void
    @Binding var toggleValues: [String: Bool]
    var loc: ((String, String) -> String)? = nil
    var responses: [String: Any] = [:]
    var hookData: [String: Any]? = nil
    @Binding var inputValues: [String: Any]
    /// The presented step's id, so a `visibility_condition` naming a field on THIS step
    /// evaluates against what the control holds right now (`VisibilityScope`). Empty = no merge.
    var stepId: String = ""
    var currentStepIndex: Int = 0
    var totalSteps: Int = 1
    /// Fired by an interactive block; carries (blockId, action, value) to the step scope.
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }
    /// Per-block field_config overrides pushed by the host delegate, layered at render time.
    var fieldConfigOverrides: [String: [String: Any]] = [:]
    /// Per-block replacement options from a refresh interaction, threaded to the renderer.
    var fieldOptionsOverrides: [String: [InputOption]] = [:]
    /**
     WHAT A TAP ON CONTENT SHOULD DO, besides dismissing the keyboard.

     🔴 The tap-anywhere gesture lives on the renderer OUTSIDE this layout, and it only ever fired
     for a tap that MISSED the content — five device runs, three gesture shapes. The consumer was
     never the ScrollView: it is the `.contentShape(Rectangle()).onTapGesture` below, which exists
     to dismiss the keyboard and sits above everything the blocks carry.

     🔴 And the splash case — the one the issue is actually about, a screen that is only an image —
     takes the `onlyCenterContent` branch, which had NO tap handler of any kind. So the gesture
     could not have worked there however it was attached outside: there was nothing to attach to.

     Handing the step's action to the handler that already RECEIVES the tap is the fix, on both
     branches. The default is a no-op, so a step that does not ask for it behaves as before.
     */
    var onContentTap: () -> Void = {}
    /// Raw-resolved block ids and the step's ONE layered list (consent-CTA gate).
    var rawResolvedIds: Set<String> = []
    var gateBlocks: [ContentBlock]? = nil

    /// Scroll offset tracked for collapse_on_scroll blocks (Sprint 7).
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        let visible = blocks.filter {
            evaluateVisibilityCondition($0.visibility_condition, responses: responses, hookData: hookData,
                                        stepId: stepId, stepInputs: inputValues)
                // `empty_state.mode == hidden` hides the block (raw-pass blocks only).
                && !OnboardingStepPipeline.isHiddenByEmptyState($0, rawResolved: rawResolvedIds.contains($0.id))
        }
        let (topBlocks, centerBlocks, bottomBlocks) = Self.partitionBlocks(visible)
        let onlyCenterContent = topBlocks.isEmpty && !centerBlocks.isEmpty

        Group {
            if onlyCenterContent {
                // Only center content — vertically centre it WHEN IT FITS, and scroll from the top
                // when it does not.
                //
                // 🔴 This branch was a bare `VStack { Spacer(); content; Spacer() }` at
                // `maxHeight: .infinity`, with no ScrollView. It was written for the small case the
                // comment names (a loading spinner), and it is correct for that. But a step whose
                // blocks all sit in the CENTER zone takes this branch too — a cross-sell screen,
                // for instance — and once that content is taller than the viewport the Spacers push
                // its top off-screen with nothing to scroll: "half the screen's content offset
                // toward the bottom", on every path that reaches the screen.
                //
                // `minHeight: geo.size.height` inside a ScrollView is the standard SwiftUI shape
                // for this: short content still centres exactly as before (the VStack is stretched
                // to the viewport and the Spacers split the slack), and tall content grows past it
                // and scrolls from the top instead of being centred into the void.
                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            zoneRenderer(blocks: centerBlocks)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        // A splash is only centre content, and this branch had no tap
                        // handler at all. The Spacers are part of the shape, so a tap above or
                        // below the image counts as a tap on the screen, which is what an author
                        // turning on "tap anywhere" means.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            onContentTap()
                        }
                    }
                }
            } else {
                // Normal: top content scrollable, center below it
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if !topBlocks.isEmpty {
                            zoneRenderer(blocks: topBlocks, scrollOffset: scrollOffset)
                                .padding(.top, 16)
                        }
                        if !centerBlocks.isEmpty {
                            zoneRenderer(blocks: centerBlocks, scrollOffset: scrollOffset)
                                .padding(.top, 20)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        // This handler is what a tap ON CONTENT reaches; the renderer's
                        // own gesture only ever saw the taps that missed it.
                        onContentTap()
                    }
                }
                .coordinateSpace(name: "stepScroll")
                // Scroll offset tracker as overlay — doesn't participate in
                // VStack layout, so it can't push content or interfere with
                // keyboard avoidance scroll positioning.
                .overlay(alignment: .top) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPrefKey.self,
                            value: -geo.frame(in: .named("stepScroll")).minY
                        )
                    }
                    .frame(height: 0)
                }
                .onPreferenceChange(ScrollOffsetPrefKey.self) { value in
                    scrollOffset = value
                }
                .scrollDismissesKeyboardCompat()
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !bottomBlocks.isEmpty {
                VStack(spacing: 8) {
                    zoneRenderer(blocks: bottomBlocks)
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func zoneRenderer(blocks: [ContentBlock], scrollOffset: CGFloat = 0) -> some View {
        ContentBlockRendererView(
            blocks: blocks,
            onAction: onAction,
            toggleValues: $toggleValues,
            loc: loc,
            responses: responses,
            hookData: hookData,
            inputValues: $inputValues,
            stepId: stepId,
            currentStepIndex: currentStepIndex,
            totalSteps: totalSteps,
            isZoneManaged: true,
            scrollOffset: scrollOffset,
            onInteract: onInteract,
            fieldConfigOverrides: fieldConfigOverrides,
            fieldOptionsOverrides: fieldOptionsOverrides,
            rawResolvedIds: rawResolvedIds,
            gateBlocks: gateBlocks ?? blocks
        )
        // Use ~8% of screen width for responsive margins across all devices
        // The ONE definition of the step's horizontal inset, shared with the full-bleed modifier
        // that has to cancel it. A constant there and a formula here is how a background
        // "reaching the screen edges" stopped eleven points short.
        .padding(.horizontal, CGFloat(BlockFullBleed.stepHorizontalInset(screenWidth: UIScreen.main.bounds.width)))
    }

    static func partitionBlocks(_ blocks: [ContentBlock]) -> (top: [ContentBlock], center: [ContentBlock], bottom: [ContentBlock]) {
        var top: [ContentBlock] = []
        var center: [ContentBlock] = []
        var bottom: [ContentBlock] = []
        for block in blocks {
            let effectiveZone = block.zone ?? block.vertical_align ?? "top"
            switch effectiveZone {
            case "center": center.append(block)
            case "bottom": bottom.append(block)
            default: top.append(block)
            }
        }
        return (top, center, bottom)
    }
}

// MARK: - Scroll offset tracking

private struct ScrollOffsetPrefKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
