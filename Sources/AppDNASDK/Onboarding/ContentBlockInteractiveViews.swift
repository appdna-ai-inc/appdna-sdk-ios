import SwiftUI

// MARK: - SPEC-419 STEP-2 — interactive EPIC-11 elements
//
// These were static renders in ContentBlockRendererView; STEP-2 makes them gesture-driven with local
// optimistic @State that works regardless of the delegate. Each writes `inputValues[field_id ?? id]` and
// fires `onInteract(blockId, action, value)` at its pinned trigger so the host delegate can push backend
// state (field_config overrides / advance) back into the live step. REUSES existing field_config keys.

/// SPEC-419 STEP-2 — fold host-pushed per-block `field_config` overrides onto a block at READ TIME.
/// ContentBlock is immutable, so we JSON round-trip a mutable copy (mirrors `resolveBlockBindings`), overlay
/// `overrides[block.id]` key-by-key (override wins), and decode back. Empty/absent overrides → the block is
/// returned unchanged. Applied UNCONDITIONALLY at the render call site (not inside resolveBlockBindings,
/// which early-returns raw blocks that have no bindings — i.e. every EPIC-11 element).
func resolvedFieldConfig(_ block: ContentBlock, _ overrides: [String: [String: Any]]) -> ContentBlock {
    guard let patch = overrides[block.id], !patch.isEmpty else { return block }
    guard let data = try? JSONEncoder().encode(block),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return block
    }
    var fc = (json["field_config"] as? [String: Any]) ?? [:]
    for (k, v) in patch { fc[k] = v }
    json["field_config"] = fc
    guard let updated = try? JSONSerialization.data(withJSONObject: json),
          let resolved = try? JSONDecoder().decode(ContentBlock.self, from: updated) else {
        return block
    }
    return resolved
}

// MARK: - OTP / code input

/// EPIC-11 — OTP boxes backed by a hidden numeric TextField. Tapping focuses the field; on reaching
/// `otp_length` digits it writes `inputValues[fid]` and fires `("otp_entered", code)`.
struct OTPInputBlockView: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    @State private var entered: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rawLen = (block.field_config?["otp_length"]?.value as? Int)
            ?? cfgDouble(block.field_config?["otp_length"]).map { Int($0) } ?? 6
        let length = min(max(rawLen, 2), 10)
        let fieldId = block.field_id ?? block.id
        let accent = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let boxBg = Color(hex: block.bg_color ?? "#1F2937")
        // Mrozu QA (2026-08-04): box border/text were hardcoded (accent/gray + white). When set,
        // border_color overrides the resting border (active box keeps the accent focus ring);
        // text_color overrides the digit. Parity w/ Android.
        let borderOverride = block.border_color.map { Color(hex: $0) }
        let digitColor = Color(hex: block.text_color ?? "#FFFFFF")
        let chars = Array(entered)

        return ZStack {
            // Hidden field captures keyboard input; nearly invisible so it never affects layout/snapshots.
            TextField("", text: Binding(
                get: { entered },
                set: { newVal in
                    let filtered = String(newVal.filter { $0.isNumber }.prefix(length))
                    entered = filtered
                    if filtered.count == length {
                        inputValues[fieldId] = filtered
                        onInteract(block.id, "otp_entered", filtered)
                    }
                }
            ))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focused)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityLabel(block.field_label ?? "Verification code")

            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { i in
                    let ch: Character? = i < chars.count ? chars[i] : nil
                    let isActive = i == chars.count
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(boxBg)
                        if let ch = ch {
                            Text(String(ch)).font(.system(size: 22, weight: .semibold)).foregroundColor(digitColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isActive ? accent : (ch != nil ? (borderOverride ?? accent.opacity(0.5)) : (borderOverride?.opacity(0.35) ?? Color.gray.opacity(0.35))),
                                    lineWidth: (isActive || ch != nil) ? 2 : 1)
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear {
            // Seed from prior input / preview value so re-entry + snapshots keep the entered code.
            if entered.isEmpty {
                entered = (inputValues[fieldId] as? String)
                    ?? (block.field_config?["otp_value"]?.value as? String) ?? ""
            }
        }
    }
}

// MARK: - Press-and-hold to confirm

/// EPIC-11 — a pill that fills left→right while held. A `DragGesture(minimumDistance: 0)` starts a hold
/// timer; on full hold it writes `inputValues[fid] = true` and fires `("confirmed", nil)`. Releasing early
/// rewinds. `hold_progress` seeds the initial (static preview) fill.
struct PressHoldConfirmBlockView: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    @State private var progress: Double = 0
    @State private var holding = false
    @State private var confirmed = false
    @State private var timer: Timer?

    private let holdDuration: Double = 1.2  // seconds to fill

    var body: some View {
        let accent = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Mrozu QA — track background (bg_color; default #1F2937), the filled-state label (confirm_text;
        // default "✓"), and optional above/below labels (label_above/label_below) in text_color (default
        // #111827). Parity w/ Android PressHoldConfirmBlock + console preview.
        let track = Color(hex: block.bg_color ?? "#1F2937")
        let text = block.text ?? "Hold to confirm"
        let confirmText = (block.field_config?["confirm_text"]?.value as? String) ?? "✓"
        let labelAbove = block.field_config?["label_above"]?.value as? String
        let labelBelow = block.field_config?["label_below"]?.value as? String
        let labelColor = Color(hex: block.text_color ?? "#111827")
        let fieldId = block.field_id ?? block.id

        return VStack(spacing: 8) {
            if let above = labelAbove, !above.isEmpty {
                Text(above).font(.system(size: 14)).foregroundColor(labelColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(track)
                    Rectangle().fill(accent).frame(width: geo.size.width * CGFloat(progress))
                    Text(confirmed ? confirmText : text)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .contentShape(RoundedRectangle(cornerRadius: 28))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !confirmed, !holding else { return }
                            startHold(fieldId: fieldId)
                        }
                        .onEnded { _ in
                            guard !confirmed else { return }
                            cancelHold()
                        }
                )
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            if let below = labelBelow, !below.isEmpty {
                Text(below).font(.system(size: 14)).foregroundColor(labelColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            // Seed static preview progress (snapshots); a real hold overwrites it.
            if progress == 0 {
                progress = min(max(cfgDouble(block.field_config?["hold_progress"]) ?? 0, 0), 1)
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func startHold(fieldId: String) {
        holding = true
        timer?.invalidate()
        let tick = 0.02
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { t in
            DispatchQueue.main.async {
                progress = min(progress + tick / holdDuration, 1)
                if progress >= 1 {
                    t.invalidate()
                    holding = false
                    confirmed = true
                    inputValues[fieldId] = true
                    onInteract(block.id, "confirmed", nil)
                }
            }
        }
    }

    private func cancelHold() {
        holding = false
        timer?.invalidate()
        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
    }
}

// MARK: - Memory / pair-match grid

/// EPIC-11 — tap flips a face-down card; two face-up cards resolve to match (stay up, fire `("pair_matched",
/// symbol)`) or mismatch (flip back). When all cards are matched it fires `("completed", nil)`. Initial card
/// `state`s seed the grid (preview parity).
struct MemoryMatchBlockView: View {
    let block: ContentBlock
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    @State private var states: [String] = []
    @State private var flippedUp: [Int] = []
    @State private var busy = false

    var body: some View {
        let rawCols = (block.field_config?["match_columns"]?.value as? Int)
            ?? cfgDouble(block.field_config?["match_columns"]).map { Int($0) } ?? 3
        let cols = min(max(rawCols, 2), 5)
        let cardsRaw = (block.field_config?["match_cards"]?.value as? [Any]) ?? []
        let cards: [[String: Any]] = cardsRaw.compactMap { $0 as? [String: Any] }
        let symbols: [String] = cards.map { ($0["symbol"] as? String) ?? "" }
        let accent = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let matchedCol = Color(hex: "#10B981")
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: cols)

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.offset) { idx, _ in
                let state = idx < states.count ? states[idx] : "down"
                let bg: Color = state == "up" ? .white : (state == "matched" ? matchedCol.opacity(0.18) : accent.opacity(0.16))
                let border: Color = state == "up" ? accent : (state == "matched" ? matchedCol : accent.opacity(0.4))
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(bg)
                    if state == "down" {
                        Text("?").font(.system(size: 26, weight: .bold)).foregroundColor(accent)
                    } else {
                        Text(symbols[idx]).font(.system(size: 28))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { flip(idx, symbols: symbols) }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if states.isEmpty {
                states = cards.map { ($0["state"] as? String) ?? "down" }
            }
        }
    }

    private func flip(_ idx: Int, symbols: [String]) {
        guard !busy, idx < states.count, states[idx] == "down" else { return }
        states[idx] = "up"
        flippedUp.append(idx)
        guard flippedUp.count == 2 else { return }
        let a = flippedUp[0], b = flippedUp[1]
        if a < symbols.count, b < symbols.count, symbols[a] == symbols[b] {
            states[a] = "matched"; states[b] = "matched"
            flippedUp = []
            onInteract(block.id, "pair_matched", symbols[a])
            if states.allSatisfy({ $0 == "matched" }) {
                onInteract(block.id, "completed", nil)
            }
        } else {
            busy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if a < states.count { states[a] = "down" }
                if b < states.count { states[b] = "down" }
                flippedUp = []
                busy = false
            }
        }
    }
}

// MARK: - Month calendar

/// EPIC-11 — one-month day grid. Tapping an in-month day highlights it, writes `inputValues[fid] = day`, and
/// fires `("day_selected", String(day))` (config carries no month/year — the host derives the full date).
/// Config `selected_days` still seed highlights (preview parity).
struct CalendarMonthBlockView: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    @State private var selectedDay: Int? = nil

    var body: some View {
        let cfg = block.field_config
        let fieldId = block.field_id ?? block.id
        let monthLabel = (cfg?["month_label"]?.value as? String) ?? "June 2026"
        // Clamp 0...31 — a negative days_in_month made `0..<(startOffset+daysInMonth)` a malformed Range.
        let daysInMonth = min(max((cfg?["days_in_month"]?.value as? Int) ?? Int(cfgDouble(cfg?["days_in_month"]) ?? 30), 0), 31)
        let startOffset = min(max((cfg?["start_offset"]?.value as? Int) ?? Int(cfgDouble(cfg?["start_offset"]) ?? 0), 0), 6)
        let seededDays = ((cfg?["selected_days"]?.value as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } }
        let today = (cfg?["today"]?.value as? Int) ?? Int(cfgDouble(cfg?["today"]) ?? -1)
        let accent = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let weekdays = ["S", "M", "T", "W", "T", "F", "S"]
        let cells = (0..<(startOffset + daysInMonth)).map { $0 - startOffset + 1 }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return VStack(spacing: 8) {
            Text(monthLabel).font(.system(size: 20, weight: .bold)).foregroundColor(.white).frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(weekdays[i]).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.5)).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    ZStack {
                        if day >= 1 && day <= daysInMonth {
                            let isSelected = seededDays.contains(day) || selectedDay == day
                            let isToday = day == today
                            Circle().fill(isSelected ? accent : Color.clear).frame(width: 34, height: 34)
                            if isToday && !isSelected {
                                Circle().stroke(accent, lineWidth: 1.5).frame(width: 34, height: 34)
                            }
                            Text("\(day)")
                                .font(.system(size: 15, weight: (isToday || isSelected) ? .bold : .regular))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.9))
                        }
                    }
                    .frame(height: 42)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard day >= 1 && day <= daysInMonth else { return }
                        selectedDay = day
                        inputValues[fieldId] = day
                        onInteract(block.id, "day_selected", String(day))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
