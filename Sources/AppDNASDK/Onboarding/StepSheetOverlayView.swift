import SwiftUI

/**
 A sheet inside a step, drawn IN the step's own hierarchy (not `.sheet`): the step stays drawn under the
 scrim and gets no taps; the sheet sits at the bottom with its corner radius, drag indicator and height.
 The scrim colour, the height and the dismiss routing are the authored ones and identical to Android's
 `StepSheetOverlay`.

 The sheet's blocks go through the step's own renderer with the STEP's answer bindings, so what is ticked
 here is the step's answer at once. `onAction` receives each button's action and value; `onDismiss` a
 gesture (`swipe` / `scrim`) and returns whether it closed (false when the sheet is not dismissible).
 */
struct StepSheetOverlayView: View {
    let sheet: StepSheet
    let stepBackgroundHex: String?
    let gateBlocks: [ContentBlock]
    @Binding var toggleValues: [String: Bool]
    @Binding var inputValues: [String: Any]
    let loc: (String, String) -> String
    let responses: [String: Any]
    let hookData: [String: Any]?
    let stepId: String
    let onAction: (String, String?) -> Void
    let onDismiss: (String) -> Bool

    @State private var dragOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.9
            ZStack(alignment: .bottom) {
                Color(hex: sheet.scrim_color)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { _ = onDismiss("scrim") }
                    .accessibilityIdentifier("step-sheet-scrim")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Close")

                VStack(spacing: 0) {
                    if sheet.drag_indicator {
                        Capsule()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 36, height: 5)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("step-sheet-indicator")
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        ContentBlockRendererView(
                            blocks: sheet.content_blocks,
                            onAction: onAction,
                            toggleValues: $toggleValues,
                            loc: loc,
                            responses: responses,
                            hookData: hookData,
                            inputValues: $inputValues,
                            stepId: stepId,
                            gateBlocks: gateBlocks
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: StepSheetContentHeightKey.self, value: g.size.height)
                        })
                    }
                    .onPreferenceChange(StepSheetContentHeightKey.self) { contentHeight = $0 }
                    .frame(height: scrollHeight(maxH: maxH, fullHeight: geo.size.height))
                }
                .frame(maxWidth: .infinity)
                .background(
                    sheetBackground
                        .clipShape(RoundedCorners(radius: sheet.corner_radius, corners: [.topLeft, .topRight]))
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = max(0, $0.translation.height) }
                        .onEnded { value in
                            let past = value.translation.height > 120 || value.predictedEndTranslation.height > 260
                            if past, onDismiss("swipe") { dragOffset = 0; return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                        }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("step-sheet")
                .accessibilityLabel("step-sheet:\(sheet.id)")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var sheetBackground: Color {
        if let hex = sheet.background_color ?? stepBackgroundHex { return Color(hex: hex) }
        return Color(UIColor.systemBackground)
    }

    /// `fit` is as tall as the content (up to `large`), `medium` half the screen, `large` 90 %.
    private func scrollHeight(maxH: CGFloat, fullHeight: CGFloat) -> CGFloat {
        let chrome: CGFloat = sheet.drag_indicator ? 17 : 0
        switch sheet.height {
        case "medium": return max(0, fullHeight * 0.5 - chrome)
        case "large": return max(0, maxH - chrome)
        default: return min(max(contentHeight, 1), max(0, maxH - chrome))
        }
    }
}

private struct StepSheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Rounds only the given corners (the sheet's top two).
private struct RoundedCorners: Shape {
    let radius: Double
    let corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
