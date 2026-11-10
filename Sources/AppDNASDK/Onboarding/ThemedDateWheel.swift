import SwiftUI
import UIKit

/// The date logic of the themed wheel: which days and months exist and may be picked. No view code, so the shared fixture
/// reads the same rules Android answers.
struct DateWheelModel {
    enum Column: String { case year, month, day, hour, minute, meridiem }

    var calendar: Calendar
    var minimum: Date
    var maximum: Date

    /// Gregorian-style calendars number months and years the way these columns assume. The others (Japanese eras, lunar leap
    /// months) keep the native wheel, which handles them correctly.
    static func supports(_ calendar: Calendar) -> Bool {
        switch calendar.identifier {
        case .gregorian, .iso8601, .buddhist: return true
        default: return false
        }
    }

    /// The day, month and year columns in the order this locale writes a date.
    static func dateColumns(locale: Locale) -> [Column] {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMMMd", options: 0, locale: locale) ?? "MMMdy"
        var seen: [Column] = []
        for ch in pattern {
            let column: Column?
            switch ch {
            case "y", "Y", "u": column = .year
            case "M", "L": column = .month
            case "d": column = .day
            default: column = nil
            }
            if let column, !seen.contains(column) { seen.append(column) }
        }
        return seen.count == 3 ? seen : [.month, .day, .year]
    }

    private func make(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    func parts(of date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1, c.hour ?? 12, c.minute ?? 0)
    }

    var years: ClosedRange<Int> {
        let low = parts(of: minimum).year
        return low...max(low, parts(of: maximum).year)
    }

    func months(inYear year: Int) -> ClosedRange<Int> {
        let low = parts(of: minimum), high = parts(of: maximum)
        let first = year == low.year ? low.month : 1
        let last = year == high.year ? high.month : (calendar.range(of: .month, in: .year, for: make(year, 1, 1) ?? minimum)?.count ?? 12)
        return first...max(first, last)
    }

    func days(inYear year: Int, month: Int) -> ClosedRange<Int> {
        let low = parts(of: minimum), high = parts(of: maximum)
        let length = calendar.range(of: .day, in: .month, for: make(year, month, 1) ?? minimum)?.count ?? 31
        let first = (year == low.year && month == low.month) ? low.day : 1
        let last = (year == high.year && month == high.month) ? min(high.day, length) : length
        return first...max(first, last)
    }

    /// The nearest real, allowed date: the day comes down when the month is shorter, and the whole date stays inside the bounds.
    func clamped(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let length = calendar.range(of: .day, in: .month, for: make(year, month, 1) ?? minimum)?.count ?? 31
        let result = make(year, month, min(day, length), hour, minute) ?? minimum
        return min(max(result, minimum), maximum)
    }
}

/// What the date wheel stores for a pick, and the date a stored answer is read back as. `calendar` is Gregorian, in the
/// time zone the wheel draws in.
///
/// A date-only answer is the calendar date the user saw, `yyyy-MM-dd`, as Android stores it. It is not a moment: written as
/// a UTC instant, local midnight east of UTC is the previous day, and every reader of the text got the wrong date.
enum DateWheelAnswer {
    static func string(for date: Date, mode: String, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        switch mode {
        case "year":
            return String(format: "%04d", c.year ?? 0)
        case "date":
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
        default:
            // A time keeps the moment it has always been.
            return ISO8601DateFormatter().string(from: date)
        }
    }

    /// The date a stored answer is shown as: four digits, `yyyy-MM-dd`, or an ISO instant (a time, or a date stored by an
    /// earlier release, which is shown as the local date it was picked on). Nil for anything else.
    static func date(from saved: String, calendar: Calendar) -> Date? {
        let text = saved.trimmingCharacters(in: .whitespaces)
        let digits = text.split(separator: "-", omittingEmptySubsequences: false)
        if digits.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            let parts = digits.compactMap { Int($0) }
            if parts.count == 1, digits[0].count == 4 {
                return calendar.date(from: DateComponents(year: parts[0], month: 6, day: 15, hour: 12))
            }
            if parts.count == 3, digits[0].count == 4, digits[1].count == 2, digits[2].count == 2 {
                let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
                // A month or day out of range is refused, not rolled over into a real but different date.
                guard let date = calendar.date(from: wanted) else { return nil }
                let got = calendar.dateComponents([.year, .month, .day], from: date)
                guard got.year == parts[0], got.month == parts[1], got.day == parts[2] else { return nil }
                return date
            }
            return nil
        }
        return ISO8601.date(from: text)
    }
}

/// The selection band takes the flow's highlight colour, on every surface.
enum DateWheelBand {
    static let opacity = 0.1
}

/// A wheel for dates and times drawn by the SDK, because UIKit's own wheel gives no control over its selection band.
struct ThemedDateWheel: View {
    @Binding var date: Date
    let range: ClosedRange<Date>
    let columns: [DateWheelModel.Column]
    let highlight: Color
    let text: Color
    let fontSize: CGFloat
    let authoredHeight: CGFloat?
    let lineColor: Color?
    let lineWidth: CGFloat
    /// Nil follows the locale.
    let use24Hour: Bool?
    let hapticOnScroll: Bool

    @SwiftUI.Environment(\.calendar) private var calendar
    @SwiftUI.Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 38

    private var model: DateWheelModel { DateWheelModel(calendar: calendar, minimum: range.lowerBound, maximum: range.upperBound) }
    private var is24Hour: Bool {
        if let use24Hour { return use24Hour }
        return !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }

    private func number(_ value: Int, pad: Int = 0) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.usesGroupingSeparator = false
        f.minimumIntegerDigits = pad
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    private var monthNames: [String] {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        return f.shortStandaloneMonthSymbols ?? []
    }

    private func set(_ edit: (inout (year: Int, month: Int, day: Int, hour: Int, minute: Int)) -> Void) {
        var p = model.parts(of: date)
        edit(&p)
        date = model.clamped(year: p.year, month: p.month, day: p.day, hour: p.hour, minute: p.minute)
    }

    private func items(for column: DateWheelModel.Column) -> (items: [WheelItem], selected: Int, name: String, pick: (Int) -> Void) {
        let p = model.parts(of: date)
        switch column {
        case .year:
            return (model.years.map { WheelItem(value: $0, label: number($0)) }, p.year, "Year", { v in set { $0.year = v } })
        case .month:
            let names = monthNames
            return (model.months(inYear: p.year).map { WheelItem(value: $0, label: names.indices.contains($0 - 1) ? names[$0 - 1] : number($0)) }, p.month, "Month", { v in set { $0.month = v } })
        case .day:
            return (model.days(inYear: p.year, month: p.month).map { WheelItem(value: $0, label: number($0)) }, p.day, "Day", { v in set { $0.day = v } })
        case .hour:
            let shown: (Int) -> Int = { [is24Hour] h in is24Hour ? h : (h % 12 == 0 ? 12 : h % 12) }
            let keepHalf = p.hour >= 12
            let values = is24Hour ? Array(0...23) : (keepHalf ? Array(12...23) : Array(0...11))
            return (values.map { WheelItem(value: $0, label: number(shown($0), pad: is24Hour ? 2 : 0)) }, p.hour, "Hour", { v in set { $0.hour = v } })
        case .minute:
            return ((0...59).map { WheelItem(value: $0, label: number($0, pad: 2)) }, p.minute, "Minute", { v in set { $0.minute = v } })
        case .meridiem:
            let f = DateFormatter()
            f.locale = locale
            return ([WheelItem(value: 0, label: f.amSymbol), WheelItem(value: 1, label: f.pmSymbol)], p.hour >= 12 ? 1 : 0, "AM or PM", { v in
                set { $0.hour = ($0.hour % 12) + (v == 1 ? 12 : 0) }
            })
        }
    }

    private var shownColumns: [DateWheelModel.Column] {
        columns.filter { $0 != .meridiem || !is24Hour }
    }

    var body: some View {
        let height = authoredHeight ?? rowHeight * 5
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(highlight.opacity(DateWheelBand.opacity))
                .frame(height: rowHeight)
                .overlay(alignment: .top) { if let lineColor, lineWidth > 0 { Rectangle().fill(lineColor).frame(height: lineWidth) } }
                .overlay(alignment: .bottom) { if let lineColor, lineWidth > 0 { Rectangle().fill(lineColor).frame(height: lineWidth) } }
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                ForEach(shownColumns, id: \.rawValue) { column in
                    let c = items(for: column)
                    WheelColumn(items: c.items, selected: c.selected, name: c.name, rowHeight: rowHeight, fontSize: fontSize,
                                highlight: UIColor(highlight), text: UIColor(text), haptic: hapticOnScroll, onSelect: c.pick)
                        .accessibilityIdentifier("date_wheel.\(column.rawValue)")
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("date_wheel")
    }
}

struct WheelItem: Equatable {
    let value: Int
    let label: String
}

/// One snapping column. A scroll view rather than `Picker(.wheel)`, whose selection band cannot be recoloured.
private struct WheelColumn: UIViewRepresentable {
    let items: [WheelItem]
    let selected: Int
    let name: String
    let rowHeight: CGFloat
    let fontSize: CGFloat
    let highlight: UIColor
    let text: UIColor
    let haptic: Bool
    let onSelect: (Int) -> Void

    func makeUIView(context: Context) -> WheelScrollView {
        WheelScrollView()
    }

    func updateUIView(_ view: WheelScrollView, context: Context) {
        view.configure(items: items, selected: selected, name: name, rowHeight: rowHeight, fontSize: fontSize,
                       highlight: highlight, text: text, haptic: haptic, onSelect: onSelect)
    }
}

final class WheelScrollView: UIScrollView, UIScrollViewDelegate {
    private var items: [WheelItem] = []
    private var labels: [UILabel] = []
    private var rowHeight: CGFloat = 38
    private var fontSize: CGFloat = 18
    private var highlight: UIColor = .systemBlue
    private var rowText: UIColor = .label
    private var haptic = false
    private var onSelect: (Int) -> Void = { _ in }
    private var name = ""
    private var selected = 0
    private var lastCentred = -1
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [WheelItem], selected: Int, name: String, rowHeight: CGFloat, fontSize: CGFloat,
                   highlight: UIColor, text: UIColor, haptic: Bool, onSelect: @escaping (Int) -> Void) {
        let rebuilt = items != self.items || rowHeight != self.rowHeight || fontSize != self.fontSize
        self.items = items
        self.selected = selected
        self.name = name
        self.rowHeight = rowHeight
        self.fontSize = fontSize
        self.highlight = highlight
        self.rowText = text
        self.haptic = haptic
        self.onSelect = onSelect
        accessibilityLabel = name
        if rebuilt { rebuild() }
        setNeedsLayout()
        if !isDragging && !isDecelerating { scroll(toValue: selected, animated: false) }
        styleRows()
    }

    private func rebuild() {
        labels.forEach { $0.removeFromSuperview() }
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: fontSize))
        labels = items.map { item in
            let label = UILabel()
            label.text = item.label
            label.font = font
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.isAccessibilityElement = false
            addSubview(label)
            return label
        }
        lastCentred = -1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = max(0, (bounds.height - rowHeight) / 2)
        if contentInset.top != inset { contentInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0) }
        contentSize = CGSize(width: bounds.width, height: rowHeight * CGFloat(items.count))
        for (i, label) in labels.enumerated() {
            label.frame = CGRect(x: 2, y: CGFloat(i) * rowHeight, width: bounds.width - 4, height: rowHeight)
        }
        if !isDragging && !isDecelerating { scroll(toValue: selected, animated: false) }
        styleRows()
    }

    private var centredIndex: Int {
        let y = contentOffset.y + contentInset.top + rowHeight / 2
        return min(max(0, Int(y / rowHeight)), max(0, items.count - 1))
    }

    private func offset(forIndex index: Int) -> CGFloat {
        CGFloat(index) * rowHeight - contentInset.top
    }

    private func scroll(toValue value: Int, animated: Bool) {
        guard let index = items.firstIndex(where: { $0.value == value }) else { return }
        let target = offset(forIndex: index)
        if abs(contentOffset.y - target) > 0.5 {
            setContentOffset(CGPoint(x: 0, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func styleRows() {
        let centre = centredIndex
        for (i, label) in labels.enumerated() {
            label.textColor = i == centre ? highlight : rowText.withAlphaComponent(0.55)
            label.font = label.font.withTraits(bold: i == centre)
        }
        accessibilityValue = items.indices.contains(centre) ? items[centre].label : nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let centre = centredIndex
        if centre != lastCentred {
            if haptic && lastCentred >= 0 && isTracking { feedback.selectionChanged() }
            lastCentred = centre
            styleRows()
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let raw = (targetContentOffset.pointee.y + contentInset.top) / rowHeight
        let index = min(max(0, Int(raw.rounded())), max(0, items.count - 1))
        targetContentOffset.pointee.y = offset(forIndex: index)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { commit() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { commit() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { commit() }

    private func commit() {
        guard items.indices.contains(centredIndex) else { return }
        let value = items[centredIndex].value
        if value != selected { selected = value; onSelect(value) }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let y = gesture.location(in: self).y
        let index = Int(y / rowHeight)
        guard items.indices.contains(index) else { return }
        setContentOffset(CGPoint(x: 0, y: offset(forIndex: index)), animated: !UIAccessibility.isReduceMotionEnabled)
        if UIAccessibility.isReduceMotionEnabled { commit() }
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ delta: Int) {
        guard let index = items.firstIndex(where: { $0.value == selected }), items.indices.contains(index + delta) else { return }
        let value = items[index + delta].value
        selected = value
        onSelect(value)
        UIAccessibility.post(notification: .announcement, argument: items[index + delta].label)
    }
}

private extension UIFont {
    func withTraits(bold: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
