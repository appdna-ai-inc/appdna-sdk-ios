import SwiftUI

// MARK: - Wheel-picker measurement mode
//
// Opt-in measurement branch for the `wheel_picker` content block. Enabled only
// when `block.field_config["measurement_type"]` is present AND the `units[]`
// resolve to a usable set (runtime guards below); otherwise the legacy drum
// renders UNCHANGED (see `WheelPickerBlockView`).
//
// EVERYTHING here lives under the generic `field_config` passthrough map — no
// new top-level `ContentBlock` field (Android is at the 255-ctor-arg ceiling).
//
// The measurement wrapper OWNS persistence for ALL four styles (ruler / gauge /
// dial / wheel): it holds an unrounded BASE value (`units[0]`), and on every
// interaction snaps+clamps the base and writes the self-consistent sibling keys.
// The `wheel` style therefore uses a RENDER-ONLY drum that never self-persists.

// MARK: Pure model (unit-tested — see MeasurementPersistenceTests.swift)

/// A single measurement unit resolved from `field_config.units[]`.
/// `units[0]` is the canonical BASE unit (`factor==1`, `offset==0` by convention).
struct MeasurementUnit: Equatable {
    let id: String
    let label: String
    let min: Double
    let max: Double
    let step: Double
    let decimals: Int
    let factor: Double
    let offset: Double
}

/// Pinned half-away-from-zero rounding: `sign(x) * floor(abs(x) + 0.5)`.
/// This is the ONE algorithm shared across iOS/Android/JS — it deliberately does
/// NOT use Swift's bare `.rounded()` (which is half-to-even) so negatives match.
/// `sign(0) == 0`.
@inline(__always)
func measurementRoundHalfAway(_ x: Double) -> Double {
    if x > 0 { return floor(x + 0.5) }
    if x < 0 { return -floor(-x + 0.5) }
    return 0
}

/// Snap a value to `unit.step`/`unit.decimals`, THEN clamp to `[unit.min, unit.max]`.
/// Clamp is the FINAL op and uses `min(max(d,lo),hi)` (never a throwing clamp) so
/// non-step-aligned custom ranges still land exactly on the boundary.
func measurementSnap(_ value: Double, _ unit: MeasurementUnit) -> Double {
    let step = unit.step > 0 ? unit.step : 1
    // step-snap in integer domain
    let q = value / step
    let n = measurementRoundHalfAway(q)
    let s = n * step
    // decimal-normalize in integer domain
    let decimals = max(0, unit.decimals)
    let p = pow(10.0, Double(decimals))
    let d = measurementRoundHalfAway(s * p) / p
    // clamp LAST — non-throwing form (safe even if lo > hi upstream)
    return Swift.min(Swift.max(d, unit.min), unit.max)
}

/// Convert a value expressed in `unit` to the canonical base: `(value - offset) / factor`.
func measurementToBase(_ value: Double, _ unit: MeasurementUnit) -> Double {
    let f = unit.factor != 0 ? unit.factor : 1
    return (value - unit.offset) / f
}

/// Convert a base value into `unit`: `base * factor + offset`.
func measurementFromBase(_ base: Double, _ unit: MeasurementUnit) -> Double {
    return base * unit.factor + unit.offset
}

/// Persist as `Int` when whole (matches the legacy drum + keeps `answer_equals`
/// numeric routing type-exact on iOS), `Double` otherwise.
func measurementScalar(_ v: Double) -> Any {
    return v == v.rounded() ? Int(v) : v
}

/// The canonical persist + delegate-payload derivation. Given an (unrounded) base
/// and the current display unit, produces:
///   - the `inputValues` patch: `{ fieldId: snapped+clamped BASE, _unit: base id,
///     _display_unit: display id, _display_value: snapped display }`
///   - the `onElementInteraction` payload: `{ value: base, display_value, unit: display id }`
/// The persisted scalar is UNIT-STABLE — flipping the toggle holds the base constant
/// so the scalar does not change; only the display keys / payload change.
struct MeasurementSnapshot {
    let inputValues: [String: Any]
    let payload: [String: Any]
    let snappedBase: Double
    let display: Double
}

func measurementSnapshot(
    fieldId: String,
    base: Double,
    baseUnit: MeasurementUnit,
    displayUnit: MeasurementUnit
) -> MeasurementSnapshot {
    let snappedBase = measurementSnap(base, baseUnit)
    let display = measurementSnap(measurementFromBase(base, displayUnit), displayUnit)
    let baseScalar = measurementScalar(snappedBase)
    let displayScalar = measurementScalar(display)

    var iv: [String: Any] = [:]
    iv[fieldId] = baseScalar                          // BASE scalar (units[0])
    iv["\(fieldId)_unit"] = baseUnit.id               // annotates the BASE scalar
    iv["\(fieldId)_display_unit"] = displayUnit.id     // user's chosen unit
    iv["\(fieldId)_display_value"] = displayScalar      // value in the display unit

    let payload: [String: Any] = [
        "value": baseScalar,
        "display_value": displayScalar,
        "unit": displayUnit.id,
    ]
    return MeasurementSnapshot(inputValues: iv, payload: payload, snappedBase: snappedBase, display: display)
}

/// The `value` a measurement commit hands to `onElementInteraction` as its (stringly-typed) value
/// argument. `onInteract` is `(blockId, action, value: String?)` on both platforms, so the base scalar
/// crosses as a string and the richer `{display_value, unit}` reach the delegate through `inputValues`
/// (`<field>_display_value` / `<field>_display_unit`), which the fire-seam passes verbatim.
///
/// Mirrors Android `MeasurementWheel.kt:367` — `snap.payload["value"]?.toString()`. An Int stays
/// integral ("70", never "70.0") so `answer_equals` numeric routing stays type-exact across platforms.
func measurementInteractionValue(_ snapshot: MeasurementSnapshot) -> String? {
    switch snapshot.payload["value"] {
    case let i as Int: return String(i)
    case let d as Double: return String(d)
    default: return nil
    }
}

/// The action name a measurement commit fires. Pinned to Android's `"value_changed"`
/// (`MeasurementWheel.kt:367`) — the wheel and the legacy drum emit the same action, so a host that
/// switches on it does not have to know which renderer the console picked.
let measurementInteractionAction = "value_changed"

/// Resolved measurement configuration parsed from `field_config`.
struct MeasurementConfig {
    let type: String
    let units: [MeasurementUnit]
    let initialUnitIndex: Int
    let style: String        // ruler | gauge | dial | wheel
    let defaultBase: Double
    let tickColorHex: String?
    let trackColorHex: String?
    let needleColorHex: String?
    let toggleActiveColorHex: String?
    let majorTickInterval: Int
    let valueFontSize: Double
    let unitFontSize: Double
}

/// Coerce a JSON-decoded value (Int/Double/String) to Double. `field_config`
/// numerics MAY arrive as strings when not passed through `normalize-step-numerics`
/// (e.g. nested in a stack), so we tolerate String too.
private func measurementNum(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}

private let measurementValidStyles: Set<String> = ["ruler", "gauge", "dial", "wheel"]

/// Parse + validate the measurement config. Returns `nil` (→ legacy drum fallback)
/// when `measurement_type` is unset, `units` is empty/unresolvable, or ANY unit is
/// degenerate (`factor==0`, `step<=0`, `min>=max`). A `unit_default` that matches no
/// unit is NOT a fallback trigger — it resolves to `units[0]` and stays in mode.
func parseMeasurementConfig(_ block: ContentBlock) -> MeasurementConfig? {
    guard let cfg = block.field_config else { return nil }
    guard let type = cfg["measurement_type"]?.value as? String, !type.isEmpty else { return nil }
    guard let rawUnits = cfg["units"]?.value as? [Any], !rawUnits.isEmpty else { return nil }

    var units: [MeasurementUnit] = []
    for el in rawUnits {
        guard let d = el as? [String: Any] else { return nil }          // unresolvable → fallback
        guard let id = d["id"] as? String, !id.isEmpty,
              let mn = measurementNum(d["min"]),
              let mx = measurementNum(d["max"]),
              let st = measurementNum(d["step"]),
              let fc = measurementNum(d["factor"]) else { return nil }    // missing numeric → fallback
        // Runtime guards → unit unusable → fall back to the legacy drum.
        if fc == 0 || st <= 0 || mn >= mx { return nil }
        let label = (d["label"] as? String) ?? id
        let decimals = Int(measurementNum(d["decimals"]) ?? 0)
        let offset = measurementNum(d["offset"]) ?? 0
        units.append(MeasurementUnit(
            id: id, label: label, min: mn, max: mx, step: st,
            decimals: max(0, decimals), factor: fc, offset: offset
        ))
    }
    guard !units.isEmpty else { return nil }

    // find-or-default (never `first(where:)!`)
    let unitDefault = cfg["unit_default"]?.value as? String
    let initialIndex = unitDefault.flatMap { ud in units.firstIndex(where: { $0.id == ud }) } ?? 0

    let rawStyle = (cfg["measurement_style"]?.value as? String) ?? "ruler"
    let style = measurementValidStyles.contains(rawStyle) ? rawStyle : "ruler"

    let base = units[0]
    let defaultBase = measurementNum(cfg["measurement_default"]?.value) ?? ((base.min + base.max) / 2)

    let majorRaw = Int(measurementNum(cfg["major_tick_interval"]?.value) ?? 5)
    let major = majorRaw > 0 ? majorRaw : 5
    let vfsRaw = measurementNum(cfg["value_font_size"]?.value) ?? 34
    let vfs = vfsRaw > 0 ? vfsRaw : 34
    let ufsRaw = measurementNum(cfg["unit_font_size"]?.value) ?? 15
    let ufs = ufsRaw > 0 ? ufsRaw : 15

    return MeasurementConfig(
        type: type,
        units: units,
        initialUnitIndex: initialIndex,
        style: style,
        defaultBase: defaultBase,
        tickColorHex: cfg["tick_color"]?.value as? String,
        trackColorHex: cfg["track_color"]?.value as? String,
        needleColorHex: cfg["needle_color"]?.value as? String,
        toggleActiveColorHex: cfg["toggle_active_color"]?.value as? String,
        majorTickInterval: major,
        valueFontSize: vfs,
        unitFontSize: ufs
    )
}

// MARK: - Measurement view

struct MeasurementWheelBlockView: View {
    let block: ContentBlock
    let config: MeasurementConfig
    @Binding var inputValues: [String: Any]
    /// Fired `("value_changed", <base value>)` on a real user commit (a pick from any
    /// style, or a unit switch), NEVER on the pristine onAppear seed and never per drag tick.
    ///
    /// This used to be dead: `writeSnapshot()` computed `snap.payload` and threw it away
    /// (`_ = snap.payload`), so no host on any device ever received a measurement interaction even
    /// though Android fired one (`MeasurementWheel.kt:367`).
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    // NB: the SDK defines a public `enum Environment` (Configuration.swift) that
    // shadows SwiftUI's `@Environment` property wrapper here — fully qualify it.
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    /// Unrounded BASE value (`units[0]`) — the single source of truth. Display in
    /// any unit is derived; the persisted scalar is snapped+clamped from this.
    @State private var holdBase: Double = 0
    @State private var unitIndex: Int = 0
    /// Required-field gate parity: for a required field we do NOT persist the seeded
    /// default until the user actually interacts (matches the legacy drum).
    @State private var hasUserInteracted: Bool = false
    @State private var didInit = false

    private let tickSpacing: CGFloat = 12

    private var baseUnit: MeasurementUnit { config.units[0] }
    private var currentUnit: MeasurementUnit {
        (unitIndex >= 0 && unitIndex < config.units.count) ? config.units[unitIndex] : config.units[0]
    }
    private var fieldId: String { block.field_id ?? block.id }

    /// Snapped display value in the current unit (base held constant + re-clamped).
    private var currentDisplay: Double {
        measurementSnap(measurementFromBase(holdBase, currentUnit), currentUnit)
    }

    // Colors (pinned defaults; dark-mode-aware for tick/track).
    private var tickColor: Color {
        Color(hex: config.tickColorHex ?? (colorScheme == .dark ? "#475569" : "#CBD5E1"))
    }
    private var trackColor: Color {
        Color(hex: config.trackColorHex ?? (colorScheme == .dark ? "#334155" : "#E2E8F0"))
    }
    private var accentColor: Color {
        Color(hex: config.needleColorHex ?? block.highlight_color ?? "#6366F1")
    }
    private var toggleColor: Color {
        Color(hex: config.toggleActiveColorHex ?? block.highlight_color ?? "#6366F1")
    }

    var body: some View {
        VStack(spacing: 16) {
            if let label = block.field_label ?? block.rating_label ?? block.text, !label.isEmpty {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            valueDisplay

            if config.units.count > 1 {
                unitToggle
            }

            styleVisual
        }
        .frame(maxWidth: .infinity)
        .onAppear { initializeIfNeeded() }
    }

    // MARK: Value + unit label

    private var valueDisplay: some View {
        // The numeric scale is LTR-locked; only the toggle row follows layout direction.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(formattedDisplay(currentDisplay))
                .font(.system(size: CGFloat(config.valueFontSize), weight: .bold, design: .rounded))
                .foregroundColor(accentColor)          // value text = needle color
                .monospacedDigit()
            Text(currentUnit.label)
                .font(.system(size: CGFloat(config.unitFontSize), weight: .medium))
                .foregroundColor(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Unit toggle

    private var unitToggle: some View {
        HStack(spacing: 0) {
            ForEach(config.units.indices, id: \.self) { i in
                let selected = i == unitIndex
                Button {
                    selectUnit(i)
                } label: {
                    Text(config.units[i].label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selected ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? toggleColor : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(trackColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 220)
    }

    // MARK: Style visuals

    @ViewBuilder
    private var styleVisual: some View {
        switch config.style {
        case "gauge": gaugeVisual
        case "dial":  drumVisual(perspective: true)
        case "wheel": drumVisual(perspective: false)
        default:      rulerVisual   // "ruler"
        }
    }

    // MARK: Ruler (horizontal tick tape + fixed center caret)

    @ViewBuilder
    private var rulerVisual: some View {
        let vals = displayValues
        GeometryReader { geo in
            let sidePad = geo.size.width / 2
            ZStack {
                if #available(iOS 17.0, *) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tickSpacing) {
                            ForEach(vals.indices, id: \.self) { i in
                                rulerTick(index: i, values: vals)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, sidePad, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: rulerScrollBinding(values: vals))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: tickSpacing) {
                                ForEach(vals.indices, id: \.self) { i in
                                    rulerTick(index: i, values: vals)
                                        .id(i)
                                        .onTapGesture { pick(vals[i]) }
                                }
                            }
                            .padding(.horizontal, sidePad)
                        }
                        .onAppear {
                            proxy.scrollTo(nearestIndex(to: currentDisplay, in: vals), anchor: .center)
                        }
                    }
                }
                // Fixed center caret.
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 2, height: 46)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: 84)
    }

    @ViewBuilder
    private func rulerTick(index i: Int, values vals: [Double]) -> some View {
        let sel = nearestIndex(to: currentDisplay, in: vals)
        let isMajor = i % max(1, config.majorTickInterval) == 0
        VStack(spacing: 4) {
            Rectangle()
                .fill(i == sel ? accentColor : tickColor)
                .frame(width: 2, height: isMajor ? 32 : 18)
            if isMajor {
                Text(formattedDisplay(vals[i]))
                    .font(.system(size: 10))
                    .foregroundColor(tickColor)
                    .fixedSize()
            } else {
                Spacer().frame(height: 12)
            }
        }
    }

    @available(iOS 17.0, *)
    private func rulerScrollBinding(values vals: [Double]) -> Binding<Int?> {
        Binding(
            get: { nearestIndex(to: currentDisplay, in: vals) },
            set: { new in
                if let n = new, n >= 0, n < vals.count { pick(vals[n]) }
            }
        )
    }

    // MARK: Drum (wheel = flat; dial = perspective) — render-only, wrapper persists

    // Custom drum (NOT SwiftUI Picker(.wheel), which forces a UIKit white edge-fade
    // + fixed intrinsic height that overflows on a dark background). Rows fade by
    // distance to the page background via opacity; `dial` tilts each row for a
    // rotary-perspective look; `wheel` is flat. Render-only — the wrapper persists.
    @ViewBuilder
    private func drumVisual(perspective: Bool) -> some View {
        let vals = displayValues
        let sel = nearestIndex(to: currentDisplay, in: vals)
        let rowH: CGFloat = 40
        let half = 2   // 5 visible rows
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(trackColor.opacity(0.6))
                .frame(height: rowH)
            VStack(spacing: 0) {
                ForEach(-half...half, id: \.self) { off in
                    let idx = sel + off
                    let inRange = idx >= 0 && idx < vals.count
                    // `dial` = barrel/rotary feel via a per-row SCALE (layout-safe,
                    // centered in the 40pt slot); `wheel` = flat (scale 1). Never a
                    // per-row rotation3DEffect — it collapses the VStack layout.
                    let scale = perspective ? max(0.62, 1 - Double(abs(off)) * 0.16) : 1.0
                    Text(inRange ? formattedDisplay(vals[idx]) : " ")
                        .font(.system(size: off == 0 ? 24 : 18, weight: off == 0 ? .bold : .regular))
                        .foregroundColor(off == 0 ? accentColor : tickColor)
                        .opacity(off == 0 ? 1 : max(0.18, 1 - Double(abs(off)) * 0.30))
                        .scaleEffect(scale)
                        .frame(height: rowH)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { if inRange { pick(vals[idx]) } }
                }
            }
        }
        .frame(height: rowH * 5)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture().onEnded { g in
                let steps = Int((-g.translation.height / rowH).rounded())
                let ni = min(max(sel + steps, 0), vals.count - 1)
                if ni != sel { pick(vals[ni]) }
            }
        )
    }

    // MARK: Gauge (minimal radial arc + needle; reads units[] range ONLY)

    @ViewBuilder
    private var gaugeVisual: some View {
        let range = currentUnit.max - currentUnit.min
        let frac = range > 0 ? Swift.min(1, Swift.max(0, (currentDisplay - currentUnit.min) / range)) : 0
        GeometryReader { geo in
            ZStack {
                MeasurementGaugeArc(startDeg: 135, sweepDeg: 270, progress: 1)
                    .stroke(trackColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                MeasurementGaugeArc(startDeg: 135, sweepDeg: 270, progress: frac)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                MeasurementGaugeNeedle(startDeg: 135, sweepDeg: 270, progress: frac)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle()
                    .fill(accentColor)
                    .frame(width: 12, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in gaugeDrag(g.location, size: geo.size) }
            )
        }
        .frame(height: 170)
        .padding(.horizontal, 24)
    }

    private func gaugeDrag(_ location: CGPoint, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        var deg = Foundation.atan2(Double(location.y - c.y), Double(location.x - c.x)) * 180 / .pi   // -180..180
        let start = 135.0, sweep = 270.0
        if deg < start { deg += 360 }                                     // map into 135..405
        let frac = Swift.min(1, Swift.max(0, (deg - start) / sweep))
        let v = currentUnit.min + frac * (currentUnit.max - currentUnit.min)
        pick(v)
    }

    // MARK: Helpers

    /// Discrete values in the CURRENT unit, from min to max by step.
    private var displayValues: [Double] {
        var vals: [Double] = []
        let u = currentUnit
        let step = u.step > 0 ? u.step : 1
        var c = u.min
        var guardCount = 0
        while c <= u.max + step * 1e-6 && guardCount < 100_000 {
            vals.append(Swift.min(c, u.max))
            c += step
            guardCount += 1
        }
        return vals.isEmpty ? [u.min] : vals
    }

    private func nearestIndex(to value: Double, in vals: [Double]) -> Int {
        guard !vals.isEmpty else { return 0 }
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, v) in vals.enumerated() {
            let d = abs(v - value)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    private func formattedDisplay(_ v: Double) -> String {
        let dec = currentUnit.decimals
        if dec <= 0 { return String(Int(measurementRoundHalfAway(v))) }
        return String(format: "%.\(dec)f", v)
    }

    // MARK: State transitions + persistence (wrapper OWNS persistence)

    private func initializeIfNeeded() {
        guard !didInit else { return }
        didInit = true
        unitIndex = config.initialUnitIndex

        // Restore a previously-persisted base scalar on re-entry.
        if let saved = doubleFromInput(inputValues[fieldId]) {
            holdBase = saved
            hasUserInteracted = true
            if let du = inputValues["\(fieldId)_display_unit"] as? String,
               let idx = config.units.firstIndex(where: { $0.id == du }) {
                unitIndex = idx
            }
            return
        }

        holdBase = config.defaultBase
        // Required-field gate: seed at render ONLY for non-required fields (parity
        // with the legacy wheel). Required fields persist after first interaction.
        if block.field_required != true {
            writeSnapshot()
        }
    }

    /// A pick from ANY style: converts the chosen display value → base, holds it, marks interaction,
    /// and performs the single wrapper-owned persist + the delegate fire (commit-level).
    private func pick(_ displayValue: Double) {
        hasUserInteracted = true
        holdBase = measurementToBase(displayValue, currentUnit)
        fireCommit(writeSnapshot())
    }

    private func selectUnit(_ idx: Int) {
        guard idx != unitIndex, idx >= 0, idx < config.units.count else { return }
        hasUserInteracted = true
        unitIndex = idx
        // Base held constant; display recomputes + re-clamps inside the snapshot.
        fireCommit(writeSnapshot())
    }

    /// Persist + return the snapshot so callers can fire the delegate. The `onAppear` seed calls this
    /// WITHOUT firing (a render-time seed is not a user interaction) — matches Android.
    @discardableResult
    private func writeSnapshot() -> MeasurementSnapshot {
        let snap = measurementSnapshot(
            fieldId: fieldId,
            base: holdBase,
            baseUnit: baseUnit,
            displayUnit: currentUnit
        )
        for (k, v) in snap.inputValues { inputValues[k] = v }
        return snap
    }

    /// Hand the commit to the step scope, which awaits `onElementInteraction` and folds the result.
    /// The delegate sees `{value: base}` here plus `{display_value, unit}` via the freshly-written
    /// `inputValues` — the same three facts Android sends.
    private func fireCommit(_ snap: MeasurementSnapshot) {
        onInteract(block.id, measurementInteractionAction, measurementInteractionValue(snap))
    }

    private func doubleFromInput(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Gauge shapes

/// Radial track/value arc for the `gauge` style (270° sweep, gap at the bottom).
struct MeasurementGaugeArc: Shape {
    let startDeg: Double
    let sweepDeg: Double
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = Swift.min(rect.width, rect.height) / 2 - 8
        let clamped = Swift.min(1, Swift.max(0, progress))
        p.addArc(
            center: center,
            radius: max(radius, 1),
            startAngle: .degrees(startDeg),
            endAngle: .degrees(startDeg + sweepDeg * clamped),
            clockwise: false
        )
        return p
    }
}

/// Needle line from the gauge center to the current value angle.
struct MeasurementGaugeNeedle: Shape {
    let startDeg: Double
    let sweepDeg: Double
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = Double(Swift.min(rect.width, rect.height)) / 2 - 16
        let clamped = Swift.min(1, Swift.max(0, progress))
        let ang = (startDeg + sweepDeg * clamped) * .pi / 180
        p.move(to: center)
        p.addLine(to: CGPoint(
            x: Double(center.x) + Foundation.cos(ang) * radius,
            y: Double(center.y) + Foundation.sin(ang) * radius
        ))
        return p
    }
}
