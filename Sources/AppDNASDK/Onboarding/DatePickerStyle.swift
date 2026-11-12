import Foundation

/// Which picker a date block draws, decided in one place and pinned by the `resolve_date_picker_style` fixture
/// (Android `DatePickerStyle.kt`, the console preview's `date-picker-style.ts`).
///
/// - A **Date Picker** (`date_wheel_picker`) draws `field_config.picker_variant` — `graphical` (a month calendar),
///   `wheel` or `compact` — and a date-only picker with `field_config.selection_mode: "range"` draws the range
///   calendar. Unset: a wheel for a date-and-time or a year, otherwise the calendar.
/// - A **Date** form field (`input_date` / `input_datetime`) used to draw the calendar whenever its presentation
///   was `inline` — the console's default — so its "Picker Variant" changed nothing. The variant now decides for an
///   inline field too; `field` presentation is the compact tap-to-open field, as before; with neither set, compact.
enum DatePickerStyle {
    static let variants: Set<String> = ["graphical", "wheel", "compact"]

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// `date_wheel_picker`: `graphical` | `wheel` | `compact` | `range`.
    /// `mode` is `picker_mode` (`date` · `datetime` · `time` · `year`).
    static func standalone(mode: String?, variant: String?, selection: String?) -> String {
        let m = clean(mode) ?? "date"
        if m == "year" || m == "time" { return "wheel" }
        let hasTime = m == "datetime" || m == "date_time"
        if !hasTime, clean(selection) == "range" { return "range" }
        if let v = clean(variant), variants.contains(v) { return v }
        return hasTime ? "wheel" : "graphical"
    }

    /// `input_date` / `input_time` / `input_datetime`: `graphical` | `wheel` | `compact`.
    static func formField(presentation: String?, variant: String?, hasDate: Bool) -> String {
        let p = clean(presentation)
        if p == "field" { return "compact" }
        let v = clean(variant).flatMap { variants.contains($0) ? $0 : nil }
        if p == "inline" { return v ?? (hasDate ? "graphical" : "compact") }
        return v ?? "compact"
    }
}

/// A range of days picked on the range calendar. Days are `yyyy-MM-dd` strings, which order as dates.
///
/// A first tap starts the range; a second tap on or after the start ends it; a tap before the start, or any tap
/// once the range is complete, starts a new one. Pinned by the `resolve_date_range` fixture.
struct DateRangeSelection: Equatable {
    var start: String?
    var end: String?

    func tapping(_ day: String) -> DateRangeSelection {
        guard let s = start, end == nil, day >= s else { return DateRangeSelection(start: day, end: nil) }
        return DateRangeSelection(start: s, end: day)
    }

    /// The answer keys this selection writes: `<field>` = `start/end` (ISO 8601 interval) once both ends are picked,
    /// with `_start`, `_end` and `_days` (inclusive). A started range writes `_start` only, so a required field stays
    /// unanswered until the range is complete. `nil` values are keys to remove.
    func answer(fieldId: String) -> [String: Any?] {
        guard let s = start else {
            return [fieldId: nil, "\(fieldId)_start": nil, "\(fieldId)_end": nil, "\(fieldId)_days": nil]
        }
        guard let e = end else {
            return [fieldId: nil, "\(fieldId)_start": s, "\(fieldId)_end": nil, "\(fieldId)_days": nil]
        }
        return [fieldId: "\(s)/\(e)", "\(fieldId)_start": s, "\(fieldId)_end": e, "\(fieldId)_days": Self.inclusiveDays(s, e)]
    }

    static func inclusiveDays(_ a: String, _ b: String) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let da = f.date(from: a), let db = f.date(from: b) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86_400).rounded()) + 1
    }

    /// Restores a stored answer (`start/end`, or a started `_start`).
    static func restore(_ values: [String: Any], fieldId: String) -> DateRangeSelection {
        if let v = values[fieldId] as? String {
            let parts = v.split(separator: "/").map(String.init)
            if parts.count == 2 { return DateRangeSelection(start: parts[0], end: parts[1]) }
        }
        return DateRangeSelection(start: values["\(fieldId)_start"] as? String, end: nil)
    }
}
