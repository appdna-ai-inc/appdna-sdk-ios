import SwiftUI

/// Form step: renders native input controls for each FormField (SPEC-082).
struct FormStepView: View {
    let config: StepConfig
    let onNext: ([String: Any]?) -> Void
    var apiClient: APIClient?
    /// Previously saved responses for this step (for back-navigation restoration)
    var savedValues: [String: Any]? = nil

    @State private var values: [String: Any] = [:]
    @State private var errors: [String: String] = [:]
    @State private var showValidationToast = false

    private var fields: [FormField] { config.fields ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    if let imageUrl = config.image_url, let url = URL(string: imageUrl) {
                        BundledAsyncPhaseImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    if let title = config.title {
                        Text(title.interpolated())
                            .font(.title2.bold())
                    }

                    if let subtitle = config.subtitle {
                        Text(subtitle.interpolated())
                            .font(.body)
                            .foregroundColor(.secondary)
                    }

                    // Fields
                    ForEach(visibleFields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            if field.type != .toggle {
                                fieldLabel(field)
                            }
                            fieldControl(field)
                            if let error = errors[field.id] {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboardCompat()
            // Prevent keyboard auto-scroll from repositioning siblings above
            // the focused field — critical for location field's inline
            // dropdown so Partner's name / other fields don't get pushed up.
            .ignoresSafeArea(.keyboard, edges: .bottom)

            // CTA — configurable styling via element_style
            let ctaBg = config.element_style?.background?.color ?? (AppDNA.brandAccentHex ?? "#6366F1")
            let ctaDisabledBg = config.element_style?.opacity != nil
                ? ctaBg // Use main color with reduced opacity
                : nil as String?
            let ctaRadius = config.element_style?.corner_radius ?? 14

            Button(action: {
                if canSubmit {
                    handleSubmit()
                } else {
                    withAnimation { showValidationToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { showValidationToast = false }
                    }
                }
            }) {
                Text((config.cta_text ?? "Continue").interpolated())
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canSubmit ? Color(hex: ctaBg) : Color(hex: ctaDisabledBg ?? ctaBg).opacity(0.4))
                    .cornerRadius(CGFloat(ctaRadius))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .overlay(alignment: .bottom) {
            if showValidationToast {
                let missingField = visibleFields.first(where: { f in
                    guard f.required else { return false }
                    let v = values[f.id]
                    return v == nil || (v as? String)?.isEmpty == true
                })
                Text("Please fill in \(missingField?.label ?? "required fields")")
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
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        .onAppear {
            restoreSavedValues()
            initializeDefaults()
        }
    }

    // MARK: - Field visibility

    private var visibleFields: [FormField] {
        fields.filter { field in
            guard let dep = field.depends_on, let depFieldId = dep.field_id else { return true }
            let depValue = values[depFieldId]
            switch dep.operator_type ?? "" {
            case "not_empty", "is_set":
                guard let val = depValue else { return false }
                return "\(val)" != ""
            case "empty":
                guard let val = depValue else { return true }
                return "\(val)" == ""
            case "equals":
                guard let expected = dep.value?.value else { return false }
                return "\(depValue ?? "")" == "\(expected)"
            case "not_equals":
                guard let expected = dep.value?.value else { return true }
                return "\(depValue ?? "")" != "\(expected)"
            case "contains":
                guard let expected = dep.value?.value else { return false }
                return "\(depValue ?? "")".contains("\(expected)")
            case "gt":
                guard let expected = dep.value?.value as? Double,
                      let actual = depValue as? Double else { return false }
                return actual > expected
            case "lt":
                guard let expected = dep.value?.value as? Double,
                      let actual = depValue as? Double else { return false }
                return actual < expected
            default:
                return true
            }
        }
    }

    private var canSubmit: Bool {
        for field in visibleFields where field.required {
            let value = values[field.id]
            if value == nil { return false }
            if let str = value as? String, str.isEmpty { return false }
        }
        return true
    }

    // MARK: - Restore saved values (back navigation)

    private func restoreSavedValues() {
        guard let saved = savedValues else { return }
        // Restore each field value from previously saved step responses
        for field in fields {
            if let val = saved[field.id], values[field.id] == nil {
                values[field.id] = val
            }
        }
    }

    // MARK: - Default values

    private func initializeDefaults() {
        // SPEC-083: Apply fieldDefaults from StepConfigOverride first
        if let fieldDefaults = config.field_defaults {
            for (fieldId, val) in fieldDefaults {
                if values[fieldId] == nil {
                    values[fieldId] = val.value
                }
            }
        }
        // Then apply per-field default_value (doesn't override hook-injected defaults)
        for field in fields {
            if let defaultVal = field.config?.default_value?.value {
                if values[field.id] == nil {
                    values[field.id] = defaultVal
                }
            }
        }
    }

    // MARK: - Label

    private func fieldLabel(_ field: FormField) -> some View {
        HStack(spacing: 2) {
            Text((field.label ?? "").interpolated())
                .font(.subheadline.weight(.medium))
            if field.required {
                Text("*")
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Field control dispatcher

    @ViewBuilder
    private func fieldControl(_ field: FormField) -> some View {
        switch field.type {
        case .text, .email, .phone:
            textField(field)
        case .url:
            UrlFieldView(field: field, value: bindingFor(field))
        case .password:
            PasswordFieldView(field: field, value: bindingFor(field))
        case .textarea:
            textArea(field)
        case .number:
            numberField(field)
        case .date:
            datePicker(field)
        case .time:
            timePicker(field)
        case .datetime:
            dateTimePicker(field)
        case .select:
            selectField(field)
        case .slider:
            sliderField(field)
        case .toggle:
            toggleField(field)
        case .stepper:
            stepperField(field)
        case .segmented:
            segmentedField(field)
        case .location:
            LocationFieldView(
                field: field,
                value: Binding(
                    get: { values[field.id] },
                    set: { values[field.id] = $0; errors[field.id] = nil }
                ),
                apiClient: apiClient
            )
        case .rating:
            RatingFieldView(field: field, value: bindingFor(field))
        case .range_slider:
            RangeSliderFieldView(field: field, value: bindingFor(field))
        case .image_picker:
            ImagePickerFieldView(field: field, value: bindingFor(field))
        case .color:
            ColorFieldView(field: field, value: bindingFor(field))
        case .multiline_chips:
            MultilineChipsFieldView(field: field, value: bindingFor(field))
        case .signature:
            SignatureFieldView(field: field, value: bindingFor(field))
        }
    }

    /// Generic binding helper that drops the per-field error on any change.
    /// Used by the SPEC-401-A renderer views which all need this same pattern.
    private func bindingFor(_ field: FormField) -> Binding<Any?> {
        Binding(
            get: { values[field.id] },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
    }

    // MARK: - Text

    private func textField(_ field: FormField) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] as? String ?? "" },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        return TextField((field.placeholder ?? "").interpolated(), text: binding)
            .textFieldStyle(.roundedBorder)
            .keyboardType(keyboardType(for: field))
            .autocapitalization(autocap(for: field))
    }

    private func textArea(_ field: FormField) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] as? String ?? "" },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        return TextEditor(text: binding)
            .frame(minHeight: 80, maxHeight: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
    }

    private func numberField(_ field: FormField) -> some View {
        let binding = Binding<String>(
            get: {
                if let num = values[field.id] as? Double {
                    let places = field.config?.decimal_places ?? 0
                    return places > 0 ? String(format: "%.\(places)f", num) : String(Int(num))
                }
                return values[field.id] as? String ?? ""
            },
            set: {
                values[field.id] = Double($0)
                errors[field.id] = nil
            }
        )
        return HStack {
            TextField((field.placeholder ?? "0").interpolated(), text: binding)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
            if let unit = field.config?.unit {
                Text(unit)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Date/Time

    /// SPEC-401-A B2 P1 — parse min/max date config (ISO `yyyy-MM-dd`)
    /// into a `ClosedRange<Date>` and apply via SwiftUI's `in:` parameter.
    /// Mirrors Android `DatePickerDialog.datePicker.minDate/maxDate`.
    private func dateRange(for field: FormField) -> ClosedRange<Date>? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let min = field.config?.min_date.flatMap({ fmt.date(from: $0) })
                ?? field.config?.max_date.flatMap({ fmt.date(from: $0) }) else { return nil }
        let lower = field.config?.min_date.flatMap { fmt.date(from: $0) } ?? Date.distantPast
        let upper = field.config?.max_date.flatMap { fmt.date(from: $0) } ?? Date.distantFuture
        guard lower <= upper else { return nil }
        _ = min // silence unused
        return lower...upper
    }

    @ViewBuilder
    private func datePicker(_ field: FormField) -> some View {
        let binding = Binding<Date>(
            get: { values[field.id] as? Date ?? Date() },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        if let range = dateRange(for: field) {
            DatePicker("", selection: binding, in: range, displayedComponents: .date)
                .datePickerStyle(.compact).labelsHidden()
        } else {
            DatePicker("", selection: binding, displayedComponents: .date)
                .datePickerStyle(.compact).labelsHidden()
        }
    }

    private func timePicker(_ field: FormField) -> some View {
        let binding = Binding<Date>(
            get: { values[field.id] as? Date ?? Date() },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        return DatePicker(
            "",
            selection: binding,
            displayedComponents: .hourAndMinute
        )
        .datePickerStyle(.compact)
        .labelsHidden()
    }

    @ViewBuilder
    private func dateTimePicker(_ field: FormField) -> some View {
        let binding = Binding<Date>(
            get: { values[field.id] as? Date ?? Date() },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        if let range = dateRange(for: field) {
            DatePicker("", selection: binding, in: range, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact).labelsHidden()
        } else {
            DatePicker("", selection: binding, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact).labelsHidden()
        }
    }

    // MARK: - Select

    @ViewBuilder
    private func selectField(_ field: FormField) -> some View {
        if field.config?.multi_select == true {
            multiSelectField(field)
        } else {
            singleSelectField(field)
        }
    }

    private func singleSelectField(_ field: FormField) -> some View {
        let options = field.options ?? []
        let binding = Binding<String>(
            get: { values[field.id] as? String ?? "" },
            set: { values[field.id] = $0; errors[field.id] = nil }
        )
        return Picker((field.placeholder ?? "Select").interpolated(), selection: binding) {
            Text((field.placeholder ?? "Select...").interpolated()).tag("")
            ForEach(options) { opt in
                Text((opt.label ?? "").interpolated()).tag(opt.id)
            }
        }
        .pickerStyle(.menu)
    }

    // SPEC-419 — multi_select mirrors Android FormStepComposable.SelectField:
    // value shape is [String] (List<String>), additions capped by max_selections.
    private func multiSelectField(_ field: FormField) -> some View {
        let options = field.options ?? []
        let maxSelections = field.config?.max_selections
        let selected: [String] = {
            if let arr = values[field.id] as? [String] { return arr }
            if let str = values[field.id] as? String {
                return str.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            }
            return []
        }()
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { opt in
                let optId = opt.id ?? ""
                let checked = selected.contains(optId)
                Button(action: {
                    var updated = selected
                    if checked {
                        updated.removeAll { $0 == optId }
                    } else if maxSelections == nil || updated.count < maxSelections! {
                        updated.append(optId)
                    }
                    values[field.id] = updated
                    errors[field.id] = nil
                }) {
                    HStack {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundColor(checked ? .accentColor : .secondary)
                        Text((opt.label ?? "").interpolated())
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            if !selected.isEmpty {
                Text(maxSelections != nil ? "\(selected.count) / \(maxSelections!) selected" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Slider

    private func sliderField(_ field: FormField) -> some View {
        // SPEC-419 pass-29 — clamp the ClosedRange (min<max, step>0); an inverted/degenerate config would trap Slider(in:).
        let step = { let s = field.config?.step ?? 1; return s > 0 ? s : 1 }()
        let minVal = min(field.config?.min_value ?? 0, field.config?.max_value ?? 100)
        let maxVal = max(field.config?.max_value ?? 100, minVal + step)
        let unit = field.config?.unit ?? ""

        let binding = Binding<Double>(
            get: { values[field.id] as? Double ?? minVal },
            set: { values[field.id] = $0 }
        )

        return VStack(spacing: 4) {
            HStack {
                Text("\(Int(binding.wrappedValue))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.headline)
                Spacer()
            }
            Slider(value: binding, in: minVal...maxVal, step: step)
            HStack {
                Text("\(Int(minVal))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(maxVal))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Toggle

    private func toggleField(_ field: FormField) -> some View {
        let binding = Binding<Bool>(
            get: { values[field.id] as? Bool ?? false },
            set: { values[field.id] = $0 }
        )
        // SPEC-401-A — `field.style.background_color` (or input_style.fill_color
        // sub-key) tints the Toggle's on-track. Mirrors the Android Switch's
        // `checkedTrackColor`. Falls back to system tint if no style set.
        let inputStyle = field.style?.input_style?.value as? [String: Any]
        let trackHex = field.style?.background_color
            ?? (inputStyle?["fill_color"] as? String)
            ?? (inputStyle?["background_color"] as? String)
        return Toggle((field.label ?? "").interpolated(), isOn: binding)
            .tint(trackHex.map { Color(hex: $0) } ?? .accentColor)
    }

    // MARK: - Stepper

    private func stepperField(_ field: FormField) -> some View {
        // SPEC-419 pass-29 — clamp the ClosedRange (min<max, step>0); an inverted/degenerate config would trap Stepper(in:).
        let step = max(Int(field.config?.step ?? 1), 1)
        let minVal = min(Int(field.config?.min_value ?? 0), Int(field.config?.max_value ?? 100))
        let maxVal = max(Int(field.config?.max_value ?? 100), minVal + step)

        let binding = Binding<Int>(
            get: { values[field.id] as? Int ?? minVal },
            set: { values[field.id] = $0 }
        )

        return Stepper(value: binding, in: minVal...maxVal, step: step) {
            HStack {
                Text("\(binding.wrappedValue)")
                    .font(.headline)
                if let unit = field.config?.unit {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Segmented

    private func segmentedField(_ field: FormField) -> some View {
        let options = field.options ?? []
        let binding = Binding<String>(
            get: { values[field.id] as? String ?? options.first?.id ?? "" },
            set: { values[field.id] = $0 }
        )
        return Picker("", selection: binding) {
            ForEach(options) { opt in
                Text((opt.label ?? "").interpolated()).tag(opt.id)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Validation & Submit

    private func handleSubmit() {
        errors.removeAll()

        for field in visibleFields {
            if field.required {
                let val = values[field.id]
                if val == nil || (val as? String)?.isEmpty == true {
                    errors[field.id] = "\(field.label) is required"
                }
            }

            if let pattern = field.validation?.pattern,
               let val = values[field.id] as? String,
               !val.isEmpty {
                let regex = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(val.startIndex..., in: val)
                if regex?.firstMatch(in: val, range: range) == nil {
                    errors[field.id] = field.validation?.pattern_message ?? "Invalid format"
                }
            }
        }

        if errors.isEmpty {
            // Round-22 — serialize each date/time field to a deterministic LOCAL-component format that
            // BOTH platforms produce identically (no UTC conversion → no local-vs-UTC divergence):
            //   date     → "yyyy-MM-dd"
            //   time     → "HH:mm"
            //   datetime → "yyyy-MM-dd'T'HH:mm:ss"
            // Was a uniform full ISO8601 (UTC) for EVERY date field, so a DATE carried an arbitrary
            // time-of-day and a TIME carried today's date — neither matched Android's date-only / bare
            // "HH:mm" strings. Formatters use no explicit timeZone → device-local components (what the
            // user picked), matching Android's picker-derived Y/M/D + H:M.
            let fieldTypeById = Dictionary(fields.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })
            let dateFmt = DateFormatter(); dateFmt.locale = Locale(identifier: "en_US_POSIX"); dateFmt.dateFormat = "yyyy-MM-dd"
            let timeFmt = DateFormatter(); timeFmt.locale = Locale(identifier: "en_US_POSIX"); timeFmt.dateFormat = "HH:mm"
            // Literal ':00' seconds: the pickers are minute-granularity, but the seeded Date carries
            // wall-clock seconds — hardcoding :00 keeps it identical to Android's "...THH:mm:00".
            let dtFmt = DateFormatter(); dtFmt.locale = Locale(identifier: "en_US_POSIX"); dtFmt.dateFormat = "yyyy-MM-dd'T'HH:mm':00'"
            var response: [String: Any] = [:]
            for (key, val) in values {
                if let date = val as? Date {
                    switch fieldTypeById[key] {
                    case .date: response[key] = dateFmt.string(from: date)
                    case .time: response[key] = timeFmt.string(from: date)
                    default: response[key] = dtFmt.string(from: date) // datetime (or unknown Date)
                    }
                } else {
                    response[key] = val
                }
            }
            onNext(response)
        }
    }

    // MARK: - Helpers

    private func keyboardType(for field: FormField) -> UIKeyboardType {
        switch field.type {
        case .email: return .emailAddress
        case .phone: return .phonePad
        case .number: return .decimalPad
        default:
            switch field.config?.keyboard_type {
            case "email": return .emailAddress
            case "number": return .numberPad
            case "phone": return .phonePad
            case "url": return .URL
            default: return .default
            }
        }
    }

    private func autocap(for field: FormField) -> UITextAutocapitalizationType {
        switch field.config?.autocapitalize {
        case "none": return .none
        case "words": return .words
        case "sentences": return .sentences
        case "characters": return .allCharacters
        default:
            return field.type == .email ? .none : .sentences
        }
    }
}

// MARK: - iOS 15 compatibility

extension View {
    @ViewBuilder
    func scrollDismissesKeyboardCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}
