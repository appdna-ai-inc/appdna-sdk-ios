import SwiftUI
import MapKit
import PhotosUI
// MARK: - Form Input Block Views (SPEC-089d Phase 3: AC-040 through AC-053)

/// Helper view to render a form field label above the input control.
struct FormFieldLabelView: View {
    let block: ContentBlock

    var body: some View {
        // SPEC-439 (#546) — `label_position: "hidden"` was IGNORED here, so a label the
        // author hid in the console still rendered on device. The console has offered this
        // control for months and it did nothing on either native; the web preview honoured
        // it, so the editor showed one thing and the device another.
        // `inline` / `floating` are not distinct behaviours on ANY surface yet (the preview
        // renders them as `above` too) — deliberately left alone rather than invented
        // differently per platform, which is how the two natives drift apart.
        let position = block.field_style?.label_position ?? "above"
        if position != "hidden",
           let label = block.field_label ?? block.rating_label ?? block.text, !label.isEmpty {
            let required = block.field_required ?? false
            // SPEC — honor authored label_font_size (field_style first, then
            // top-level), default .subheadline (~15pt). Parity with Android
            // FormFieldLabel (field_style?.label_font_size ?: 15sp). Was hardcoded.
            let labelSize = block.field_style?.label_font_size ?? block.label_font_size
            // SPEC-439 (#546) — label_font_family + label_align were missing entirely.
            let family = block.field_style?.label_font_family
            let baseFont: Font = {
                if let f = family, !f.isEmpty {
                    return .custom(f, size: CGFloat(labelSize ?? 15))
                }
                return labelSize.map { Font.system(size: CGFloat($0), weight: .medium) } ?? .subheadline.weight(.medium)
            }()
            let alignment: HorizontalAlignment = {
                switch block.field_style?.label_align {
                case "center": return .center
                case "right": return .trailing
                default: return .leading
                }
            }()
            let frameAlignment: Alignment = {
                switch block.field_style?.label_align {
                case "center": return .center
                case "right": return .trailing
                default: return .leading
                }
            }()
            VStack(alignment: alignment, spacing: 0) {
                HStack(spacing: 2) {
                    Text(label)
                        .font(baseFont)
                        .foregroundColor(Color(hex: block.field_style?.label_color ?? "#374151"))
                    if required {
                        Text("*")
                            .foregroundColor(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }
}

/// Helper function for calling FormFieldLabelView from within views.
@ViewBuilder
func formFieldLabel(_ block: ContentBlock) -> some View {
    FormFieldLabelView(block: block)
}

/// Extract a numeric value from AnyCodable, handling both Int and Double.
/// JSON integers decode as Int via AnyCodable, so `as? Double` silently fails.
func cfgDouble(_ val: AnyCodable?) -> Double? {
    guard let v = val?.value else { return nil }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return nil
}

/// Gradient direction helpers for angle-based gradients.
func gradientStart(_ angleDeg: Double) -> UnitPoint {
    let rad = angleDeg * .pi / 180
    return UnitPoint(x: 0.5 - cos(rad) * 0.5, y: 0.5 + sin(rad) * 0.5)
}
func gradientEnd(_ angleDeg: Double) -> UnitPoint {
    let rad = angleDeg * .pi / 180
    return UnitPoint(x: 0.5 + cos(rad) * 0.5, y: 0.5 - sin(rad) * 0.5)
}

/// Read configurable field height — checks element_height first (console sizing),
/// then falls back to field_config.field_height (legacy).
/// Returns nil if neither is set.
func fieldHeight(_ block: ContentBlock) -> CGFloat? {
    // element_height takes priority (set via console height control)
    if let eh = block.element_height {
        if let sv = SizeValue.parse(eh) {
            switch sv {
            case .px(let val): return val
            case .percent(let frac): return UIScreen.main.bounds.height * frac
            default: break
            }
        }
    }
    // Fallback: field_config.field_height (points)
    return cfgDouble(block.field_config?["field_height"]).map { CGFloat($0) }
}

/// SPEC-419 — effective field border width. When the block ALREADY draws a container
/// border (block_style.border_width > 0 — e.g. the login input blocks author a capsule
/// outline via applyBlockStyle), the field must NOT add its own or the two outlines stack
/// into a double border. Parity with Android FormInput*Block.
func fieldBorderWidth(_ block: ContentBlock) -> CGFloat {
    if (block.block_style?.border_width ?? 0) > 0 { return 0 }
    return CGFloat(block.field_style?.border_width ?? 1)
}

/// Generic text-based input (text, number, email, phone, url).
struct FormInputTextBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]
    let keyboardType: UIKeyboardType

    @State private var text: String = ""
    // SPEC — focus tracking so focused_background_color can swap the field fill
    // while editing (parity with Android isFocused). UIKitTextField already
    // drives this binding from textFieldDidBegin/EndEditing.
    @State private var isFocused: Bool = false

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let placeholder = block.field_placeholder ?? block.text ?? ""
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        // Always use UIKitTextField — SwiftUI TextField has focus/dark mode issues.
        let keyboardAppearanceRaw = block.field_config?["keyboard_appearance"]?.value as? String
        // SPEC-419 pass-16 #4 — honor field_config.input_text_size (preferred) /
        // font_size (default 14), mirroring preview precedence. Was no font set +
        // a fixed inner height of 24 that clipped larger fonts.
        let inputFontSize = CGFloat(cfgDouble(block.field_config?["input_text_size"]) ?? cfgDouble(block.field_config?["font_size"]) ?? 14)
        // SPEC — focused_background_color swaps the field fill while editing;
        // falls back to background_color when unset. Parity with Android.
        let baseBg = Color(hex: block.field_style?.background_color ?? "transparent")
        let focusedBg = block.field_style?.focused_background_color.map { Color(hex: $0) } ?? baseBg

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            UIKitTextField(
                text: $text,
                placeholder: placeholder,
                keyboardType: keyboardType,
                keyboardAppearance: .from(keyboardAppearanceRaw),
                returnKeyType: .done,
                font: UIFont.systemFont(ofSize: inputFontSize),
                textColor: block.field_style?.text_color.map { UIColor(Color(hex: $0)) },
                placeholderColor: block.field_style?.placeholder_color.map { UIColor(Color(hex: $0)) },
                isFocused: $isFocused
            )
            .frame(height: max(24, inputFontSize + 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .frame(minHeight: fieldHeight(block), alignment: .center)
            .background(isFocused ? focusedBg : baseBg)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: fieldBorderWidth(block))
            )
            .onChange(of: text) { newValue in
                inputValues[fieldId] = newValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if text.isEmpty, let saved = inputValues[fieldId] as? String { text = saved } }
    }
}

/// Multi-line text area input.
struct FormInputTextAreaBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var text: String = ""

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        let minLines = (block.field_config?["min_lines"]?.value as? Int) ?? 3
        // SPEC-419 pass-19 #2 — honor field_config.field_height as an additional minimum
        // (the editor shows "Field Height" for textarea too). min_lines stays the floor.
        let minLinesHeight = CGFloat(minLines * 22)
        let textAreaMinHeight = max(minLinesHeight, fieldHeight(block) ?? 0)
        // SPEC-419 pass-15 #14 — honor field_style.text_color + placeholder_color (Android + preview already do).
        let textColor = block.field_style?.text_color.map { Color(hex: $0) }
        let placeholderColor = Color(hex: block.field_style?.placeholder_color ?? "#9CA3AF")

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .foregroundColor(textColor)
                    .frame(minHeight: textAreaMinHeight)
                    .padding(4)
                    .background(Color(hex: block.field_style?.background_color ?? "transparent"))
                    .cornerRadius(cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(borderColor, lineWidth: fieldBorderWidth(block))
                    )
                    .onChange(of: text) { newValue in
                        inputValues[fieldId] = newValue
                    }
                if text.isEmpty, let ph = block.field_placeholder, !ph.isEmpty {
                    Text(ph)
                        .foregroundColor(placeholderColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if text.isEmpty, let saved = inputValues[fieldId] as? String { text = saved } }
    }
}

/// Password input with show/hide toggle.
struct FormInputPasswordBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var text: String = ""
    @State private var showPassword: Bool = false

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let placeholder = block.field_placeholder ?? "Password"
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        let keyboardAppearanceRaw = block.field_config?["keyboard_appearance"]?.value as? String
        // SPEC-419 pass-17 — mirror FormInputTextBlock font sizing onto the password sibling.
        let inputFontSize = CGFloat(cfgDouble(block.field_config?["input_text_size"]) ?? cfgDouble(block.field_config?["font_size"]) ?? 14)

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            HStack {
                UIKitTextField(
                    text: $text,
                    placeholder: placeholder,
                    keyboardAppearance: .from(keyboardAppearanceRaw),
                    isSecure: !showPassword,
                    textContentType: .password,
                    autocorrection: false,
                    autocapitalization: .none,
                    returnKeyType: .done,
                    font: UIFont.systemFont(ofSize: inputFontSize),
                    textColor: block.field_style?.text_color.map { UIColor(Color(hex: $0)) },
                    placeholderColor: block.field_style?.placeholder_color.map { UIColor(Color(hex: $0)) }
                )
                .frame(height: max(24, inputFontSize + 6))

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(minHeight: fieldHeight(block))
            .background(Color(hex: block.field_style?.background_color ?? "transparent"))
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: fieldBorderWidth(block))
            )
            .onChange(of: text) { newValue in
                inputValues[fieldId] = newValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if text.isEmpty, let saved = inputValues[fieldId] as? String { text = saved } }
    }
}

/// Date, Time, or DateTime picker input.
struct FormInputDateBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]
    let components: DatePickerComponents

    @State private var selectedDate = Date()
    @State private var showCompactPopover = false
    // Pre-warm state: an offscreen hidden wheel forces UIKit's UIPickerView
    // subsystem to init eagerly so the first tap → sheet open isn't laggy.
    @State private var prewarmDate = Date()
    // Round-10 #6 — allow_future/allow_past validation message for the form-input date variant.
    @State private var dateError: String?

    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-419 pass-15 #34 — honor highlight_color first (editor + preview key); fall back to fill_color/active_color.
        let accentColor = Color(hex: block.highlight_color ?? block.field_style?.fill_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Dark theme detection: explicit color_scheme override, else auto-detect
        // from text_color being a light color (onboarding flows with dark
        // backgrounds set white text, and the native date wheel popover must
        // match, otherwise it renders white-on-white and is unreadable).
        let schemeOverride = block.field_config?["color_scheme"]?.value as? String
        let resolvedScheme: ColorScheme? = {
            switch schemeOverride?.lowercased() {
            case "dark": return .dark
            case "light": return .light
            default:
                if let hex = block.field_style?.text_color, Color.isLightHex(hex) { return .dark }
                return nil
            }
        }()

        // Picker variant (UI: "Picker Variant" select on input_date/datetime).
        // Falls back to .compact when unset so existing flows don't change.
        // block.picker_presentation (editor "Presentation" control) takes precedence, matching
        // Android (ContentBlockRenderer.kt:7780-7784) + preview: "field" → tap-to-open compact,
        // "inline" → graphical (only for variants that include a date component; time-only has no
        // graphical style so it falls through to picker_variant).
        let variant: String = {
            if block.picker_presentation == "field" {
                return "compact"
            } else if block.picker_presentation == "inline" && components.contains(.date) {
                return "graphical"
            }
            return (block.field_config?["picker_variant"]?.value as? String) ?? "compact"
        }()
        // SPEC — honor time_format ("12h"/"24h") + time_text_size on the time
        // picker. The console writes both to input_time/input_datetime which
        // route here (not to DateWheelPickerBlockView). Locale en_GB forces 24h
        // (HH:mm, no AM/PM); en_US forces 12h (h:mm a). Only applies when a time
        // component is shown; unset time_format keeps the device locale.
        let isTimeComponent = components.contains(.hourAndMinute)
        let timeLocale: Locale? = {
            guard isTimeComponent, let tf = block.time_format?.lowercased() else { return nil }
            return Locale(identifier: tf == "24h" ? "en_GB" : "en_US")
        }()
        // Non-optional so the compact display text never falls back to SwiftUI's
        // ~17pt body when time_text_size is unset. Mirrors Android's 14.sp default
        // (time components honor time_text_size ?? 14; non-time components use 14).
        let displayFont: Font = Font.system(size: CGFloat(isTimeComponent ? (block.time_text_size ?? 14) : 14))
        // Per-variant bg — both controls already exist in the console editor.
        let wheelBgHex = block.field_config?["wheel_bg_color"]?.value as? String
        let calendarBgHex = block.field_config?["calendar_bg_color"]?.value as? String
        // Fall through to the shared field_style.background_color (the
        // "Background" picker every input_* block shares) so the compact pill
        // can finally be styled like every other input field.
        let fieldBgHex = block.field_style?.background_color
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        // Opacity control for the per-variant surface, mirrors wheel_opacity
        // on the standalone date_wheel_picker block.
        let wheelOpacity = CGFloat((cfgDouble(block.field_config?["wheel_opacity"])) ?? 1.0)
        let calendarOpacity = CGFloat((cfgDouble(block.field_config?["calendar_opacity"])) ?? 1.0)

        // Height control for the compact pill (wheel/graphical have intrinsic
        // heights set by the picker itself). Accepts a numeric `input_height`
        // or `height` in field_config, or the semantic `sm | md | lg` shorthand
        // on field_style.height.
        let numericHeight: Double? = cfgDouble(block.field_config?["input_height"])
            ?? cfgDouble(block.field_config?["height"])
        let semanticHeight: Double? = {
            switch block.field_style?.height?.lowercased() {
            case "sm": return 36
            case "md": return 44
            case "lg": return 56
            default: return nil
            }
        }()
        let compactHeight: CGFloat? = (numericHeight ?? semanticHeight).map { CGFloat($0) }

        // SPEC-419 pass-16 #11/#12 — honor picker_border_color/_width/_corner_radius/_padding
        // + wheel_text_color on ALL date variants (was standalone date_wheel_picker only).
        // Mirrors editor field_config keys + preview OnboardingStepPreview.tsx:2576-2580.
        let pickerCornerRadius = CGFloat((cfgDouble(block.field_config?["picker_corner_radius"])) ?? 12)
        let wheelTextColorHex = block.field_config?["wheel_text_color"]?.value as? String
        let pickerBorderColorHex = block.field_config?["picker_border_color"]?.value as? String
        let pickerBorderWidth = CGFloat((cfgDouble(block.field_config?["picker_border_width"])) ?? (pickerBorderColorHex != nil ? 1 : 0))
        let pickerPadding = CGFloat((cfgDouble(block.field_config?["picker_padding"])) ?? 0)

        VStack(alignment: .leading, spacing: 6) {
            // Pre-warm the iOS wheel subsystem behind a zero-size anchor.
            // Earlier .frame(200,150).offset(-10000,-10000) was wrong — the
            // 150pt frame still ate VStack space, breaking layout for any
            // sibling block stacked below.
            Color.clear
                .frame(width: 0, height: 0)
                .background(
                    DatePicker("", selection: $prewarmDate, displayedComponents: components)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 200, height: 150)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                )

            formFieldLabel(block)

            Group {
                switch variant {
                case "wheel":
                    DatePicker("", selection: $selectedDate, displayedComponents: components)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .tint(accentColor)
                        .environment(\.locale, timeLocale ?? Locale.current)
                        .frame(maxWidth: .infinity)
                        // #12 — wheel_text_color tints the spinning labels (.white = identity).
                        .colorMultiply(wheelTextColorHex.map { Color(hex: $0) } ?? .white)
                        .background(Color(hex: wheelBgHex ?? fieldBgHex ?? "transparent").opacity(wheelOpacity))
                        .cornerRadius(cornerRadius)
                case "graphical":
                    DatePicker("", selection: $selectedDate, displayedComponents: components)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .tint(accentColor)
                        .environment(\.locale, timeLocale ?? Locale.current)
                        .background(Color(hex: calendarBgHex ?? fieldBgHex ?? "transparent").opacity(calendarOpacity))
                        .cornerRadius(cornerRadius)
                default: // compact
                    // Fully custom tap-to-open pattern instead of SwiftUI's
                    // `.datePickerStyle(.compact)`. The native compact style
                    // draws its own rounded pill (system tertiary fill) which
                    // layered underneath any chrome we added and made the
                    // outer border's corners look bolder than the straight
                    // edges. A plain Text + icon button sidesteps the pill
                    // entirely so our border is the only rounded shape drawn.
                    // Default border to 1pt when a color is authored but the
                    // width is left unset — prevents the border from vanishing
                    // when the author clicks a color picker without touching
                    // the width slider.
                    let authoredBorderColor = block.field_style?.border_color
                    let borderColorHex = authoredBorderColor ?? "#D1D5DB"
                    let borderWidth = block.field_style?.border_width
                        .map { CGFloat($0) }
                        ?? (authoredBorderColor != nil ? 1 : 0)
                    let bg = Color(hex: fieldBgHex ?? "transparent")
                    let fgColor: Color = {
                        if let hex = block.field_style?.text_color { return Color(hex: hex) }
                        return resolvedScheme == .dark ? .white : .primary
                    }()
                    let fmt: DateFormatter = {
                        let f = DateFormatter()
                        if components == .date { f.dateStyle = .medium; f.timeStyle = .none }
                        else if components == .hourAndMinute { f.dateStyle = .none; f.timeStyle = .short }
                        else { f.dateStyle = .medium; f.timeStyle = .short }
                        // Force 12h/24h display per time_format when a time is shown.
                        if let loc = timeLocale { f.locale = loc }
                        return f
                    }()
                    let chevron = components == .hourAndMinute ? "clock" : "calendar"

                    Button {
                        showCompactPopover.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(fmt.string(from: selectedDate))
                                .font(displayFont)
                                .foregroundColor(fgColor)
                            Spacer()
                            Image(systemName: chevron)
                                .foregroundColor(accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: compactHeight ?? fieldHeight(block), alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Single-path background — fill + stroke on the SAME
                    // RoundedRectangle so the corner antialiasing is identical
                    // to the straight edges.
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius).fill(bg)
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(Color(hex: borderColorHex), lineWidth: borderWidth)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .sheet(isPresented: $showCompactPopover) {
                        let sheetContent = VStack(spacing: 16) {
                            DatePicker("", selection: $selectedDate, displayedComponents: components)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                                .tint(accentColor)
                                .environment(\.locale, timeLocale ?? Locale.current)
                                .environment(\.colorScheme, resolvedScheme ?? .light)
                            Button("Done") { showCompactPopover = false }
                                .buttonStyle(.borderedProminent)
                                .tint(accentColor)
                        }
                        .padding()
                        Group {
                            if #available(iOS 16.0, *) {
                                sheetContent.presentationDetents([.medium])
                            } else {
                                sheetContent
                            }
                        }
                    }
                }
            }
            // #11 — opt-in picker border + padding around the whole picker (any variant).
            .padding(pickerPadding)
            .overlay(
                RoundedRectangle(cornerRadius: pickerCornerRadius)
                    .strokeBorder(Color(hex: pickerBorderColorHex ?? "#00000000"), lineWidth: pickerBorderWidth)
            )
            .environment(\.colorScheme, resolvedScheme ?? .light)
            .onChange(of: selectedDate) { newValue in
                // Round-10 #6 — enforce allow_future / allow_past on the form-input date variant,
                // matching Android's FormInputDateBlock and iOS's own DateWheelPickerBlockView. Before
                // this, input_date silently accepted any date. An out-of-range pick is NOT committed
                // (so the required gate still blocks the step) and surfaces the inline message.
                let now = Date()
                if block.allow_future == false && newValue > now {
                    dateError = block.date_validation_message ?? "Future dates are not allowed"
                    inputValues[fieldId] = nil
                    return
                }
                if block.allow_past == false && newValue < now {
                    dateError = block.date_validation_message ?? "Past dates are not allowed"
                    inputValues[fieldId] = nil
                    return
                }
                // Mrozu QA — also enforce block.min_date / block.max_date on the form-input date
                // variant (the editor's Min/Max Date controls). Previously only the standalone
                // date_wheel_picker honored these; input_date/time/datetime silently dropped them.
                // Parsed with the same helper the standalone picker uses (relative + ISO forms).
                if let minD = DateWheelPickerBlockView.parseDate(block.min_date), newValue < minD {
                    dateError = block.date_validation_message ?? "Date is before the allowed minimum"
                    inputValues[fieldId] = nil
                    return
                }
                if let maxD = DateWheelPickerBlockView.parseDate(block.max_date), newValue > maxD {
                    dateError = block.date_validation_message ?? "Date is after the allowed maximum"
                    inputValues[fieldId] = nil
                    return
                }
                dateError = nil
                let formatter = ISO8601DateFormatter()
                inputValues[fieldId] = formatter.string(from: newValue)
            }
            if let dateError {
                Text(dateError)
                    .font(.caption)
                    // Honor field_style.error_text_color (parity with Android, which uses
                    // error_text_color ?? colorScheme.error) — was hardcoded system red.
                    .foregroundColor(block.field_style?.error_text_color.map { Color(hex: $0) } ?? .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dropdown select input with display_style support (dropdown, stacked, grid).
struct FormInputSelectBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedValue: String = ""
    // Round-11 Finding 3 — an ordered [String] (append-on-select, acting as an ordered set) so the
    // written array preserves SELECTION order, matching Android's LinkedHashSet. A Swift Set is
    // hash-ordered and non-deterministic across runs, so `Array(Set)` produced arbitrary ordering.
    @State private var selectedValues: [String] = []
    /// SPEC-441 (#541) — the active category chip. Empty means "first chip".
    @State private var activeCategory: String = ""
    /// SPEC-444 (#540, #542) — the option whose bottom sheet is presented, if any.
    @State private var sheetOption: InputOption? = nil
    // SPEC-448 (#556) — options fetched for this block's Option Set. Empty until a refresh lands,
    // which is why the ladder falls back to `field_options` rather than waiting on it.
    @State private var dynamicOptions: [InputOption] = []
    // SPEC-448 — the search box. `searchResults` is nil when no search is active, which is a
    // different state from "searched and found nothing" and must render differently.
    @State private var searchText: String = ""
    @State private var searchResults: [InputOption]? = nil
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    // SPEC-448 — paging. `nextCursor` nil means "no more, or not started"; `isPaging` stops a
    // burst of onAppear callbacks from firing several identical requests for the same page.
    @State private var nextCursor: String? = nil
    @State private var isPaging: Bool = false

    /// Whether the author asked for a search box.
    private var showsSearch: Bool {
        (block.field_config?["options_search"]?.value as? Bool) == true
    }

    /// The set this Select is bound to, or nil for an authored list.
    private var optionSetId: String? {
        block.field_config?["option_set_id"]?.value as? String
    }

    /// The version the flow config was published with. The store treats a cached entry at or
    /// above this as current, which is what makes an author's edit land on next launch rather
    /// than only after some cache TTL expires.
    private var optionSetVersion: Int? {
        if let v = block.field_config?["option_set_version"]?.value as? Int { return v }
        if let d = block.field_config?["option_set_version"]?.value as? Double { return Int(d) }
        return nil
    }

    private var isMultiSelect: Bool {
        block.multi_select == true ||
        (block.field_config?["multi_select"]?.value as? Bool) == true
    }

    /// Read display_style from field_config; defaults to "dropdown".
    private var displayStyle: String {
        (block.field_config?["display_style"]?.value as? String) ?? "dropdown"
    }

    /// SPEC-442 (#552) — the GLOBAL selected-border colour. It existed per-option only, so
    /// matching the selected border across N options meant editing N options by hand. A
    /// per-option `selected_border_color` still wins; this is the shared fallback.
    private var globalSelectedBorderHex: String? {
        block.field_config?["selected_border_color"]?.value as? String
    }

    // SPEC-442 sweep — the remaining per-option styling fields that had no global. Same defect
    // shape as Selected Border: consistency meant editing every option by hand. Per-option wins.
    private var globalTextAlignment: String? { block.field_config?["text_alignment"]?.value as? String }
    private var globalTitleWeight: String? { block.field_config?["title_font_weight"]?.value as? String }
    private var globalImageShape: String? { block.field_config?["image_shape"]?.value as? String }
    private var globalOverlayHex: String? { block.field_config?["image_overlay_color"]?.value as? String }
    private var globalSelectedOverlayHex: String? { block.field_config?["selected_image_overlay_color"]?.value as? String }
    private var globalOverlayOpacity: Double? {
        (block.field_config?["image_overlay_opacity"]?.value as? Double)
            ?? (block.field_config?["image_overlay_opacity"]?.value as? Int).map(Double.init)
    }

    // MARK: - SPEC-441 (#541) — category chips

    /// A scrollable row of chips above the options; the active chip filters what shows.
    /// Authored as `field_config.categories` = [{ id, label, icon? }].
    private var categories: [(id: String, label: String, icon: String?)] {
        guard let raw = block.field_config?["categories"]?.value as? [Any] else { return [] }
        return raw.compactMap { entry in
            guard let m = entry as? [String: Any],
                  let id = m["id"] as? String,
                  let label = m["label"] as? String else { return nil }
            return (id: id, label: label, icon: m["icon"] as? String)
        }
    }

    private var showCategoryHeader: Bool {
        (block.field_config?["category_header"]?.value as? Bool) ?? true
    }

    private var resolvedActiveCategory: String {
        activeCategory.isEmpty ? (categories.first?.id ?? "") : activeCategory
    }

    /// Options in section order: uncategorised first, then each category's options in the
    /// authored category order.
    ///
    /// The chips are scroll-spy NAVIGATION, not a filter — every category renders as its own
    /// titled section in one scrolling list. (An earlier build filtered to the active chip;
    /// that was a misread of a screenshot showing only the first section.)
    private func optionsForActiveCategory(_ options: [InputOption]) -> [InputOption] {
        guard !categories.isEmpty else { return options }
        let uncategorised = options.filter { $0.category == nil }
        let grouped = categories.flatMap { cat in options.filter { $0.category == cat.id } }
        return uncategorised + grouped
    }

    /// The category whose section STARTS at this index, or nil when the option continues the
    /// previous section.
    private func sectionStart(_ options: [InputOption], _ i: Int) -> (id: String, label: String, icon: String?)? {
        guard !categories.isEmpty, let cat = options[i].category else { return nil }
        if i > 0, options[i - 1].category == cat { return nil }
        return categories.first { $0.id == cat }
    }

    @ViewBuilder
    private var categoryChipRow: some View {
        if !categories.isEmpty {
            let active = resolvedActiveCategory
            let accent = Color(hex: AppDNA.brandAccentHex ?? "#6366F1")
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.id) { cat in
                            Button(action: { activeCategory = cat.id }) {
                                Text(cat.icon.map { "\($0) " + cat.label } ?? cat.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(cat.id == active ? accent : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(cat.id == active ? accent.opacity(0.2) : Color.gray.opacity(0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// SPEC-448 §C — progress is shown INSIDE the search field and nowhere else.
    ///
    /// A spinner over the list would say "this screen is loading", which is false: the list is
    /// right there and still usable while a search is in flight. The rule the whole feature is
    /// built around is that it never looks like it is fetching.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            TextField("Search", text: $searchText)
                .font(.system(size: 15))
                .autocorrectionDisabled()
                .onChange(of: searchText) { newValue in
                    runSearch(newValue)
                }
            if isSearching {
                ProgressView().scaleEffect(0.7)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// SPEC-448 — fetch the next page when the user reaches the end of the list.
    ///
    /// Triggered by the LAST rendered option appearing rather than by a scroll offset: offsets
    /// differ per display style (a grid, a stacked list and a dropdown all scroll differently) and
    /// would need separate maths for each, while "the last row became visible" means the same
    /// thing everywhere. Search results are never paged from here — the server already returned
    /// the matches for that query, and appending page 2 of the UNFILTERED list under them would
    /// silently mix the two.
    private func pageInIfNeeded(after option: InputOption) {
        guard searchResults == nil,
              let setId = optionSetId, !setId.isEmpty,
              let cursor = nextCursor, !isPaging,
              option.resolvedValue == allSourcedOptions.last?.resolvedValue
        else { return }

        isPaging = true
        Task {
            let page = await OptionSetStore.shared.nextPage(
                setId: setId, cursor: cursor, client: AppDNA.optionSetClient
            )
            await MainActor.run {
                isPaging = false
                guard let page else { return }
                // Read the merged list back from the store rather than appending here: the store
                // de-duplicates by value, and a reorder between two fetches can legitimately return
                // an item already held.
                nextCursor = page.next_cursor
            }
            let merged = await OptionSetStore.shared.cachedItems(for: setId)
            await MainActor.run { if !merged.isEmpty { dynamicOptions = merged } }
        }
    }

    /// Every option currently in play, by the same ladder the body uses. The multi-select branch
    /// needs the full objects to record, and it only holds values.
    private var allSourcedOptions: [InputOption] {
        if let results = searchResults { return results }
        guard let setId = optionSetId, !setId.isEmpty else { return block.field_options ?? [] }
        return dynamicOptions.isEmpty ? (block.field_options ?? []) : dynamicOptions
    }

    /// Debounced remote search.
    ///
    /// Each keystroke cancels the previous task, so a fast typist issues one request rather than
    /// one per character — the endpoint has its own rate-limit bucket precisely because a search
    /// box is the chattiest thing pointed at it.
    private func runSearch(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Clearing the box restores the full list rather than showing "no results" — an empty
            // query is not a filter.
            searchResults = nil
            isSearching = false
            return
        }

        guard let setId = optionSetId, !setId.isEmpty else {
            // A locally-authored list is searched in memory. No network, no spinner, and it works
            // with no Option Set at all.
            let folded = trimmed.lowercased()
            searchResults = (block.field_options ?? []).filter {
                ($0.label ?? "").lowercased().contains(folded)
                    || ($0.subtitle ?? "").lowercased().contains(folded)
            }
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000) // debounce
            if Task.isCancelled { return }
            await MainActor.run { isSearching = true }
            let results = await OptionSetStore.shared.search(
                setId: setId, query: trimmed, client: AppDNA.optionSetClient
            )
            if Task.isCancelled { return }
            await MainActor.run {
                isSearching = false
                // nil means the search could NOT be performed. Leaving the previous list up is
                // right: replacing it with an empty one would tell the user their query matched
                // nothing, which is a different and wrong statement.
                if let results { searchResults = results }
            }
        }
    }
    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-448 (#556) — a Select can source its options from an Option Set instead of the
        // authored list. The ladder is cache → embedded page → authored, resolved synchronously
        // so the FIRST frame has something real: making this await would put the network on the
        // render path, which is exactly the "looks like it is fetching" the spec forbids.
        // `field_options` doubles as the embedded page — the same array an SDK predating this
        // spec renders — so an old build degrades to a short list rather than an empty Select.
        let sourced: [InputOption] = {
            // An active search REPLACES the list, including an empty result — that is the honest
            // answer to "nothing matched", and falling back to the full list here would silently
            // ignore what the user typed.
            if let results = searchResults { return results }
            guard let setId = optionSetId, !setId.isEmpty else { return block.field_options ?? [] }
            return dynamicOptions.isEmpty ? (block.field_options ?? []) : dynamicOptions
        }()
        // SPEC-441 (#541) — the active chip filters what the Select shows.
        let options = optionsForActiveCategory(sourced)

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)
            categoryChipRow

            switch displayStyle {
            case "stacked":
                stackedSelectView(options: options, fieldId: fieldId)
            case "grid":
                gridSelectView(options: options, fieldId: fieldId)
            case "image_tiles":
                imageTilesSelectView(options: options, fieldId: fieldId)
            case "bubble":
                bubbleSelectView(options: options, fieldId: fieldId)
            case "list":
                listSelectView(options: options, fieldId: fieldId)
            default: // "dropdown"
                dropdownSelectView(options: options, fieldId: fieldId)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // SPEC-444 (#540, #542) — an option that owns sheet_blocks opens them in a bottom
        // sheet when picked. The blocks render through the ordinary renderer, which is what
        // lets one engine serve both the chooser and the detail screens.
        .sheet(item: $sheetOption) { opt in
            OptionBottomSheetView(option: opt, onDismiss: { sheetOption = nil })
        }
        .onAppear {
            let fieldId = block.field_id ?? block.id
            if selectedValue.isEmpty, let saved = inputValues[fieldId] as? String {
                selectedValue = saved
            }
            if selectedValues.isEmpty, let saved = inputValues[fieldId] as? [String] {
                selectedValues = saved
            }
        }
        // SPEC-448 (#556) — refresh the set AFTER the first frame has drawn. `.task` runs once the
        // view is on screen, so the list the user sees is whatever the ladder already had; when a
        // fresher one arrives it swaps in. Nothing here blocks a render, which is the difference
        // between a list that is occasionally a moment stale and one that visibly loads.
        .task(id: optionSetId) {
            guard let setId = optionSetId, !setId.isEmpty else { return }
            let fresh = await OptionSetStore.shared.refresh(
                setId: setId,
                client: AppDNA.optionSetClient,
                expectedVersion: optionSetVersion
            )
            // A failed refresh returns empty, and empty must NOT clear a working list — the
            // fallback ladder stays standing rather than being replaced by nothing.
            if !fresh.isEmpty { dynamicOptions = fresh }
            nextCursor = await OptionSetStore.shared.cursor(for: setId)
        }
    }

    // MARK: - List / separators (EPIC-1)

    @ViewBuilder
    private func listSelectView(options: [InputOption], fieldId: String) -> some View {
        let cfg = block.field_config
        let accentHex = block.field_style?.fill_color ?? block.field_style?.focused_border_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1")
        let fillCol = Color(hex: accentHex)
        let separatorCol = (cfg?["separator_color"]?.value as? String).map { Color(hex: $0) } ?? Color(hex: "#D1D5DB")
        // SPEC-419 pass-24 — separator_thickness (console Slider 0–4, default 1) drives the
        // divider height; thickness was previously hardcoded to 1pt.
        let separatorThickness = CGFloat((cfgDouble(cfg?["separator_thickness"])) ?? 1)
        let textCol: Color = (cfg?["text_color"]?.value as? String).map { Color(hex: $0) } ?? block.field_style?.text_color.map { Color(hex: $0) } ?? .primary
        let selectedTextCol: Color = (cfg?["selected_text_color"]?.value as? String).map { Color(hex: $0) } ?? textCol
        let selectedBgCol = (cfg?["selected_bg_color"]?.value as? String).map { Color(hex: $0) } ?? fillCol.opacity(0.15)
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                let isSelected = isMultiSelect ? selectedValues.contains(option.resolvedValue) : selectedValue == option.resolvedValue
                let _ = pageInIfNeeded(after: option)
                // Parity with Android (ContentBlockRenderer list 8781/8795-8797) + preview:
                // honor per-option title/subtitle font size, and per-option title_color for the
                // unselected state (selected still uses the block-level selectedTextCol).
                let optTitleSize = CGFloat(option.title_font_size ?? 16)
                let optSubtitleSize = CGFloat(option.subtitle_font_size ?? 13)
                let optTitleCol = isSelected
                    ? (option.selected_text_color.map { Color(hex: $0) } ?? selectedTextCol)
                    : (option.title_color.map { Color(hex: $0) } ?? textCol)
                let optSubtitleCol = isSelected
                    ? (option.selected_text_color.map { Color(hex: $0) } ?? selectedTextCol)
                    : (option.title_color.map { Color(hex: $0) } ?? textCol)
                let optRowBg = isSelected
                    ? (option.selected_bg_color.map { Color(hex: $0) } ?? selectedBgCol)
                    : (option.bg_color.map { Color(hex: $0) } ?? Color.clear)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label ?? "").font(.system(size: optTitleSize)).foregroundColor(optTitleCol)
                        if let sub = option.subtitle, !sub.isEmpty {
                            Text(sub).font(.system(size: optSubtitleSize)).foregroundColor(optSubtitleCol)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Text("✓").font(.system(size: 18, weight: .bold)).foregroundColor(fillCol)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(optRowBg)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection(option: option, fieldId: fieldId) }
                if idx < options.count - 1 {
                    Rectangle().fill(separatorCol).frame(height: separatorThickness)
                }
            }
        }
    }

    // MARK: - Bubble / chip (EPIC-1)

    @ViewBuilder
    private func bubbleSelectView(options: [InputOption], fieldId: String) -> some View {
        let cfg = block.field_config
        let accentHex = block.field_style?.fill_color ?? block.field_style?.focused_border_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1")
        let fillCol = Color(hex: accentHex)
        let cfgOptBorder = (cfg?["border_color"]?.value as? String).map { Color(hex: $0) }
        let unselectedBorderCol: Color = cfgOptBorder ?? block.field_style?.border_color.map { Color(hex: $0) } ?? Color(hex: "#D1D5DB")
        let textCol: Color = (cfg?["text_color"]?.value as? String).map { Color(hex: $0) } ?? block.field_style?.text_color.map { Color(hex: $0) } ?? .primary
        let selectedTextCol: Color = (cfg?["selected_text_color"]?.value as? String).map { Color(hex: $0) } ?? textCol
        let selectedBorderW = CGFloat((cfgDouble(cfg?["selected_border_width"])) ?? 2)
        let unselectedBorderW = CGFloat((cfgDouble(cfg?["unselected_border_width"])) ?? 1)
        let spacing = CGFloat((cfgDouble(cfg?["option_spacing"])) ?? 8)
        ChipFlowLayout(spacing: spacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = isMultiSelect ? selectedValues.contains(option.resolvedValue) : selectedValue == option.resolvedValue
                let _ = pageInIfNeeded(after: option)
                let chipBorder = isSelected ? ((option.selected_border_color ?? globalSelectedBorderHex).map { Color(hex: $0) } ?? fillCol) : (option.border_color.map { Color(hex: $0) } ?? unselectedBorderCol)
                // Parity with Android + preview: honor per-option bg_color / selected_bg_color
                // (was hardcoded fillCol / clear, dropping per-option chip backgrounds).
                let chipBg = isSelected
                    ? (option.selected_bg_color.map { Color(hex: $0) } ?? fillCol)
                    : (option.bg_color.map { Color(hex: $0) } ?? Color.clear)
                Text(option.label ?? "")
                    // Parity with Android bubble (ContentBlockRenderer.kt:8760): honor per-option title_font_size.
                    .font(.system(size: CGFloat(option.title_font_size ?? 14), weight: .medium))
                    .foregroundColor(isSelected ? selectedTextCol : textCol)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(chipBg)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(chipBorder, lineWidth: isSelected ? selectedBorderW : unselectedBorderW))
                    .contentShape(Capsule())
                    .onTapGesture { toggleSelection(option: option, fieldId: fieldId) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Image-fill tiles (EPIC-1)

    @ViewBuilder
    private func imageTilesSelectView(options: [InputOption], fieldId: String) -> some View {
        let cfg = block.field_config
        let accentHex = block.field_style?.fill_color ?? block.field_style?.focused_border_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1")
        let fillCol = Color(hex: accentHex)
        let cornerR = CGFloat(block.field_style?.corner_radius ?? 10)
        let cfgOptBorder = (cfg?["border_color"]?.value as? String).map { Color(hex: $0) }
        let unselectedBorderCol: Color = cfgOptBorder ?? block.field_style?.border_color.map { Color(hex: $0) } ?? Color(hex: "#D1D5DB")
        let cols = max(Int((cfgDouble(cfg?["grid_columns"])) ?? 2), 1)
        let tileHeight = CGFloat((cfgDouble(cfg?["tile_height"])) ?? 140)
        // SPEC-419 pass-24 — tile_aspect_ratio ("W:H", console Select 1:1/4:3/16:9/3:4) sizes the
        // tile by its (flexible) width × the ratio. When set it overrides the fixed tile_height;
        // falls back to tile_height when unset.
        let tileAspect = parseAspectRatio(cfg?["tile_aspect_ratio"]?.value as? String)
        let selectedBorderW = CGFloat((cfgDouble(cfg?["selected_border_width"])) ?? 2)
        let unselectedBorderW = CGFloat((cfgDouble(cfg?["unselected_border_width"])) ?? 1)
        let spacing = CGFloat((cfgDouble(cfg?["option_spacing"])) ?? 8)
        // SPEC-447 (#555) — where the TEXT sits relative to the image. `full_bleed` is the default
        // and renders exactly as before; the other two give the label a surface of its own instead
        // of relying on a scrim to dim the photograph.
        let tileLayout = (cfg?["tile_image_layout"]?.value as? String) ?? "full_bleed"
        let stripRatio = min(0.95, max(0.5, (cfgDouble(cfg?["tile_strip_ratio"])) ?? 0.75))
        let surfaceHex = (cfg?["tile_surface_color"]?.value as? String)
            ?? block.field_style?.background_color ?? "#111827"
        let imgInset = CGFloat((cfgDouble(cfg?["tile_image_inset"])) ?? 8)
        let frameW = CGFloat((cfgDouble(cfg?["tile_image_frame_width"])) ?? 0)
        let frameHex = (cfg?["tile_image_frame_color"]?.value as? String) ?? "#374151"
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols), spacing: spacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = isMultiSelect ? selectedValues.contains(option.resolvedValue) : selectedValue == option.resolvedValue
                let _ = pageInIfNeeded(after: option)
                let optBorderCol = (option.selected_border_color ?? globalSelectedBorderHex).map { Color(hex: $0) } ?? fillCol
                let optUnselBorderCol = option.border_color.map { Color(hex: $0) } ?? unselectedBorderCol
                ZStack(alignment: .bottomLeading) {
                    if tileLayout != "full_bleed" {
                        // The text surface sits under everything; the image is then laid over its
                        // own share of the tile, so the label never has a photograph behind it.
                        Color(hex: surfaceHex)
                    }
                    if let imgUrl = option.resolvedImageURL(isSelected: isSelected), let url = URL(string: imgUrl) {
                        GeometryReader { geo in
                            BundledAsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.gray.opacity(0.2)
                            }
                            .frame(
                                width: tileLayout == "contained" ? geo.size.width - imgInset * 2 : geo.size.width,
                                height: tileLayout == "full_bleed"
                                    ? geo.size.height
                                    : geo.size.height * CGFloat(stripRatio) - (tileLayout == "contained" ? imgInset : 0),
                            )
                            .clipped()
                            .overlay(
                                frameW > 0 && tileLayout == "contained"
                                    ? RoundedRectangle(cornerRadius: 8).stroke(Color(hex: frameHex), lineWidth: frameW)
                                    : nil,
                            )
                            .cornerRadius(tileLayout == "contained" ? 8 : 0)
                            .offset(x: tileLayout == "contained" ? imgInset : 0, y: tileLayout == "contained" ? imgInset : 0)
                        }
                    }
                    // Selected uses selected_image_overlay_* (falls back to base). Parity with Android.
                    if let ovHex = (isSelected ? (option.selected_image_overlay_color ?? globalSelectedOverlayHex ?? option.image_overlay_color ?? globalOverlayHex) : (option.image_overlay_color ?? globalOverlayHex)) {
                        let ovOpacity = (isSelected ? (option.selected_image_overlay_opacity ?? option.image_overlay_opacity ?? globalOverlayOpacity) : (option.image_overlay_opacity ?? globalOverlayOpacity)) ?? 0.3
                        // SPEC-447 AC — the overlay covers the IMAGE REGION ONLY in the two surfaced
                        // layouts. Unconstrained it fills the ZStack, so authoring a dark scrim and then
                        // switching layout dimmed the text band too: the very surface these layouts exist
                        // to provide, tinted by a setting meant for the photograph. The bottom scrim below
                        // was already gated on full_bleed; this is that same reasoning applied to the other
                        // overlay. Geometry mirrors the image exactly, inset included.
                        // Its own GeometryReader, for the same reason the image above has one: the
                        // overlay has to be measured against the TILE to cover the image's share of it.
                        GeometryReader { ovGeo in
                            Color(hex: ovHex).opacity(ovOpacity)
                                .frame(
                                    width: tileLayout == "contained" ? ovGeo.size.width - imgInset * 2 : ovGeo.size.width,
                                    height: tileLayout == "full_bleed"
                                        ? ovGeo.size.height
                                        : ovGeo.size.height * CGFloat(stripRatio) - (tileLayout == "contained" ? imgInset : 0)
                                )
                                .cornerRadius(tileLayout == "contained" ? 8 : 0)
                                .offset(x: tileLayout == "contained" ? imgInset : 0, y: tileLayout == "contained" ? imgInset : 0)
                        }
                    }
                    // Bottom scrim so the label stays legible over any image — only meaningful when
                    // the text is ON the image. With a text surface it would dim the very surface
                    // these layouts exist to provide.
                    if tileLayout == "full_bleed" {
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label ?? "")
                            // Parity with Android image_tiles: honour the per-option font size.
                            .font(.system(size: CGFloat(option.title_font_size ?? 15), weight: .semibold))
                            .foregroundColor(.white)
                        if let sub = option.subtitle, !sub.isEmpty {
                            Text(sub).font(.system(size: CGFloat(option.subtitle_font_size ?? 12))).foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    // SPEC-447 — the band is painted UNDER THE TEXT, so it is exactly as tall as the
                    // text needs. A band sized as a fixed share of the tile puts the title back on
                    // the photograph the moment two lines do not fit that share. Parity with Android.
                    .background(tileLayout == "full_bleed" ? Color.clear : Color(hex: surfaceHex))
                }
                .frame(maxWidth: .infinity)
                .tileSize(aspectRatio: tileAspect, height: tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerR))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerR)
                        .stroke(isSelected ? optBorderCol : optUnselBorderCol, lineWidth: isSelected ? selectedBorderW : unselectedBorderW)
                )
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection(option: option, fieldId: fieldId) }
            }
        }
    }

    // MARK: - Dropdown (default)

    @ViewBuilder
    private func dropdownSelectView(options: [InputOption], fieldId: String) -> some View {
        Picker("", selection: $selectedValue) {
            Text(block.field_placeholder ?? "Select...").tag("")
            ForEach(options) { option in
                Text(option.label ?? "").tag(option.resolvedValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .frame(minHeight: fieldHeight(block), alignment: .center)
        .background(Color(hex: block.field_style?.background_color ?? "transparent"))
        .cornerRadius(CGFloat(block.field_style?.corner_radius ?? 8))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(block.field_style?.corner_radius ?? 8))
                .stroke(Color(hex: block.field_style?.border_color ?? "#D1D5DB"), lineWidth: fieldBorderWidth(block))
        )
        .onChange(of: selectedValue) { newValue in
            inputValues[fieldId] = newValue
        }
    }

    // MARK: - Stacked (vertical cards with configurable selection indicator)

    @ViewBuilder
    private func stackedSelectView(options: [InputOption], fieldId: String) -> some View {
        let cfg = block.field_config
        let accentHex = block.field_style?.fill_color
            ?? block.field_style?.focused_border_color
            ?? block.active_color
            ?? (AppDNA.brandAccentHex ?? "#6366F1")
        let fillCol = Color(hex: accentHex)
        // Select v2 — option card corner: `option_corner_radius` wins, else legacy `corner_radius`, else 10.
        let cornerR = CGFloat(block.field_style?.option_corner_radius ?? block.field_style?.corner_radius ?? 10)
        // Select v2 — per-option styling extras (Mrozu QA).
        let optionFontFamily = block.field_style?.option_font_family
        // Default TRUE = full wrap (preserves prior native behavior + the Mrozu ask
        // that long option text stays fully visible). Authors opt into single-line
        // truncation by setting option_text_wrap=false.
        let optionTextWrap = block.field_style?.option_text_wrap ?? true
        let optionImageScale = block.field_style?.option_image_scale ?? "contain"
        // checkmark_color decouples the indicator tint from the accent/fill; falls back to fillCol when unset.
        let checkmarkCol: Color = block.field_style?.checkmark_color.map { Color(hex: $0) } ?? fillCol

        // Colors from field_config
        let cfgOptBg = (cfg?["bg_color"]?.value as? String).map { Color(hex: $0) }
        let cfgOptText = (cfg?["text_color"]?.value as? String).map { Color(hex: $0) }
        let cfgOptBorder = (cfg?["border_color"]?.value as? String).map { Color(hex: $0) }
        let cfgSelectedBg = (cfg?["selected_bg_color"]?.value as? String).map { Color(hex: $0) }
        let cfgSelectedText = (cfg?["selected_text_color"]?.value as? String).map { Color(hex: $0) }

        let selectedBgCol = cfgSelectedBg ?? fillCol.opacity(0.15)
        let optionBg: Color = cfgOptBg
            ?? block.field_style?.background_color.map { Color(hex: $0) }
            ?? Color.clear
        let textCol: Color = cfgOptText
            ?? block.field_style?.text_color.map { Color(hex: $0) }
            ?? block.text_color.map { Color(hex: $0) }
            ?? block.style?.color.map { Color(hex: $0) }
            ?? .primary
        let selectedTextCol: Color = cfgSelectedText ?? textCol
        let unselectedBorderCol: Color = cfgOptBorder
            ?? block.field_style?.border_color.map { Color(hex: $0) }
            // EPIC-1 — neutral gray default (was accent fillCol@0.3 = the "purple-border bug").
            // Matches the other iOS field borders (#D1D5DB). Selected stays accent.
            ?? Color(hex: "#D1D5DB")

        // Selection indicator: "radio" (default), "border", "both", "none"
        let selectionIndicator = (cfg?["selection_indicator"]?.value as? String) ?? "radio"
        let showRadio = selectionIndicator == "radio" || selectionIndicator == "both"
        let showBorderHighlight = selectionIndicator == "border" || selectionIndicator == "both"
        let selectionAnimation = (cfg?["selection_animation"]?.value as? String) ?? "none"
        // Radio fill: "circle" (default), "checkmark", or any emoji/SF Symbol
        let radioFill = (cfg?["radio_fill"]?.value as? String) ?? "circle"
        // Radio position
        let radioPosition = (cfg?["radio_position"]?.value as? String) ?? "right"
        let radioOnLeft = radioPosition == "left" || radioPosition == "leading"
        // Border widths
        let selectedBorderW = CGFloat((cfgDouble(cfg?["selected_border_width"])) ?? 2)
        let unselectedBorderW = CGFloat((cfgDouble(cfg?["unselected_border_width"])) ?? 1)
        // Background opacity + blur
        let bgOpacity = CGFloat((cfgDouble(cfg?["background_opacity"])) ?? 1.0)
        let useBlur = (cfg?["blur_background"]?.value as? Bool) == true

        // Text sizes
        let defaultTitleSize = (cfgDouble(cfg?["title_font_size"])) ?? 15
        let defaultSubtitleSize = (cfgDouble(cfg?["subtitle_font_size"])) ?? 12
        let defaultSubtitleColor = (cfg?["subtitle_color"]?.value as? String).map { Color(hex: $0) }
            ?? textCol.opacity(0.65)

        // Option layout: configurable spacing + optional height. Resolution
        // order matches text/date inputs so the console "Height" control works
        // uniformly: block.element_height (px) → field_config.option_height →
        // field_config.size → field_config.field_height → nil (intrinsic).
        let optionSpacing = CGFloat((cfgDouble(cfg?["option_spacing"])) ?? 8)
        let optionHeight: CGFloat? = (cfgDouble(cfg?["option_height"]) ?? cfgDouble(cfg?["size"])).map { CGFloat($0) }
            ?? fieldHeight(block)
        // Stacked-list image size default (32). Shares the `option_image_size`
        // config with the grid path so one console slider governs both.
        let stackedImageSize = CGFloat((cfgDouble(cfg?["option_image_size"])) ?? 32)
        // SPEC-419 pass-24 — show_item_separators (console Switch, stacked only) draws a divider
        // between stacked options, honoring separator_color + separator_thickness like the list
        // variant. Off by default (cards already have borders).
        let showItemSeparators = (cfg?["show_item_separators"]?.value as? Bool) == true
        let separatorCol = (cfg?["separator_color"]?.value as? String).map { Color(hex: $0) } ?? Color(hex: "#D1D5DB")
        let separatorThickness = CGFloat((cfgDouble(cfg?["separator_thickness"])) ?? 1)

        // Select v2 — resolve the option font family once (falls back to the system font when
        // the family isn't natively available). Applied to title/subtitle/leading/trailing.
        let optFont: (CGFloat, Font.Weight) -> Font = { size, weight in
            if let fam = optionFontFamily {
                let resolved = FontResolver.resolve(fam)
                if resolved != ".AppleSystemUIFont" {
                    return .custom(resolved, size: size).weight(weight)
                }
            }
            return .system(size: size, weight: weight)
        }

        VStack(spacing: optionSpacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { pair in
                let oi = pair.offset                 // SPEC-419 — per-index parity node key
                let option = pair.element
                // SPEC-441 (#541) — section header before the first option of each category.
                if showCategoryHeader, let sec = sectionStart(options, oi) {
                    Text(sec.icon.map { "\($0) " + sec.label } ?? sec.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, oi == 0 ? 0 : 8)
                }
                let isSelected = isMultiSelect
                    ? selectedValues.contains(option.resolvedValue)
                    : selectedValue == option.resolvedValue

                // Per-option color overrides — each option can have its own highlight
                let optUnselectedBg = option.bg_color.map { Color(hex: $0) } ?? optionBg
                let optSelectedBg = option.selected_bg_color.map { Color(hex: $0) } ?? selectedBgCol
                let optSelectedText = option.selected_text_color.map { Color(hex: $0) } ?? selectedTextCol
                // Selected state always wins so `selected_text_color` applies
                // even when `title_color` is also set. Previously `title_color`
                // was resolved statically, which silently swallowed the selected
                // color and left white-on-white / black-on-black after tap.
                let optTitleColor: Color = isSelected
                    ? optSelectedText
                    : (option.title_color.map { Color(hex: $0) } ?? textCol)
                // SPEC-419 D1 legibility rule — when selected, the subtitle adopts the option's
                // selected text color so it stays readable on the selected background (fixes the
                // "subtitle invisible on the green selected row" bug). Matches the console preview.
                let optSubtitleColor: Color = isSelected
                    ? (option.selected_text_color.map { Color(hex: $0) }
                        ?? option.subtitle_color.map { Color(hex: $0) }
                        ?? defaultSubtitleColor)
                    : (option.subtitle_color.map { Color(hex: $0) } ?? defaultSubtitleColor)
                let optTitleSize: CGFloat = CGFloat(option.title_font_size ?? defaultTitleSize)
                let optSubtitleSize: CGFloat = CGFloat(option.subtitle_font_size ?? defaultSubtitleSize)
                let optTitleWeight: Font.Weight = fontWeight(option.title_font_weight ?? globalTitleWeight)

                // Per-option border color overrides
                let optBorderCol = (option.selected_border_color ?? globalSelectedBorderHex).map { Color(hex: $0) } ?? fillCol
                let optUnselBorderCol = option.border_color.map { Color(hex: $0) } ?? unselectedBorderCol

                Button {
                    toggleSelection(option: option, fieldId: fieldId)
                } label: {
                    HStack(spacing: 12) {
                        // Radio on left — indicator tint uses checkmark_color when set (else fillCol).
                        if showRadio && radioOnLeft {
                            radioIndicator(isSelected: isSelected, fillCol: checkmarkCol, radioFill: radioFill)
                        }
                        // Image with optional overlay circle — swaps between
                        // selected/unselected variants when the option defines
                        // them, otherwise falls back to the default image_url.
                        if let imgUrl = option.resolvedImageURL(isSelected: isSelected), let url = URL(string: imgUrl) {
                            imageWithOverlay(url: url, option: option, isSelected: isSelected, size: stackedImageSize, imageScale: optionImageScale)
                        }
                        if let icon = option.icon, !icon.isEmpty {
                            Text(icon)
                        }
                        // SPEC-070 EPIC-1 — leading label at the START of the row
                        if let lt = option.leading_text, !lt.isEmpty {
                            Text(lt)
                                // Parity with Android + console preview which render the leading label at 14pt.
                                .font(optFont(14, .semibold))
                                .foregroundColor(optTitleColor)
                                .accessibilityIdentifier("option.\(oi).leading_text")
                        }
                        // Title + subtitle — option_text_wrap true → full multi-line wrap;
                        // false (default) → single-line truncate (parity with the console preview).
                        VStack(alignment: ((option.text_alignment ?? globalTextAlignment) == "center" ? .center : .leading), spacing: 2) {
                            Text(option.label ?? "")
                                .font(optFont(optTitleSize, optTitleWeight))
                                .foregroundColor(optTitleColor)
                                .lineLimit(optionTextWrap ? nil : 1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: optionTextWrap)
                                .accessibilityIdentifier("option.\(oi).title")
                            if let sub = option.subtitle, !sub.isEmpty {
                                Text(sub)
                                    .font(optFont(optSubtitleSize, .regular))
                                    .foregroundColor(optSubtitleColor)
                                    .lineLimit(optionTextWrap ? nil : 1)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: optionTextWrap)
                                    .accessibilityIdentifier("option.\(oi).subtitle")
                            }
                        }
                        // EPIC-1 — when centered, expand to fill the row so .center actually
                        // centers the text (a content-sized VStack stays pinned left). Mirrors
                        // Android's Column(weight 1f) + CenterHorizontally.
                        .frame(maxWidth: (option.text_alignment ?? globalTextAlignment) == "center" ? .infinity : nil)
                        .layoutPriority(1)
                        // No trailing Spacer in the centered case — it would compete with the
                        // VStack's maxWidth:.infinity and split the row (text drifts left).
                        if (option.text_alignment ?? globalTextAlignment) != "center" {
                            Spacer(minLength: 0)
                        }
                        // SPEC-070 EPIC-1 — trailing label at the END of the row (e.g. "Casual")
                        if let tt = option.trailing_text, !tt.isEmpty {
                            Text(tt)
                                // Parity with Android + console preview which render the trailing label at a fixed 12pt.
                                .font(optFont(12, .regular))
                                .foregroundColor(optSubtitleColor)
                                .accessibilityIdentifier("option.\(oi).trailing_text")
                        }
                        // Radio on right — indicator tint uses checkmark_color when set (else fillCol).
                        if showRadio && !radioOnLeft {
                            radioIndicator(isSelected: isSelected, fillCol: checkmarkCol, radioFill: radioFill)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .leading)
                    .background {
                        ZStack {
                            if useBlur {
                                RoundedRectangle(cornerRadius: cornerR)
                                    .fill(.ultraThinMaterial)
                            }
                            RoundedRectangle(cornerRadius: cornerR)
                                .fill((isSelected ? optSelectedBg : optUnselectedBg).opacity(bgOpacity))
                            if showBorderHighlight || selectionIndicator == "radio" || selectionIndicator == "none" {
                                RoundedRectangle(cornerRadius: cornerR)
                                    .strokeBorder(
                                        isSelected ? optBorderCol : optUnselBorderCol,
                                        lineWidth: isSelected && showBorderHighlight ? selectedBorderW : unselectedBorderW
                                    )
                            }
                        }
                    }
                    // EPIC-1 — selection_animation glow: accent halo on the selected option (static
                    // glow now; pulse/sparkle motion is a future dynamic layer). Parity with Android.
                    .shadow(color: isSelected && selectionAnimation != "none" ? fillCol.opacity(0.4) : .clear,
                            radius: isSelected && selectionAnimation != "none" ? 6 : 0)
                    // SPEC-419 — row.bg parity node: a dedicated, non-propagating accessibility
                    // element behind the row content (a bare identifier on the content propagates
                    // to every child and overrides their ids). This clear overlay carries ONLY the
                    // row.bg id + the full row frame, so the harness reads the row box + samples the
                    // selected-bg colour from the screenshot at it.
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .allowsHitTesting(false)
                            .accessibilityElement()
                            .accessibilityIdentifier("option.\(oi).row.bg")
                    }
                    // SPEC-419 D5 — per-option badge (e.g. RECOMMENDED) STRADDLING the option's
                    // top border: vertical center on the border line (half above / half below),
                    // inset 12pt from the trailing edge — the premium "notch on the card edge" look.
                    .overlay(alignment: badgeAlignment(option.badge?.position)) {
                        if let badge = option.badge, let bText = badge.text, !bText.isEmpty {
                            Text(bText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(badge.text_color.map { Color(hex: $0) } ?? .white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(badge.bg_color.map { Color(hex: $0) } ?? Color.green))
                                .offset(x: badgeOffsetX(option.badge?.position), y: -9)
                                .accessibilityIdentifier("option.\(oi).badge")
                        }
                    }
                    // Whole rectangle is tappable, not just the text + radio.
                    // Without this, empty space between the radio and the
                    // trailing edge falls through to the parent scroll view.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // SPEC-419 Principle 3 — expose each per-index parity node (row.bg/title/subtitle/
                // leading_text/trailing_text/badge) as a discrete accessibility element so the
                // structural parity harness can read each box, instead of the Button merging them.
                .accessibilityElement(children: .contain)
                // SPEC-419 pass-24 — optional divider between stacked options (parity with list).
                if showItemSeparators && oi < options.count - 1 {
                    Rectangle().fill(separatorCol).frame(height: separatorThickness)
                }
            }
        }
    }

    // SPEC-419 pass-24 — parse a "W:H" aspect-ratio string into a width/height ratio
    // for `.aspectRatio(_:contentMode:)`. Returns nil for unset/malformed values so the
    // caller can fall back to a fixed height.
    private func parseAspectRatio(_ s: String?) -> CGFloat? {
        guard let s = s else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }

    // MARK: - Badge alignment helper (SPEC-070 EPIC-1)

    private func badgeAlignment(_ pos: String?) -> Alignment {
        switch pos {
        case "top_leading": return .topLeading
        case "bottom_leading": return .bottomLeading
        case "bottom_trailing": return .bottomTrailing
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .topTrailing
        }
    }

    // SPEC-419 D5 — horizontal inset for the straddling badge: 12pt in from the trailing
    // edge (trailing/default), or 12pt in from the leading edge for leading positions.
    private func badgeOffsetX(_ pos: String?) -> CGFloat {
        switch pos {
        case "top_leading", "bottom_leading", "leading": return 12
        default: return -12
        }
    }

    // MARK: - Radio indicator helper

    @ViewBuilder
    private func radioIndicator(isSelected: Bool, fillCol: Color, radioFill: String) -> some View {
        switch radioFill {
        case "checkmark":
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? fillCol : .gray.opacity(0.4))
                .font(.title3)
        case "circle":
            Image(systemName: isSelected
                ? (isMultiSelect ? "checkmark.circle.fill" : "largecircle.fill.circle")
                : "circle")
                .foregroundColor(isSelected ? fillCol : .gray.opacity(0.4))
                .font(.title3)
        default:
            // Emoji or custom SF Symbol name
            if radioFill.count <= 2 && radioFill.unicodeScalars.allSatisfy({ $0.value > 127 }) {
                // Emoji
                Text(isSelected ? radioFill : "○")
                    .font(.title3)
            } else if UIImage(systemName: radioFill) != nil {
                // SF Symbol
                Image(systemName: isSelected ? radioFill : "circle")
                    .foregroundColor(isSelected ? fillCol : .gray.opacity(0.4))
                    .font(.title3)
            } else {
                // Fallback to default circle
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? fillCol : .gray.opacity(0.4))
                    .font(.title3)
            }
        }
    }

    // MARK: - Image with overlay helper

    /// EPIC-1 — corner radius for the option image clip + overlay, by image_shape.
    /// circle (default) = size/2 → a true circle; rounded = 12; square = 0. Parity with Android.
    private func optionImageCornerRadius(_ shape: String?, size: CGFloat) -> CGFloat {
        switch shape {
        case "rounded": return 12
        case "square": return 0
        default: return size / 2
        }
    }

    @ViewBuilder
    private func imageWithOverlay(url: URL, option: InputOption, isSelected: Bool, size: CGFloat, imageScale: String = "contain") -> some View {
        let radius = optionImageCornerRadius(option.image_shape ?? globalImageShape, size: size)
        // Select v2 — option_image_scale: "cover" crops/fills the frame; "contain"/"fit" fit the
        // whole image inside so an oversized image is not cropped.
        let useFill = imageScale == "cover"
        ZStack {
            BundledAsyncImage(url: url) { image in
                useFill ? AnyView(image.resizable().scaledToFill()) : AnyView(image.resizable().scaledToFit())
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius))

            // EPIC-1 — overlay tint follows image_shape; selected uses selected_image_overlay_* (falls back to base).
            if let ovHex = (isSelected ? (option.selected_image_overlay_color ?? globalSelectedOverlayHex ?? option.image_overlay_color ?? globalOverlayHex) : (option.image_overlay_color ?? globalOverlayHex)) {
                let ovOpacity = (isSelected ? (option.selected_image_overlay_opacity ?? option.image_overlay_opacity ?? globalOverlayOpacity) : (option.image_overlay_opacity ?? globalOverlayOpacity)) ?? 0.3
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(hex: ovHex).opacity(ovOpacity))
                    .frame(width: size, height: size)
            }
        }
    }

    // MARK: - Selection toggle helper

    private func toggleSelection(option: InputOption, fieldId: String) {
        if isMultiSelect {
            if let idx = selectedValues.firstIndex(of: option.resolvedValue) {
                selectedValues.remove(at: idx)
            } else {
                // Enforce the console-configured cap on the ADD path only;
                // removing a selection must always work.
                let maxSel = cfgDouble(block.field_config?["max_selections"]).map { Int($0) }
                if let m = maxSel, selectedValues.count >= m { return }
                selectedValues.append(option.resolvedValue)
            }
            inputValues[fieldId] = selectedValues
            // SPEC-448 — record the full OPTIONS alongside the values, in selection order, so a
            // later screen can say `{{selected.<field_id>.0.label}}`. inputValues keeps carrying
            // the values alone, which is what reaches responses and therefore customer webhooks.
            let chosen = allSourcedOptions.filter { selectedValues.contains($0.resolvedValue) }
                .sorted { a, b in
                    (selectedValues.firstIndex(of: a.resolvedValue) ?? 0)
                        < (selectedValues.firstIndex(of: b.resolvedValue) ?? 0)
                }
            SelectedOptionStore.shared.record(fieldId: fieldId, options: chosen)
        } else {
            selectedValue = option.resolvedValue
            inputValues[fieldId] = option.resolvedValue
            SelectedOptionStore.shared.record(fieldId: fieldId, option: option)
        }
        // SPEC-444 (#540, #542) — picking an option that owns a sheet opens it. The choice is
        // already recorded above; the sheet only presents, so nothing else is reported.
        if let blocks = option.sheet_blocks, !blocks.isEmpty {
            sheetOption = option
        }
    }

    private func fontWeight(_ raw: String?) -> Font.Weight {
        switch raw {
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        default: return .regular
        }
    }

    // MARK: - Grid (configurable columns with toggle icons, blur, tooltip)

    @ViewBuilder
    private func gridSelectView(options: [InputOption], fieldId: String) -> some View {
        let cfg = block.field_config
        let accentHex = block.field_style?.fill_color
            ?? block.field_style?.focused_border_color
            ?? block.active_color
            ?? (AppDNA.brandAccentHex ?? "#6366F1")
        let fillCol = Color(hex: accentHex)
        let cornerR = CGFloat(block.field_style?.corner_radius ?? 10)

        let cfgOptBg = (cfg?["bg_color"]?.value as? String).map { Color(hex: $0) }
        let cfgOptText = (cfg?["text_color"]?.value as? String).map { Color(hex: $0) }
        let cfgOptBorder = (cfg?["border_color"]?.value as? String).map { Color(hex: $0) }
        let cfgSelectedBg = (cfg?["selected_bg_color"]?.value as? String).map { Color(hex: $0) }
        let cfgSelectedText = (cfg?["selected_text_color"]?.value as? String).map { Color(hex: $0) }

        let selectedBgCol = cfgSelectedBg ?? fillCol.opacity(0.15)
        let optionBg: Color = cfgOptBg
            ?? block.field_style?.background_color.map { Color(hex: $0) }
            ?? Color.clear
        let textCol: Color = cfgOptText
            ?? block.field_style?.text_color.map { Color(hex: $0) }
            ?? block.text_color.map { Color(hex: $0) }
            ?? block.style?.color.map { Color(hex: $0) }
            ?? .primary
        let selectedTextCol: Color = cfgSelectedText ?? textCol
        let unselectedBorderCol: Color = cfgOptBorder
            ?? block.field_style?.border_color.map { Color(hex: $0) }
            // EPIC-1 — neutral gray default (was accent fillCol@0.3 = the "purple-border bug").
            // Matches the other iOS field borders (#D1D5DB). Selected stays accent.
            ?? Color(hex: "#D1D5DB")

        // Grid configuration
        let colCount = max(Int((cfgDouble(cfg?["grid_columns"])) ?? 2), 1)
        let selectedBorderW = CGFloat((cfgDouble(cfg?["selected_border_width"])) ?? 2)
        let unselectedBorderW = CGFloat((cfgDouble(cfg?["unselected_border_width"])) ?? 1)
        let bgOpacity = CGFloat((cfgDouble(cfg?["background_opacity"])) ?? 1.0)
        let useBlur = (cfg?["blur_background"]?.value as? Bool) == true
        // Default toggle icons for grid (per-option overrides take priority)
        let defaultSelectedIcon = (cfg?["selected_icon"]?.value as? String)
        let defaultUnselectedIcon = (cfg?["unselected_icon"]?.value as? String)
        // Show toggle icon overlay (+/check badge). Position, size, and
        // colors are all configurable — previously hardcoded to top-right,
        // 20×20, accent fill.
        let showToggleIcon = (cfg?["show_toggle_icon"]?.value as? Bool) ?? (defaultSelectedIcon != nil)
        let toggleIconPositionKey = (cfg?["toggle_icon_position"]?.value as? String) ?? "top_trailing"
        let toggleBadgeAlignment: Alignment = {
            switch toggleIconPositionKey {
            case "top_leading": return .topLeading
            case "bottom_trailing": return .bottomTrailing
            case "bottom_leading": return .bottomLeading
            default: return .topTrailing
            }
        }()
        let toggleIconSize = CGFloat((cfgDouble(cfg?["toggle_icon_size"])) ?? 20)
        let toggleIconSelectedBg = (cfg?["toggle_icon_selected_bg_color"]?.value as? String).map { Color(hex: $0) }
        let toggleIconUnselectedBg = (cfg?["toggle_icon_unselected_bg_color"]?.value as? String).map { Color(hex: $0) }
        let toggleIconSelectedFg = (cfg?["toggle_icon_selected_fg_color"]?.value as? String).map { Color(hex: $0) }
        let toggleIconUnselectedFg = (cfg?["toggle_icon_unselected_fg_color"]?.value as? String).map { Color(hex: $0) }
        // Tooltip below grid
        let tooltipText = (cfg?["tooltip_text"]?.value as? String)
        let tooltipIcon = (cfg?["tooltip_icon"]?.value as? String) ?? "info.circle"

        // Grid layout: same configurable spacing + height as the stacked variant.
        // `fieldHeight(block)` respects the console "Height" control the same
        // way text/date inputs do.
        let optionSpacing = CGFloat((cfgDouble(cfg?["option_spacing"])) ?? 8)
        let optionHeight: CGFloat? = (cfgDouble(cfg?["option_height"]) ?? cfgDouble(cfg?["size"])).map { CGFloat($0) }
            ?? fieldHeight(block)

        // Block-level cell content alignment (default for every cell).
        // Individual options may override via option.cell_alignment.
        let blockCellAlignmentKey = (cfg?["grid_cell_alignment"]?.value as? String) ?? "center"

        // Per-option image size for grid cells (previously hardcoded 40).
        // Falls through to 40 so existing flows look unchanged.
        let gridImageSize = CGFloat((cfgDouble(cfg?["option_image_size"])) ?? 40)

        // Block-level font-size defaults (parity with stackedSelectView + console preview).
        // The grid previously ignored block-level title/subtitle sizes. The preview shrinks
        // the grid title by 0.85 (OnboardingStepPreview ~3548) — match that here; subtitle
        // keeps the raw default (no factor).
        let defaultTitleSize = (cfgDouble(cfg?["title_font_size"])) ?? 15
        let defaultSubtitleSize = (cfgDouble(cfg?["subtitle_font_size"])) ?? 12

        VStack(spacing: optionSpacing) {
            // Manual grid — LazyVGrid clips wrapped text (ignores fixedSize for row height).
            let rowCount = (options.count + colCount - 1) / colCount
            ForEach(0..<rowCount, id: \.self) { rowIdx in
                HStack(spacing: optionSpacing) {
                    ForEach(0..<colCount, id: \.self) { colIdx in
                        let optIdx = rowIdx * colCount + colIdx
                        if optIdx < options.count {
                            let option = options[optIdx]
                            let isSelected = isMultiSelect
                                ? selectedValues.contains(option.resolvedValue)
                                : selectedValue == option.resolvedValue
                            let optBorderCol = (option.selected_border_color ?? globalSelectedBorderHex).map { Color(hex: $0) } ?? fillCol
                            let optUnselBorderCol = option.border_color.map { Color(hex: $0) } ?? unselectedBorderCol
                            let optUnselectedBg = option.bg_color.map { Color(hex: $0) } ?? optionBg
                            let optSelectedBg = option.selected_bg_color.map { Color(hex: $0) } ?? selectedBgCol
                            let optSelectedText = option.selected_text_color.map { Color(hex: $0) } ?? selectedTextCol

                            // Resolve cell alignment: per-option override → block default → center.
                            let cellAlignmentKey = option.cell_alignment ?? blockCellAlignmentKey
                            let cellHAlign: HorizontalAlignment = {
                                switch cellAlignmentKey {
                                case "leading", "left": return .leading
                                case "trailing", "right": return .trailing
                                default: return .center
                                }
                            }()
                            let cellFrameAlign: Alignment = {
                                switch cellAlignmentKey {
                                case "leading", "left": return .leading
                                case "trailing", "right": return .trailing
                                default: return .center
                                }
                            }()
                            let cellTextAlign: TextAlignment = {
                                switch cellAlignmentKey {
                                case "leading", "left": return .leading
                                case "trailing", "right": return .trailing
                                default: return .center
                                }
                            }()

                            Button {
                                toggleSelection(option: option, fieldId: fieldId)
                            } label: {
                                ZStack(alignment: toggleBadgeAlignment) {
                                    VStack(alignment: cellHAlign, spacing: 6) {
                                        // Image with optional overlay — respects
                                        // selected_image_url / unselected_image_url
                                        // when the option defines state variants.
                                        if let imgUrl = option.resolvedImageURL(isSelected: isSelected), let url = URL(string: imgUrl) {
                                            // Grid images keep fill/crop (unchanged) — option_image_scale
                                            // is a stacked-list control; pin "cover" so the shared helper's
                                            // new "contain" default doesn't letterbox grid cells.
                                            imageWithOverlay(url: url, option: option, isSelected: isSelected, size: gridImageSize, imageScale: "cover")
                                        }
                                        // Icon with state change (selected/unselected variants)
                                        if let icon = option.icon, !icon.isEmpty {
                                            let resolvedIcon = isSelected
                                                ? (option.selected_icon ?? defaultSelectedIcon ?? icon)
                                                : (option.unselected_icon ?? defaultUnselectedIcon ?? icon)
                                            if UIImage(systemName: resolvedIcon) != nil {
                                                Image(systemName: resolvedIcon)
                                                    .font(.title2)
                                                    .foregroundColor(isSelected ? optSelectedText : textCol)
                                            } else {
                                                Text(resolvedIcon).font(.title2)
                                            }
                                        }
                                        // Label + subtitle
                                        Text(option.label ?? "")
                                            // Grid title honors per-option title_font_weight (parity with the
                                            // stacked branch's optTitleWeight + Android's grid) — was weightless.
                                            .font(.system(size: CGFloat(option.title_font_size ?? defaultTitleSize * 0.85), weight: fontWeight(option.title_font_weight ?? globalTitleWeight)))
                                            // Grid title honors per-option title_color for the unselected state
                                            // (parity with the stacked branch + Android grid optTitleColor); the
                                            // selected state still wins via optSelectedText.
                                            .foregroundColor(isSelected ? optSelectedText : (option.title_color.map { Color(hex: $0) } ?? textCol))
                                            .multilineTextAlignment(cellTextAlign)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let sub = option.subtitle, !sub.isEmpty {
                                            Text(sub)
                                                .font(.system(size: CGFloat(option.subtitle_font_size ?? defaultSubtitleSize)))
                                                // EPIC-1 — honor per-option subtitle_color when set (was hardcoded 0.65 alpha),
                                                // then block-level field_config.subtitle_color (parity with the stacked branch's
                                                // defaultSubtitleColor + the console preview), else the faded step text color.
                                                .foregroundColor(option.subtitle_color.map { Color(hex: $0) } ?? (cfg?["subtitle_color"]?.value as? String).map { Color(hex: $0) } ?? textCol.opacity(0.65))
                                                .multilineTextAlignment(cellTextAlign)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: cellFrameAlign)
                                    .padding(10)

                                    // Toggle icon badge. Position, size, and
                                    // colors driven by field_config so the
                                    // same grid can show a top-left "+" or a
                                    // bottom-right filled check on selected,
                                    // custom palette — not just the accent
                                    // color fallback.
                                    if showToggleIcon {
                                        let selIcon = option.selected_icon ?? defaultSelectedIcon ?? "checkmark"
                                        let unselIcon = option.unselected_icon ?? defaultUnselectedIcon ?? "plus"
                                        let badgeIcon = isSelected ? selIcon : unselIcon
                                        let badgeFg = isSelected
                                            ? (toggleIconSelectedFg ?? optSelectedText)
                                            : (toggleIconUnselectedFg ?? textCol.opacity(0.5))
                                        let badgeBg = isSelected
                                            ? (toggleIconSelectedBg ?? fillCol.opacity(0.2))
                                            : (toggleIconUnselectedBg ?? Color.clear)
                                        let glyphSize = toggleIconSize * 0.5
                                        Group {
                                            if UIImage(systemName: badgeIcon) != nil {
                                                Image(systemName: badgeIcon)
                                                    .font(.system(size: glyphSize, weight: .bold))
                                            } else {
                                                Text(badgeIcon).font(.system(size: glyphSize))
                                            }
                                        }
                                        .foregroundColor(badgeFg)
                                        .frame(width: toggleIconSize, height: toggleIconSize)
                                        .background(Circle().fill(badgeBg))
                                        .padding(6)
                                    }
                                }
                                .background {
                                    ZStack {
                                        if useBlur {
                                            RoundedRectangle(cornerRadius: cornerR)
                                                .fill(.ultraThinMaterial)
                                        }
                                        RoundedRectangle(cornerRadius: cornerR)
                                            .fill((isSelected ? optSelectedBg : optUnselectedBg).opacity(bgOpacity))
                                        RoundedRectangle(cornerRadius: cornerR)
                                            .strokeBorder(
                                                isSelected ? optBorderCol : optUnselBorderCol,
                                                lineWidth: isSelected ? selectedBorderW : unselectedBorderW
                                            )
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            // Tooltip below grid
            if let tooltip = tooltipText, !tooltip.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: tooltipIcon)
                        .font(.caption)
                        .foregroundColor(textCol.opacity(0.5))
                    Text(tooltip)
                        .font(.caption)
                        .foregroundColor(textCol.opacity(0.5))
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Slider input for single numeric value.
struct FormInputSliderBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var value: Double = 50
    // Per-step selection haptic (parity with the native Slider / Android's tick).
    @State private var sliderHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-419 pass-21 — editor authors min/max/step/default into field_config
        // (StepContentEditor :5411/:5415/:5419/:5427); top-level keys are never populated
        // for these blocks. Top-level first (back-compat), then field_config, then literal.
        let rawMin = block.min_value ?? cfgDouble(block.field_config?["min_value"]) ?? 0
        let rawMax = block.max_value_picker ?? cfgDouble(block.field_config?["max_value"]) ?? 100
        let rawStep = block.step_value ?? cfgDouble(block.field_config?["step"]) ?? 1
        // SPEC-419 pass-22 — field_config min/max/step are now authorable (were always 0...100);
        // clamp so the range can't violate ClosedRange (lower<=upper) or stall (step>0).
        let stepVal = rawStep > 0 ? rawStep : 1
        let minVal = min(rawMin, rawMax)
        let maxVal = max(rawMax, minVal + stepVal)
        let showValue = (block.field_config?["show_value"]?.value as? Bool) ?? true
        let unitStr = block.unit ?? ""
        // Mrozu QA: custom slider so track_color (inactive/max track) + thumb_color
        // are honored — the native SwiftUI Slider's `.tint` colors only the
        // active/min track + thumb. The custom track keeps step-snapping, min/max
        // clamping and the value binding, with a Slider a11y proxy for VoiceOver.
        let trackCol = Color(hex: block.field_style?.track_color ?? block.track_color ?? "#E5E7EB")
        let thumbColor = Color(hex: block.field_style?.thumb_color ?? "#FFFFFF")
        let fillCol = Color(hex: block.field_style?.fill_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                formFieldLabel(block)
                Spacer()
                if showValue {
                    // Round-24/30/31 — decide the label format by the STEP, not the value. One decimal
                    // for ANY fractional step (Round-30: was step<1, so a step of 2.5 truncated to "2";
                    // now "2.5" matching Android). Integer branch uses floor(x+0.5) — EXACTLY Kotlin
                    // roundToInt (Math.round, half toward +inf) — so it matches Android for every value
                    // incl. NEGATIVE ties (Round-31: Int(v.rounded()) is half-AWAY-from-zero, which split
                    // -2.5 into iOS "-3" vs Android "-2" for a whole step with a fractional min).
                    let formatted = (stepVal > 0 && stepVal.truncatingRemainder(dividingBy: 1) != 0)
                        ? String(format: "%.1f", value) : "\(Int((value + 0.5).rounded(.down)))"
                    Text("\(formatted)\(unitStr)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(fillCol)
                }
            }

            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let frac = maxVal > minVal ? CGFloat((value - minVal) / (maxVal - minVal)) : 0
                let clampedFrac = max(0, min(1, frac))
                ZStack(alignment: .leading) {
                    Capsule().fill(trackCol).frame(height: 4)
                    Capsule().fill(fillCol).frame(width: w * clampedFrac, height: 4)
                    Circle().fill(thumbColor)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: max(0, min(w - 24, w * clampedFrac - 12)))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = Double(max(0, min(1, g.location.x / w)))
                            let raw = minVal + f * (maxVal - minVal)
                            // MIN-anchored snapping (reachable = min + k·step) — matches
                            // the native iOS Slider(step:) + Android Slider(steps:), which
                            // both anchor at minVal, not at 0.
                            let snapped = minVal + ((raw - minVal) / stepVal).rounded() * stepVal
                            let clamped = max(minVal, min(maxVal, snapped))
                            if clamped != value {
                                value = clamped
                                // inputValues is written by .onChange(of: value) below —
                                // the single sink that also catches the a11y proxy.
                                sliderHaptic.selectionChanged()   // per-step tick (parity)
                                sliderHaptic.prepare()
                            }
                        }
                )
            }
            .frame(height: 24)
            .accessibilityRepresentation {
                Slider(value: $value, in: minVal...maxVal, step: stepVal)
            }
        }
        // Single persistence sink — catches drag AND the VoiceOver accessibility
        // Slider proxy (which mutates `value` without firing the DragGesture).
        // Restores the catch-all the native Slider's .onChange used to provide.
        .onChange(of: value) { newValue in
            inputValues[fieldId] = newValue
        }
        .onAppear {
            sliderHaptic.prepare()
            if let saved = inputValues[fieldId] as? Double { value = saved }
            else { value = block.default_picker_value ?? cfgDouble(block.field_config?["default_value"]) ?? minVal; inputValues[fieldId] = value }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Toggle (switch) input.
struct FormInputToggleBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var isOn: Bool = false

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let onColor = Color(hex: block.field_style?.toggle_on_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Mrozu QA (2026-08-03): toggle_off_color + thumb_color were decoded but the native
        // SwiftUI Toggle only exposes `.tint` (the on-track). Use a custom capsule toggle so all
        // three colors apply, with `.accessibilityRepresentation` preserving the native Switch a11y.
        // Parity with Android SwitchDefaults.colors(checked/unchecked track+thumb).
        let offColor = Color(hex: block.field_style?.toggle_off_color ?? "#E5E5EA")
        let thumbColor = Color(hex: block.field_style?.thumb_color ?? "#FFFFFF")
        let label = block.field_label ?? block.toggle_label ?? ""

        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? onColor : offColor).frame(width: 51, height: 31)
                Circle().fill(thumbColor).frame(width: 27, height: 27).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isOn)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
        }
        // Persist on ANY change to isOn — covers the visual tap AND the VoiceOver
        // accessibilityRepresentation Toggle (which flips $isOn without firing the
        // tap gesture). Persisting only in onTapGesture dropped a11y toggles.
        .onChange(of: isOn) { newValue in
            inputValues[fieldId] = newValue
        }
        .onAppear {
            if let saved = inputValues[fieldId] as? Bool { isOn = saved }
            // Honor field_config.default_value first (parity with Android, which falls
            // back to field_config["default_value"] as Boolean), then block.toggle_default.
            else { isOn = (block.field_config?["default_value"]?.value as? Bool) ?? block.toggle_default ?? false; inputValues[fieldId] = isOn }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Mrozu QA (2026-08-04, Flo s1) — standalone consent / agreement element: a tappable checkbox +
/// a rich label whose `[terms](url)` / `[privacy](url)` markdown links open natively (SwiftUI
/// `Text(AttributedString)` renders `.link` runs tappable). Persists a Bool to `inputValues[field_id]`;
/// when `field_required` is set, `RequiredFieldGate` gates the CTA until the box is checked.
/// All authoring config travels through `field_config` (parity with the Android `AgreementBlock`
/// composable and the console editor keys).
struct AgreementBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var isChecked: Bool = false

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let checkboxColor = Color(hex: (block.field_config?["checkbox_color"]?.value as? String) ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let borderColor = Color(hex: (block.field_config?["checkbox_border_color"]?.value as? String) ?? "#C7C7CC")
        let checkmarkColor = Color(hex: (block.field_config?["checkmark_color"]?.value as? String) ?? "#FFFFFF")
        let textColor = Color(hex: (block.field_config?["text_color"]?.value as? String) ?? "#8E8E93")
        let linkColor = Color(hex: (block.field_config?["link_color"]?.value as? String) ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let agreementText = (block.field_config?["agreement_text"]?.value as? String)
            ?? block.text
            ?? "I agree to the [Terms of Service](https://example.com/terms) and [Privacy Policy](https://example.com/privacy)."

        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isChecked ? checkboxColor : Color.clear)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isChecked ? checkboxColor : borderColor, lineWidth: 1.5)
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(checkmarkColor)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { isChecked.toggle() }
            .accessibilityRepresentation { Toggle(agreementText, isOn: $isChecked) }

            agreementLabel(agreementText, linkColor: linkColor, textColor: textColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Persist on any change (visual tap OR the a11y Toggle representation).
        .onChange(of: isChecked) { newValue in inputValues[fieldId] = newValue }
        .onAppear {
            if let saved = inputValues[fieldId] as? Bool { isChecked = saved }
            else { isChecked = (block.field_config?["default_checked"]?.value as? Bool) ?? false; inputValues[fieldId] = isChecked }
        }
    }

    // Plain (non-ViewBuilder) helper — builds the attributed consent copy. Kept
    // OUT of the ViewBuilder because a `for` loop can't live directly in a
    // result-builder body.
    @available(iOS 15.0, *)
    private func buildAgreementAttributed(_ text: String, linkColor: Color, textColor: Color) -> AttributedString {
        var result = AttributedString()
        // Parse per line so a `\n` in the consent copy is preserved (mirrors rich_text).
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            if var parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    if run.link != nil {
                        parsed[run.range].foregroundColor = UIColor(linkColor)
                        parsed[run.range].underlineStyle = .single
                    } else {
                        parsed[run.range].foregroundColor = UIColor(textColor)
                    }
                }
                result.append(parsed)
            } else {
                result.append(AttributedString(line))
            }
        }
        return result
    }

    @ViewBuilder
    private func agreementLabel(_ text: String, linkColor: Color, textColor: Color) -> some View {
        if #available(iOS 15.0, *) {
            Text(buildAgreementAttributed(text, linkColor: linkColor, textColor: textColor))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.footnote)
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Stepper input for incrementing/decrementing numeric value.
struct FormInputStepperBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var value: Int = 0

    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-419 pass-21 — editor authors min/max/step into field_config for the stepper
        // (StepContentEditor :5388/:5392/:5396); top-level keys are never populated.
        let rawMin = Int(block.min_value ?? cfgDouble(block.field_config?["min_value"]) ?? 0)
        let rawMax = Int(block.max_value_picker ?? cfgDouble(block.field_config?["max_value"]) ?? 100)
        let rawStep = Int(block.step_value ?? cfgDouble(block.field_config?["step"]) ?? 1)
        // SPEC-419 pass-22 — clamp the now-authorable range (min<max, step>0) to guard the ClosedRange.
        let stepVal = rawStep > 0 ? rawStep : 1
        let minVal = min(rawMin, rawMax)
        let maxVal = max(rawMax, minVal + stepVal)
        let unitStr = block.unit ?? ""

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            Stepper(value: $value, in: minVal...maxVal, step: stepVal) {
                Text("\(value)\(unitStr)")
                    .font(.body.weight(.medium))
            }
            .onChange(of: value) { newValue in
                inputValues[fieldId] = newValue
            }
        }
        .onAppear {
            if let saved = inputValues[fieldId] as? Int { value = saved }
            else { value = Int(block.default_picker_value ?? cfgDouble(block.field_config?["default_value"]) ?? Double(minVal)); inputValues[fieldId] = value }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented picker input.
struct FormInputSegmentedBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedValue: String = ""

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let options = block.field_options ?? []

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            Picker("", selection: $selectedValue) {
                ForEach(options) { option in
                    Text(option.label ?? "").tag(option.resolvedValue)
                }
            }
            .pickerStyle(.segmented)
            // Tint the selected segment with the brand/fill accent so the segmented control
            // isn't the system gray/white pill — parity with Android (fills the selected segment
            // with field_style.fill_color ?? active_color ?? brand) and the console preview.
            .tint(Color(hex: block.field_style?.fill_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1")))
            .onChange(of: selectedValue) { newValue in
                inputValues[fieldId] = newValue
            }
        }
        .onAppear {
            if let saved = inputValues[fieldId] as? String, !saved.isEmpty { selectedValue = saved }
            else if selectedValue.isEmpty, let first = options.first {
                selectedValue = first.resolvedValue
                inputValues[fieldId] = first.resolvedValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Star rating input (form variant -- reuses rating block logic).
struct FormInputRatingBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedRating: Double = 0

    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-419 pass-15 #3 — editor writes these into field_config (StepContentEditor:6312)
        // and Android promotes field_config→top-level; iOS read top-level only → all 4 dead.
        // Read field_config first, fall back to the top-level fields for back-compat.
        let cfg = block.field_config
        let fcInt: (String) -> Int? = { key in
            (cfg?[key]?.value as? Int) ?? (cfg?[key]?.value as? Double).map { Int($0) }
        }
        let fcStr: (String) -> String? = { key in cfg?[key]?.value as? String }
        let fcBool: (String) -> Bool? = { key in cfg?[key]?.value as? Bool }
        let maxStars = max(1, fcInt("max_stars") ?? block.max_stars ?? 5)  // clamp ≥1 — a field_config 0/negative would trap ForEach(1...maxStars)
        let starSz = CGFloat(fcInt("star_size").map { Double($0) } ?? block.star_size ?? 32)
        let filledCol = Color(hex: fcStr("filled_color") ?? block.filled_color ?? block.field_style?.fill_color ?? "#FBBF24")
        let emptyCol = Color(hex: fcStr("empty_color") ?? block.empty_color ?? "#D1D5DB")
        // SPEC-419 pass-19 #1 — honor allow_half (Android already renders halves via
        // block.allow_half). Read field_config first like the other rating keys, fall
        // back to top-level. Half-star render mirrors the standalone RatingFieldView.
        let allowHalf = fcBool("allow_half") ?? block.allow_half ?? false

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            HStack(spacing: 4) {
                ForEach(1...maxStars, id: \.self) { index in
                    let starState: Double = {
                        if selectedRating >= Double(index) { return 1.0 }
                        if allowHalf && selectedRating >= Double(index) - 0.5 { return 0.5 }
                        return 0.0
                    }()
                    Image(systemName: starState == 1.0 ? "star.fill" : (starState == 0.5 ? "star.leadinghalf.filled" : "star"))
                        .font(.system(size: starSz))
                        .foregroundColor(starState > 0 ? filledCol : emptyCol)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { dg in
                                    let isLeftHalf = dg.location.x < starSz / 2
                                    let raw: Double = (allowHalf && isLeftHalf) ? Double(index) - 0.5 : Double(index)
                                    selectedRating = allowHalf ? raw : Double(Int(raw))
                                    inputValues[fieldId] = selectedRating
                                }
                        )
                }
            }
        }
        .onAppear {
            let fieldId = block.field_id ?? block.id
            if let saved = inputValues[fieldId] as? Double { selectedRating = saved }
            else { selectedRating = block.default_rating ?? 0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Round-29/30/31 — range-slider value-label formatter: one decimal for ANY fractional step (Round-30:
/// was step<1, so a step of 2.5 truncated to "2"; now "2.5", matching Android + the single slider).
/// Integer branch uses floor(v+0.5) — EXACTLY Kotlin roundToInt (half toward +inf) — so it matches
/// Android for every value incl. negative ties (Round-31: v.rounded() is half-away-from-zero, splitting
/// -2.5 into iOS "-3" vs Android "-2").
private func rangeSliderValueText(_ v: Double, _ step: Double) -> String {
    (step > 0 && step.truncatingRemainder(dividingBy: 1) != 0)
        ? String(format: "%.1f", v) : "\(Int((v + 0.5).rounded(.down)))"
}

/// Range slider (dual-thumb) input.
struct FormInputRangeSliderBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var lowValue: Double = 0
    @State private var highValue: Double = 100

    var body: some View {
        let fieldId = block.field_id ?? block.id
        // SPEC-419 pass-21 — editor authors min/max into field_config for the range slider
        // (StepContentEditor :5411/:5415); top-level keys are never populated.
        let rawMin = block.min_value ?? cfgDouble(block.field_config?["min_value"]) ?? 0
        let rawMax = block.max_value_picker ?? cfgDouble(block.field_config?["max_value"]) ?? 100
        // SPEC-419 pass-22 — clamp the now-authorable range so minVal...maxVal can't trap (min<max).
        let minVal = min(rawMin, rawMax)
        let maxVal = max(rawMax, minVal + 1)
        // Round-24/25/26 — honor the authored step (default 1.0) like the single slider + Android, which
        // snap both thumbs to the step grid. iOS ignored step here entirely → captured continuous values
        // (33.7) while Android snapped (34.0). The console writes the step under field_config["step"]
        // (NOT "step_value"). CLAMP > 0 like every sibling slider: the console number input has no min,
        // so a cleared/negative step yields 0, and `Slider(step: 0)` computes NaN → corrupt {min,max}
        // response + a potential fatal NaN→Int. Android already guards `step > 0`.
        let stepVal: Double = { let s = block.step_value ?? cfgDouble(block.field_config?["step"]) ?? 1; return s > 0 ? s : 1 }()
        let unitStr = block.unit ?? ""
        let fillCol = Color(hex: block.field_style?.fill_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Mrozu QA — custom track so track_color (inactive track) + thumb_color are honored on the
        // range slider too (native Slider().tint only colors the active/min track + thumb). Parity
        // with the single FormInputSliderBlock + Android's range slider track_color + the editor's
        // Track/Fill/Thumb controls for input_range_slider.
        let trackCol = Color(hex: block.field_style?.track_color ?? block.track_color ?? "#E5E7EB")
        let thumbColor = Color(hex: block.field_style?.thumb_color ?? "#FFFFFF")

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                formFieldLabel(block)
                Spacer()
                // Round-29 — show one decimal for a fractional step (matches Android + the single slider);
                // `Int()` silently dropped the half-step the user selected (2.5 rendered "2").
                Text("\(rangeSliderValueText(lowValue, stepVal))\(unitStr) - \(rangeSliderValueText(highValue, stepVal))\(unitStr)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(fillCol)
            }

            VStack(spacing: 4) {
                HStack {
                    Text((block.field_config?["min_label"]?.value as? String) ?? "Min")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    // Custom track/fill/thumb mirroring FormInputSliderBlock so track_color +
                    // thumb_color apply; drag snaps to the step grid (min-anchored) and the
                    // VStack's .onChange clamp keeps low <= high.
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let frac = maxVal > minVal ? CGFloat((lowValue - minVal) / (maxVal - minVal)) : 0
                        let clampedFrac = max(0, min(1, frac))
                        ZStack(alignment: .leading) {
                            Capsule().fill(trackCol).frame(height: 4)
                            Capsule().fill(fillCol).frame(width: w * clampedFrac, height: 4)
                            Circle().fill(thumbColor)
                                .frame(width: 24, height: 24)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .offset(x: max(0, min(w - 24, w * clampedFrac - 12)))
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let f = Double(max(0, min(1, g.location.x / w)))
                                    let raw = minVal + f * (maxVal - minVal)
                                    let snapped = minVal + ((raw - minVal) / stepVal).rounded() * stepVal
                                    lowValue = max(minVal, min(maxVal, snapped))
                                }
                        )
                    }
                    .frame(height: 24)
                    .accessibilityRepresentation {
                        Slider(value: $lowValue, in: minVal...maxVal, step: stepVal)
                    }
                }
                HStack {
                    Text((block.field_config?["max_label"]?.value as? String) ?? "Max")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let frac = maxVal > minVal ? CGFloat((highValue - minVal) / (maxVal - minVal)) : 0
                        let clampedFrac = max(0, min(1, frac))
                        ZStack(alignment: .leading) {
                            Capsule().fill(trackCol).frame(height: 4)
                            Capsule().fill(fillCol).frame(width: w * clampedFrac, height: 4)
                            Circle().fill(thumbColor)
                                .frame(width: 24, height: 24)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .offset(x: max(0, min(w - 24, w * clampedFrac - 12)))
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let f = Double(max(0, min(1, g.location.x / w)))
                                    let raw = minVal + f * (maxVal - minVal)
                                    let snapped = minVal + ((raw - minVal) / stepVal).rounded() * stepVal
                                    highValue = max(minVal, min(maxVal, snapped))
                                }
                        )
                    }
                    .frame(height: 24)
                    .accessibilityRepresentation {
                        Slider(value: $highValue, in: minVal...maxVal, step: stepVal)
                    }
                }
            }
            .onChange(of: lowValue) { _ in
                if lowValue > highValue { highValue = lowValue }
                inputValues[fieldId] = ["min": lowValue, "max": highValue]
            }
            .onChange(of: highValue) { _ in
                if highValue < lowValue { lowValue = highValue }
                inputValues[fieldId] = ["min": lowValue, "max": highValue]
            }
        }
        .onAppear {
            if let saved = inputValues[fieldId] as? [String: Any] {
                lowValue = saved["min"] as? Double ?? block.min_value ?? cfgDouble(block.field_config?["min_value"]) ?? 0
                highValue = saved["max"] as? Double ?? block.max_value_picker ?? cfgDouble(block.field_config?["max_value"]) ?? 100
            } else {
                lowValue = block.min_value ?? cfgDouble(block.field_config?["min_value"]) ?? 0
                highValue = block.max_value_picker ?? cfgDouble(block.field_config?["max_value"]) ?? 100
                inputValues[fieldId] = ["min": lowValue, "max": highValue]
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chips/tag input -- multi-select toggleable chips.
struct FormInputChipsBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    // Round-11 Finding 3 — an ordered [String] (append-on-select, acting as an ordered set) so the
    // written array preserves SELECTION order, matching Android's LinkedHashSet. A Swift Set is
    // hash-ordered and non-deterministic across runs, so `Array(Set)` produced arbitrary ordering.
    @State private var selectedValues: [String] = []

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let options = block.field_options ?? []
        let fillCol = Color(hex: block.field_style?.fill_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Console writes the cap as `max_chips` (Max Chips slider); `max_selections`
        // kept as a fallback for older/imported configs.
        let maxSelections = cfgDouble(block.field_config?["max_chips"]).map { Int($0) } ?? cfgDouble(block.field_config?["max_selections"]).map { Int($0) }

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            // FlowLayout approximation using wrapping HStack
            FlowLayoutView(spacing: 8) {
                ForEach(options) { option in
                    let isSelected = selectedValues.contains(option.resolvedValue)
                    Button {
                        if isSelected {
                            selectedValues.removeAll { $0 == option.resolvedValue }
                        } else {
                            if let max = maxSelections, selectedValues.count >= max {
                                return // At max selections
                            }
                            selectedValues.append(option.resolvedValue)
                        }
                        inputValues[fieldId] = selectedValues
                    } label: {
                        Text(option.label ?? "")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? fillCol : Color.gray.opacity(0.1))
                            .foregroundColor(isSelected ? .white : .primary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(isSelected ? fillCol : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let fieldId = block.field_id ?? block.id
            if let saved = inputValues[fieldId] as? [String] { selectedValues = saved }
        }
    }
}

/// Color picker -- grid of preset color swatches.
struct FormInputColorBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedColor: String = ""

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let presetColors: [String] = {
            if let colors = block.field_config?["preset_colors"]?.value as? [String] {
                return colors
            }
            return ["#EF4444", "#F97316", "#EAB308", "#22C55E", "#3B82F6", (AppDNA.brandAccentHex ?? "#6366F1"), "#A855F7", "#EC4899", "#000000", "#6B7280"]
        }()

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(presetColors, id: \.self) { color in
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .stroke(selectedColor == color ? Color.primary : Color.clear, lineWidth: 2)
                                .padding(2)
                        )
                        .onTapGesture {
                            selectedColor = color
                            inputValues[fieldId] = color
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let fieldId = block.field_id ?? block.id
            if let saved = inputValues[fieldId] as? String { selectedColor = saved }
        }
    }
}

/// Placeholder for complex inputs (location, image_picker, signature) -- renders icon + label.
struct FormInputPlaceholderBlock: View {
    let block: ContentBlock
    let iconName: String
    let label: String

    var body: some View {
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(16)
            .background(Color(hex: block.field_style?.background_color ?? "transparent"))
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AC-046: Location Input with MKLocalSearchCompleter autocomplete

/// Observable wrapper around MKLocalSearchCompleter for location autocomplete.
class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func search(query: String) {
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = Array(completer.results.prefix(5))
            self.isSearching = false
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.results = []
            self.isSearching = false
        }
    }
}

/// Location input with autocomplete powered by MKLocalSearchCompleter.
/// User types to search, selects a result, and the formatted address + coordinates are stored.
struct FormInputLocationPlaceholderBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var text: String = ""
    @State private var showResults = false
    @State private var isFocused: Bool = false
    @StateObject private var searchCompleter = LocationSearchCompleter()

    /// True while we're restoring text from saved inputValues so the
    /// .onChange(of: text) handler doesn't clobber the full dict with a
    /// raw string.
    @State private var isRestoringFromSaved = false

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        let borderWidth = CGFloat(block.field_style?.border_width ?? 1)
        // Same default background as FormInputTextBlock — location must look
        // like any other iOS text field, not a differently-styled widget.
        let bgColor = Color(hex: block.field_style?.background_color ?? "transparent")
        // Always use UIKitTextField for location — SwiftUI's TextField
        // triggers ScrollView auto-scroll-to-focus which pushes the field up
        // when the keyboard appears. UIKit fields don't participate in that.
        let keyboardAppearanceRaw = block.field_config?["keyboard_appearance"]?.value as? String
        // Show prefix location icon? (default true — user can opt out per-block)
        let showIcon = (block.field_config?["show_prefix_icon"]?.value as? Bool) ?? true

        // Inline layout — dropdown is a real VStack child, which grows the
        // location block downward (siblings BELOW get pushed; siblings ABOVE
        // stay). The parent ScrollView has .ignoresSafeArea(.keyboard) to
        // prevent keyboard auto-scroll from repositioning above siblings.
        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            HStack(spacing: 8) {
                if showIcon {
                    Image(systemName: "location.fill")
                        .foregroundColor(.secondary)
                }
                UIKitTextField(
                    text: $text,
                    placeholder: block.field_placeholder ?? "Search location...",
                    keyboardAppearance: .from(keyboardAppearanceRaw),
                    autocorrection: false,
                    autocapitalization: .words,
                    returnKeyType: .search,
                    textColor: block.field_style?.text_color.map { UIColor(Color(hex: $0)) },
                    placeholderColor: block.field_style?.placeholder_color.map { UIColor(Color(hex: $0)) },
                    isFocused: Binding(
                        get: { isFocused },
                        set: { isFocused = $0 }
                    )
                )
                .frame(height: 24)
                .onChange(of: text) { newValue in
                    // Skip the onChange that fires when we programmatically set
                    // text from a saved dict — we must NOT overwrite the full
                    // dict with the raw string. Same when a suggestion is
                    // selected (we set text before storing the dict).
                    if isRestoringFromSaved { return }
                    searchCompleter.search(query: newValue)
                    showResults = isFocused && !newValue.isEmpty
                    // Only store the raw string if the user is ACTIVELY typing.
                    // Once a suggestion is selected, selectResult writes the
                    // structured dict and this onChange won't fire again until
                    // the user starts typing over it.
                    inputValues[fieldId] = newValue
                }
                if !text.isEmpty {
                    Button {
                        text = ""
                        showResults = false
                        inputValues[fieldId] = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
                if searchCompleter.isSearching {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(12)
            .frame(minHeight: fieldHeight(block))
            .background(bgColor)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )

            if showResults && !searchCompleter.results.isEmpty {
                // Dropdown styling from field_config
                let cfg = block.field_config
                let ddBgHex = cfg?["dropdown_bg_color"]?.value as? String
                let ddTextHex = cfg?["dropdown_text_color"]?.value as? String
                let ddSubtextHex = cfg?["dropdown_subtext_color"]?.value as? String
                let ddIconHex = cfg?["dropdown_icon_color"]?.value as? String
                let ddIconBgHex = cfg?["dropdown_icon_bg_color"]?.value as? String
                let ddIconBgGrad = cfg?["dropdown_icon_bg_gradient"]?.value as? [String: Any]
                let ddOpacity = cfgDouble(cfg?["dropdown_opacity"]) ?? 1.0
                let ddFontSize = cfgDouble(cfg?["dropdown_font_size"]) ?? 14
                let ddSubFontSize = cfgDouble(cfg?["dropdown_sub_font_size"]) ?? 12
                let ddRowHeight = cfgDouble(cfg?["dropdown_row_height"])
                let ddIconSize = cfgDouble(cfg?["dropdown_icon_size"]) ?? 24

                let ddBg: Color = ddBgHex.map { Color(hex: $0) } ?? Color(.systemBackground)
                let ddText: Color = ddTextHex.map { Color(hex: $0) } ?? .primary
                let ddSubtext: Color = ddSubtextHex.map { Color(hex: $0) } ?? .secondary
                let ddIcon: Color = ddIconHex.map { Color(hex: $0) } ?? .white

                VStack(alignment: .leading, spacing: 0) {
                    let visible = Array(searchCompleter.results.prefix(5).enumerated())
                    ForEach(visible, id: \.offset) { idx, result in
                        Button {
                            selectResult(result, fieldId: fieldId)
                        } label: {
                            HStack(spacing: 8) {
                                // Icon with optional gradient background
                                ZStack {
                                    if let grad = ddIconBgGrad,
                                       let colors = grad["colors"] as? [String], colors.count >= 2 {
                                        let angle = grad["angle"] as? Double ?? 180
                                        let gradColors = colors.map { Color(hex: $0) }
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(LinearGradient(
                                                colors: gradColors,
                                                startPoint: gradientStart(angle),
                                                endPoint: gradientEnd(angle)
                                            ))
                                    } else if let iconBg = ddIconBgHex {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(hex: iconBg))
                                    }
                                    Image(systemName: "mappin")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(ddIcon)
                                }
                                .frame(width: CGFloat(ddIconSize), height: CGFloat(ddIconSize))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.system(size: CGFloat(ddFontSize)))
                                        .foregroundColor(ddText)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.system(size: CGFloat(ddSubFontSize)))
                                            .foregroundColor(ddSubtext)
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: ddRowHeight.map { CGFloat($0) }, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, ddRowHeight != nil ? 0 : 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < visible.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(ddBg.opacity(ddOpacity))
                .cornerRadius(cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isFocused) { focused in
            // Hide dropdown immediately when focus is lost (tap outside)
            if !focused {
                showResults = false
            }
        }
        .onAppear {
            // Restore previously entered/selected value WITHOUT clobbering the
            // stored dict. Uses isRestoringFromSaved to bypass the onChange(of: text)
            // handler so the full structured dict (lat/lng/city/state/country/
            // timezone) survives back-navigation.
            let fieldId = block.field_id ?? block.id
            if let savedDict = inputValues[fieldId] as? [String: Any] {
                // Full structured dict — rebuild display text from city/state/country
                let display = Self.formatLocationDisplay(from: savedDict)
                    ?? (savedDict["address"] as? String)
                    ?? ""
                if !display.isEmpty && text != display {
                    isRestoringFromSaved = true
                    text = display
                    // Re-yield so onChange(of:text) fires with isRestoringFromSaved
                    // still true, then clear the flag.
                    DispatchQueue.main.async {
                        isRestoringFromSaved = false
                    }
                }
                Log.debug("[LocationBlock] restored saved dict: \(savedDict)")
            } else if let savedStr = inputValues[fieldId] as? String, !savedStr.isEmpty {
                if text != savedStr {
                    isRestoringFromSaved = true
                    text = savedStr
                    DispatchQueue.main.async {
                        isRestoringFromSaved = false
                    }
                }
            }
        }
    }

    /// Formats a saved location dict as "City / State, Country" (with state)
    /// or "City, Country" (no state). Returns nil if city is missing.
    static func formatLocationDisplay(from dict: [String: Any]) -> String? {
        let city = (dict["city"] as? String) ?? ""
        let state = (dict["state"] as? String) ?? ""
        let country = (dict["country"] as? String) ?? ""
        guard !city.isEmpty else { return nil }
        if !state.isEmpty && !country.isEmpty {
            return "\(city) / \(state), \(country)"
        } else if !country.isEmpty {
            return "\(city), \(country)"
        } else {
            return city
        }
    }

    private func selectResult(_ result: MKLocalSearchCompletion, fieldId: String) {
        showResults = false
        isFocused = false  // dismiss keyboard + hide dropdown reliably

        // Resolve full placemark via MKLocalSearch to get city/state/country
        let searchRequest = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: searchRequest)
        search.start { response, _ in
            guard let mapItem = response?.mapItems.first else {
                // Fallback: store minimal data
                let fallback = result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
                isRestoringFromSaved = true
                text = fallback
                DispatchQueue.main.async { isRestoringFromSaved = false }
                inputValues[fieldId] = ["address": fallback]
                Log.debug("Location resolved without a placemark")
                return
            }
            let placemark = mapItem.placemark
            let coordinate = placemark.coordinate
            let city = placemark.locality ?? placemark.subAdministrativeArea ?? ""
            let state = placemark.administrativeArea ?? ""
            let country = placemark.country ?? ""

            // IMPORTANT: MKLocalSearch's MKPlacemark.timeZone is USUALLY NIL
            // for text-search results. Falling back to TimeZone.current returns
            // the DEVICE's timezone (e.g. Europe/Warsaw) — not the LOCATION's
            // timezone. To get the accurate timezone for the selected location,
            // we reverse-geocode via CLGeocoder which reliably populates
            // CLPlacemark.timeZone.
            //
            // Strategy: if MKPlacemark has a timezone, use it immediately.
            // Otherwise, update the field text + lat/lng/city/state/country
            // synchronously (fast UX), then fetch the timezone async and
            // overwrite the dict once we have it. The user won't be able to
            // advance for a few hundred ms, which is fine.

            // Helper that stores the dict + updates display + prints debug
            let finalize: (String) -> Void = { resolvedTimezone in
                let locationDict: [String: Any] = [
                    "city": city,
                    "state": state,
                    "country": country,
                    "timezone": resolvedTimezone,
                    "latitude": coordinate.latitude,
                    "longitude": coordinate.longitude,
                ]
                inputValues[fieldId] = locationDict

                let display = Self.formatLocationDisplay(from: locationDict) ?? result.title
                isRestoringFromSaved = true
                text = display
                DispatchQueue.main.async { isRestoringFromSaved = false }

                // Never log city/state/country/coordinates. A raw `print` is
                // unconditional and reaches release builds.
                Log.debug("Location selected (timezone resolved: \(!resolvedTimezone.isEmpty))")
            }

            if let tz = placemark.timeZone?.identifier {
                // Rare happy path — placemark already has timezone
                finalize(tz)
            } else {
                // Reverse geocode to fetch the LOCATION's timezone (not device tz)
                let geocoder = CLGeocoder()
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                geocoder.reverseGeocodeLocation(location) { placemarks, error in
                    let tz = placemarks?.first?.timeZone?.identifier ?? "UTC"
                    if let error = error {
                        Log.warning("Reverse geocode timezone lookup failed: \(error.localizedDescription), defaulting to UTC")
                    }
                    finalize(tz)
                }
            }
        }
    }
}

// MARK: - AC-048: Image Picker with PhotosPicker (iOS 16+)

/// Image picker using PhotosPicker. Stores selected image data as base64 in inputValues.
struct FormInputImagePickerPlaceholderBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var thumbnailImage: UIImage? = nil

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        let borderWidth = CGFloat(block.field_style?.border_width ?? 1)

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            PhotosPicker(selection: $selectedItem, matching: .images) {
                if let thumbnailImage = thumbnailImage {
                    // Show selected image thumbnail
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(borderColor, lineWidth: borderWidth)
                        )
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                                .padding(8)
                        }
                } else {
                    // Empty state -- dashed border tap target
                    HStack(spacing: 8) {
                        Image(systemName: "photo.fill")
                            .foregroundColor(.secondary)
                        Text("Tap to pick image")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(16)
                    .background(Color(hex: block.field_style?.background_color ?? "transparent"))
                    .cornerRadius(cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(borderColor, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                    )
                }
            }
            .buttonStyle(.plain)
            .onChange(of: selectedItem) { newItem in
                guard let newItem = newItem else { return }
                newItem.loadTransferable(type: Data.self) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let data):
                            if let data = data {
                                self.selectedImageData = data
                                self.thumbnailImage = UIImage(data: data)
                                // Store base64 string and metadata in inputValues
                                let base64 = data.base64EncodedString()
                                inputValues[fieldId] = [
                                    "data": base64,
                                    "size": data.count,
                                    "mime_type": "image/jpeg",
                                ]
                            }
                        case .failure:
                            break
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AC-051: Signature Input (interactive Canvas with touch drawing)

/// Interactive signature pad with basic touch/drag drawing.
struct FormInputSignatureBlock: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var lines: [[CGPoint]] = []
    @State private var currentLine: [CGPoint] = []

    var body: some View {
        let fieldId = block.field_id ?? block.id
        let borderColor = Color(hex: block.field_style?.border_color ?? "#D1D5DB")
        let cornerRadius = CGFloat(block.field_style?.corner_radius ?? 8)
        // SPEC-419 pass-15 #15 — honor field_config.stroke_color (editor + preview); was hardcoded .primary.
        let strokeCol: Color = (block.field_config?["stroke_color"]?.value as? String).map { Color(hex: $0) } ?? .primary
        // SPEC-419 pass-16 #2 — honor field_config.stroke_width (editor default 2); was hardcoded 2.
        let strokeW: CGFloat = CGFloat(cfgDouble(block.field_config?["stroke_width"]) ?? 2)

        VStack(alignment: .leading, spacing: 6) {
            formFieldLabel(block)

            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    for line in lines + [currentLine] {
                        guard line.count > 1 else { continue }
                        var path = Path()
                        path.move(to: line[0])
                        for point in line.dropFirst() {
                            path.addLine(to: point)
                        }
                        context.stroke(path, with: .color(strokeCol), lineWidth: strokeW)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Color(hex: block.field_style?.background_color ?? "transparent"))
                .cornerRadius(cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            currentLine.append(value.location)
                        }
                        .onEnded { _ in
                            lines.append(currentLine)
                            currentLine = []
                            inputValues[fieldId] = "signed"
                        }
                )

                // Clear button
                if !lines.isEmpty {
                    Button {
                        lines = []
                        currentLine = []
                        inputValues.removeValue(forKey: fieldId)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }
            }

            if lines.isEmpty {
                Text("Draw your signature above")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Flow Layout (SPEC-089d Phase 3 -- for chips block)

/// EPIC-1 — true content-hugging flow layout (chips wrap by their own width, left→right).
/// iOS 16 Layout protocol; mirrors Android FlowRow so the bubble/chip select matches.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? max(0, x - spacing) : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            // Place each chip at its natural content-hugging size (mirrors Android FlowRow).
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Simple flow layout approximation using LazyVGrid with adaptive columns.
/// Wraps children to next line when they exceed available width.
struct FlowLayoutView<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Use adaptive grid items as a flow-layout approximation
        let columns = [GridItem(.adaptive(minimum: 60, maximum: .infinity), spacing: spacing)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            content()
        }
    }
}

// SPEC-419 pass-24 — size an image-tile by an explicit aspect ratio (width × ratio) when
// `tile_aspect_ratio` is set, else fall back to a fixed `tile_height`.
private extension View {
    @ViewBuilder
    func tileSize(aspectRatio: CGFloat?, height: CGFloat) -> some View {
        if let ar = aspectRatio {
            self.aspectRatio(ar, contentMode: .fit)
        } else {
            self.frame(height: height)
        }
    }
}

// MARK: - SPEC-444 (#540, #542) — the option bottom sheet

/// Presents an option's `sheet_blocks` through the ordinary content-block renderer.
///
/// One engine, two authoring presets: the console seeds a chooser set (slider / toggle /
/// preview / CTA) or a detail set (badge / heading / media / CTA), and the author edits from
/// there. That is what the reporter asked for on #542 — one mechanism, as long as they choose
/// what goes on it.
///
/// Presentation-only by design: values set inside are NOT reported to the host app. The
/// reporter confirmed only the option choice matters, which is why there is no response
/// plumbing here on any platform.
struct OptionBottomSheetView: View {
    let option: InputOption
    let onDismiss: () -> Void

    @State private var sheetToggles: [String: Bool] = [:]
    @State private var sheetInputs: [String: Any] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle — the affordance in the reporter's recording.
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            ScrollView {
                ContentBlockRendererView(
                    blocks: option.sheet_blocks ?? [],
                    onAction: { action, _ in
                        // The CTA closes the sheet; the flow continues underneath, where the
                        // option is already selected.
                        if action == "next" || action == "continue" || action == "dismiss" { onDismiss() }
                    },
                    toggleValues: $sheetToggles,
                    inputValues: $sheetInputs
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
