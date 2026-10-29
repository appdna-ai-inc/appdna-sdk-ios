import SwiftUI

/// Question step: title, option grid, single/multi select, CTA.
struct QuestionStepView: View {
    let config: StepConfig
    let onNext: ([String: Any]?) -> Void

    @State private var selectedIds: Set<String>

    /// `savedResponses` is the step's stored answer (`responses[step.id]`). A user who comes back to
    /// an answered question sees the option or options they chose, highlighted.
    init(config: StepConfig, onNext: @escaping ([String: Any]?) -> Void, savedResponses: [String: Any]? = nil) {
        self.config = config
        self.onNext = onNext
        _selectedIds = State(initialValue: Set(Self.restoredSelection(savedResponses, config: config)))
    }

    /// The options a stored answer chose, in the order it stored them: only ids this step still
    /// offers, and only the first of them for a single-select question.
    static func restoredSelection(_ saved: [String: Any]?, config: StepConfig) -> [String] {
        let raw: [String]
        switch saved?["selected"] {
        case let list as [Any]: raw = list.compactMap { $0 as? String }
        case let one as String: raw = [one]
        default: raw = []
        }
        let offered = Set((config.options ?? []).compactMap(\.id))
        var seen = Set<String>()
        let kept = raw.filter { offered.contains($0) && seen.insert($0).inserted }
        return config.selection_mode == .multi ? kept : Array(kept.prefix(1))
    }

    private var isMultiSelect: Bool {
        config.selection_mode == .multi
    }

    // MARK: - Configurable colors from element_style

    /// Accent color used for selected state (border, fill tint, CTA).
    private var accentColor: Color {
        if let hex = config.element_style?.border?.color { return Color(hex: hex) }
        if let hex = config.element_style?.background?.color { return Color(hex: hex) }
        return Color(hex: (AppDNA.brandAccentHex ?? "#6366F1"))
    }

    /// Background color for selected option cards — reads selection_style.background or falls back to accent at 15%.
    private var selectedBgColor: Color {
        if let hex = config.element_style?.shadow?.color { return Color(hex: hex) } // Reuse shadow.color as selected_bg
        return accentColor.opacity(0.15)
    }

    /// Background color for unselected option cards.
    private var optionBgColor: Color {
        if let hex = config.element_style?.background?.overlay { return Color(hex: hex) }
        if let hex = config.element_style?.background?.color { return Color(hex: hex).opacity(0.1) }
        return Color.white.opacity(0.08)
    }

    /// Border color for selected option cards.
    private var selectedBorderColor: Color {
        accentColor
    }

    /// Border color for unselected option cards.
    private var optionBorderColor: Color {
        if let hex = config.element_style?.border?.color { return Color(hex: hex).opacity(0.3) }
        return Color.white.opacity(0.15)
    }

    /// Text color for option labels (uses element_style text_style if set).
    private var optionTextColor: Color {
        if let hex = config.element_style?.textStyle?.color { return Color(hex: hex) }
        return .primary
    }

    var body: some View {
        VStack(spacing: 24) {
            if let title = config.title {
                Text(title.interpolated())
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
            }

            // Options grid — manual 2-column layout (LazyVGrid clips wrapped text)
            ScrollView {
                VStack(spacing: 12) {
                    let allOptions = config.options ?? []
                    let rowCount = (allOptions.count + 1) / 2
                    ForEach(0..<rowCount, id: \.self) { rowIdx in
                        HStack(spacing: 12) {
                            optionCard(allOptions[rowIdx * 2])
                            if rowIdx * 2 + 1 < allOptions.count {
                                optionCard(allOptions[rowIdx * 2 + 1])
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            // CTA
            Button {
                let data: [String: Any] = [
                    "selected": Array(selectedIds),
                    "selection_mode": isMultiSelect ? "multi" : "single",
                ]
                onNext(data)
            } label: {
                Text((config.cta_text ?? "Continue").interpolated())
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(selectedIds.isEmpty ? Color.gray : accentColor)
                    .cornerRadius(CGFloat(config.element_style?.corner_radius ?? 14))
            }
            .disabled(selectedIds.isEmpty)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Option card

    private func optionCard(_ option: QuestionOption) -> some View {
        let optId = option.id ?? UUID().uuidString
        let isSelected = selectedIds.contains(optId)
        let cornerRadius = CGFloat(config.element_style?.corner_radius ?? 12)

        return Button {
            if isMultiSelect {
                if isSelected {
                    selectedIds.remove(optId)
                } else {
                    selectedIds.insert(optId)
                }
            } else {
                selectedIds = [optId]
            }
        } label: {
            VStack(spacing: 8) {
                if let icon = option.icon {
                    Text(icon)
                        .font(.system(size: 32))
                }

                Text((option.label ?? "").interpolated())
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(optionTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let sub = option.subtitle, !sub.isEmpty {
                    Text(sub.interpolated())
                        .font(.caption)
                        .foregroundColor(optionTextColor.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isSelected ? selectedBgColor : optionBgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected ? selectedBorderColor : optionBorderColor, lineWidth: isSelected ? 2 : 1)
            )
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
