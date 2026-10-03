import SwiftUI
import PhotosUI
import UIKit

/// SwiftUI renderers for the form-field types that previously
/// existed in the schema (`flow.schema.ts FORM_FIELD_TYPES`) but had no iOS
/// implementation. Each view is a thin wrapper that reads/writes the bound
/// `Any?` value used by `FormStepView`.
///
/// Mirrors the Android `FormFieldRendererExtras.kt` companion file.

// MARK: - Password

@available(iOS 15.0, *)
struct PasswordFieldView: View {
    let field: FormField
    @Binding var value: Any?
    @State private var isVisible = false

    var body: some View {
        let binding = Binding<String>(
            get: { value as? String ?? "" },
            set: { input in
                let truncated = field.config?.max_length.map { String(input.prefix($0)) } ?? input
                value = truncated
            }
        )
        HStack {
            Group {
                if isVisible {
                    TextField((field.placeholder ?? "").interpolated(), text: binding)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField((field.placeholder ?? "").interpolated(), text: binding)
                        .textContentType(.password)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel(isVisible ? "Hide password" : "Show password")
        }
    }
}

// MARK: - URL

@available(iOS 15.0, *)
struct UrlFieldView: View {
    let field: FormField
    @Binding var value: Any?

    var body: some View {
        let binding = Binding<String>(
            get: { value as? String ?? "" },
            set: { input in
                let truncated = field.config?.max_length.map { String(input.prefix($0)) } ?? input
                value = truncated
            }
        )
        TextField((field.placeholder ?? "https://").interpolated(), text: binding)
            .textFieldStyle(.roundedBorder)
            .keyboardType(.URL)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .textContentType(.URL)
    }
}

// MARK: - Rating

@available(iOS 15.0, *)
struct RatingFieldView: View {
    let field: FormField
    @Binding var value: Any?

    var body: some View {
        let cfg = field.config
        let maxStars = max(3, min(10, cfg?.max_stars ?? 5))
        let allowHalf = cfg?.allow_half ?? false
        let starSize = CGFloat(cfg?.star_size ?? 32)
        let filledColor = cfg?.filled_color.map { Color(hex: $0) } ?? .accentColor
        let emptyColor = cfg?.empty_color.map { Color(hex: $0) } ?? Color(.systemGray3)
        let current = (value as? Double) ?? Double((value as? Int) ?? 0)

        HStack(spacing: 4) {
            ForEach(1...maxStars, id: \.self) { i in
                let starState: Double = {
                    if current >= Double(i) { return 1.0 }
                    if allowHalf && current >= Double(i) - 0.5 { return 0.5 }
                    return 0.0
                }()
                ZStack {
                    Image(systemName: starState == 1.0 ? "star.fill" : (starState == 0.5 ? "star.leadinghalf.filled" : "star"))
                        .resizable()
                        .scaledToFit()
                        .frame(width: starSize, height: starSize)
                        .foregroundColor(starState > 0 ? filledColor : emptyColor)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { dg in
                            let isLeftHalf = dg.location.x < starSize / 2
                            let raw: Double = (allowHalf && isLeftHalf) ? Double(i) - 0.5 : Double(i)
                            value = allowHalf ? raw : Double(Int(raw))
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                )
                .accessibilityLabel("Rating \(i) of \(maxStars)")
            }
        }
    }
}

// MARK: - Range Slider

@available(iOS 15.0, *)
struct RangeSliderFieldView: View {
    let field: FormField
    @Binding var value: Any?

    var body: some View {
        let cfg = field.config
        let minV = cfg?.min_value ?? 0
        let maxV = cfg?.max_value ?? 100
        let unit = cfg?.unit ?? ""
        let decimalPlaces = cfg?.decimal_places ?? 0
        // Honor the authored step (like the single field slider FormStepView:415 + Android
        // FormFieldRendererExtras.kt:302). This range slider snapped continuously while Android snapped
        // to the step grid — the same drag produced different captured values.
        let stepV: Double = { let s = cfg?.step ?? 1; return s > 0 ? s : 1 }()

        // Decode existing range from value (dictionary form: low/high)
        let stored = value as? [String: Double]
        let low: Binding<Double> = Binding(
            get: { stored?["low"] ?? minV },
            set: { newLow in
                let high = stored?["high"] ?? maxV
                value = ["low": min(newLow, high), "high": high]
            }
        )
        let high: Binding<Double> = Binding(
            get: { stored?["high"] ?? maxV },
            set: { newHigh in
                let lowVal = stored?["low"] ?? minV
                value = ["low": lowVal, "high": max(newHigh, lowVal)]
            }
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(formatNumber(low.wrappedValue, places: decimalPlaces))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(formatNumber(high.wrappedValue, places: decimalPlaces))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 16, weight: .semibold))
            }
            // Stacked sliders — SwiftUI lacks a native range slider, so we
            // use two coupled sliders that clamp each other.
            VStack(spacing: 4) {
                // Guard the ClosedRange against an inverted/degenerate config
                // (min_value > max_value) or a coupled value out of order, mirroring FormInputRangeSliderBlock.
                Slider(value: low, in: minV...max(minV, high.wrappedValue), step: stepV)
                Slider(value: high, in: min(maxV, low.wrappedValue)...maxV, step: stepV)
            }
            HStack {
                Text(cfg?.min_label?.interpolated() ?? formatNumber(minV, places: decimalPlaces))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(cfg?.max_label?.interpolated() ?? formatNumber(maxV, places: decimalPlaces))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Image Picker

@available(iOS 16.0, *)
struct ImagePickerFieldView: View {
    let field: FormField
    @Binding var value: Any?

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var showCrop = false
    @State private var error: String?

    var body: some View {
        let cfg = field.config
        let maxSizeMb = cfg?.max_size_mb ?? 10
        let aspectRatio = cfg?.aspect_ratio ?? "free"
        let placeholder = cfg?.placeholder_text?.interpolated() ?? "Tap to add a photo"

        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(image != nil ? "Change photo" : placeholder)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .onChange(of: pickerItem) { item in
                Task { await loadImage(item: item, maxSizeMb: maxSizeMb, aspectRatio: aspectRatio) }
            }
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let error = error {
                Text(error).foregroundColor(.red).font(.caption)
            }
        }
    }

    @MainActor
    private func loadImage(item: PhotosPickerItem?, maxSizeMb: Double, aspectRatio: String) async {
        guard let item = item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let sizeMb = Double(data.count) / (1024.0 * 1024.0)
            if sizeMb > maxSizeMb {
                error = "Image too large (\(String(format: "%.1f", sizeMb)) MB max \(maxSizeMb) MB)"
                return
            }
            error = nil
            guard let raw = UIImage(data: data) else { return }
            // Centre-crop to the requested ratio, if any
            let cropped = aspectRatio.lowercased() == "free" ? raw : centerCrop(raw, ratio: parseRatio(aspectRatio) ?? 1.0)
            image = cropped
            // Persist as a base64 data URL so the value is JSON-serialisable
            if let jpeg = cropped.jpegData(compressionQuality: 0.9) {
                value = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            }
        } catch {
            self.error = "Could not load image: \(error.localizedDescription)"
        }
    }

    private func parseRatio(_ spec: String) -> CGFloat? {
        let parts = spec.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "x", with: ":").split(separator: ":")
        guard parts.count == 2,
              let w = Float(parts[0]),
              let h = Float(parts[1]),
              h != 0
        else { return nil }
        return CGFloat(w / h)
    }

    private func centerCrop(_ source: UIImage, ratio: CGFloat) -> UIImage {
        let srcW = source.size.width
        let srcH = source.size.height
        let srcRatio = srcW / srcH
        let cropW: CGFloat
        let cropH: CGFloat
        if srcRatio > ratio {
            cropH = srcH
            cropW = srcH * ratio
        } else {
            cropW = srcW
            cropH = srcW / ratio
        }
        let x = (srcW - cropW) / 2
        let y = (srcH - cropH) / 2
        let rect = CGRect(x: x * source.scale, y: y * source.scale, width: cropW * source.scale, height: cropH * source.scale)
        guard let cgi = source.cgImage?.cropping(to: rect) else { return source }
        return UIImage(cgImage: cgi, scale: source.scale, orientation: source.imageOrientation)
    }
}

// MARK: - Color Picker

@available(iOS 15.0, *)
struct ColorFieldView: View {
    let field: FormField
    @Binding var value: Any?

    var body: some View {
        let cfg = field.config
        let showOpacity = cfg?.show_opacity ?? false
        let initialHex = (value as? String) ?? cfg?.default_color ?? (AppDNA.brandAccentHex ?? "#6366F1")

        let colorBinding = Binding<Color>(
            get: { Color(hex: initialHex) },
            set: { newColor in
                value = newColor.toHex(withAlpha: showOpacity)
            }
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorPicker(
                    "",
                    selection: colorBinding,
                    supportsOpacity: showOpacity
                )
                .labelsHidden()
                Text(initialHex)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            // Presets row (defaults if author didn't customise)
            if let presets = cfg?.preset_colors, !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.gray.opacity(0.3)))
                                .onTapGesture { value = hex }
                        }
                    }
                }
            }
        }
    }
}

private extension Color {
    /// Approximate hex serialisation. iOS `Color` doesn't expose its
    /// components publicly outside `UIColor`, so we round-trip via UIColor.
    func toHex(withAlpha: Bool) -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        let R = Int(round(r * 255)), G = Int(round(g * 255)), B = Int(round(b * 255))
        if withAlpha {
            let A = Int(round(a * 255))
            return String(format: "#%02X%02X%02X%02X", R, G, B, A)
        }
        return String(format: "#%02X%02X%02X", R, G, B)
    }
}

// MARK: - Multiline Chips

@available(iOS 16.0, *)
struct MultilineChipsFieldView: View {
    let field: FormField
    @Binding var value: Any?

    @State private var input: String = ""

    var body: some View {
        let cfg = field.config
        let maxChips = cfg?.max_chips ?? 50
        let allowCustom = cfg?.allow_custom ?? true
        let suggestions = cfg?.suggestions ?? []
        let selected = (value as? [String]) ?? []

        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(selected, id: \.self) { chip in
                    HStack(spacing: 4) {
                        Text(chip)
                        Button { remove(chip) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
            if allowCustom && selected.count < maxChips {
                HStack {
                    TextField(field.placeholder?.interpolated() ?? "Add tag", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustom)
                    Button(action: addCustom) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !suggestions.isEmpty {
                Text("Suggestions").font(.caption).foregroundColor(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(suggestions.filter { !selected.contains($0) }, id: \.self) { s in
                        Button { add(s) } label: { Text(s).padding(.horizontal, 10).padding(.vertical, 6) }
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                            .foregroundColor(.primary)
                    }
                }
            }
            Text("\(selected.count) / \(maxChips) selected").font(.caption).foregroundColor(.secondary)
        }
    }

    private func add(_ s: String) {
        var current = (value as? [String]) ?? []
        let cfg = field.config
        let maxChips = cfg?.max_chips ?? 50
        guard !current.contains(s), current.count < maxChips else { return }
        current.append(s)
        value = current
    }

    private func addCustom() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        input = ""
    }

    private func remove(_ s: String) {
        var current = (value as? [String]) ?? []
        current.removeAll { $0 == s }
        value = current
    }
}

// MARK: - Signature

@available(iOS 15.0, *)
struct SignatureFieldView: View {
    let field: FormField
    @Binding var value: Any?

    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    var body: some View {
        let cfg = field.config
        let strokeColor = cfg?.stroke_color.map { Color(hex: $0) } ?? Color.black
        let strokeWidth = CGFloat(cfg?.stroke_width ?? 2.5)
        let clearText = cfg?.clear_button_text ?? "Clear"

        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color(.systemGray6))
                    .frame(height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                Canvas { ctx, _ in
                    let allStrokes = strokes + (current.isEmpty ? [] : [current])
                    for s in allStrokes where s.count > 1 {
                        var path = Path()
                        path.move(to: s[0])
                        for p in s.dropFirst() { path.addLine(to: p) }
                        ctx.stroke(
                            path,
                            with: .color(strokeColor),
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                if strokes.isEmpty && current.isEmpty {
                    Text(field.placeholder?.interpolated() ?? "Sign here")
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 180)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dg in
                        current.append(dg.location)
                    }
                    .onEnded { _ in
                        if !current.isEmpty {
                            strokes.append(current)
                            current = []
                            value = "signature:\(strokes.count)"
                        }
                    }
            )
            Button(clearText) {
                strokes.removeAll()
                current.removeAll()
                value = nil
            }
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }
    }
}

// MARK: - Helpers

private func formatNumber(_ value: Double, places: Int) -> String {
    if places <= 0 { return String(Int(value.rounded())) }
    return String(format: "%.\(places)f", value)
}

/// Minimal flow layout for chip rows. SwiftUI lacks a built-in until iOS 16,
/// and we want this to work down to iOS 15 for the `MultilineChipsFieldView`
/// host (the view itself gates iOS 16, but `FlowLayout` is available
/// platform-wide because we only use `Layout` APIs available on iOS 16+.)
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(subviews: subviews, in: proposal.replacingUnspecifiedDimensions().width)
        return CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews: subviews, in: bounds.width)
        for (idx, frame) in layout.frames.enumerated() {
            subviews[idx].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }
}
