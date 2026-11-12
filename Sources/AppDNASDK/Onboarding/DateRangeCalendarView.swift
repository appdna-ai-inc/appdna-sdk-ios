import SwiftUI

/// The range calendar a Date Picker draws for `field_config.selection_mode: "range"`: a month grid with the week's
/// days across the top, the picked days joined by a bar in `range_color`, and the two ends filled with the accent.
/// Tapping the month and year opens a list of years to jump to; the chevrons move a month. Days outside the
/// picker's bounds are dimmed and cannot be picked. Android `DateRangeCalendar` draws the same.
struct DateRangeCalendarView: View {
    @Binding var selection: DateRangeSelection
    let bounds: ClosedRange<Date>
    let accent: Color
    let rangeFill: Color
    let text: Color
    let initialMonth: Date

    @State private var month: Date?
    @State private var showingYears = false

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = .current
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private func firstOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private var shown: Date { month ?? firstOfMonth(initialMonth) }

    private var title: String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return f.string(from: shown)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if showingYears { yearList } else { monthGrid }
        }
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingYears.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title).font(.headline).foregroundColor(text)
                    Image(systemName: showingYears ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundColor(accent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("date_range.header")
            Spacer()
            if !showingYears {
                Button { step(-1) } label: { Image(systemName: "chevron.left").foregroundColor(accent) }
                    .buttonStyle(.plain).padding(.horizontal, 8)
                    .disabled(firstOfMonth(bounds.lowerBound) >= shown)
                    .accessibilityIdentifier("date_range.previous")
                Button { step(1) } label: { Image(systemName: "chevron.right").foregroundColor(accent) }
                    .buttonStyle(.plain).padding(.horizontal, 8)
                    .disabled(firstOfMonth(bounds.upperBound) <= shown)
                    .accessibilityIdentifier("date_range.next")
            }
        }
    }

    private func step(_ by: Int) {
        if let d = cal.date(byAdding: .month, value: by, to: shown) { month = d }
    }

    private var monthGrid: some View {
        let symbols: [String] = {
            let s = cal.veryShortStandaloneWeekdaySymbols
            let k = cal.firstWeekday - 1
            return Array(s[k...] + s[..<k])
        }()
        let days = cal.range(of: .day, in: .month, for: shown)?.count ?? 30
        let lead = (cal.component(.weekday, from: shown) - cal.firstWeekday + 7) % 7
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.semibold)).foregroundColor(text.opacity(0.5)).frame(height: 20)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day, let date = cal.date(byAdding: .day, value: day - 1, to: shown) {
                    dayCell(day: day, key: dayFormatter.string(from: date), date: date)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(day: Int, key: String, date: Date) -> some View {
        let lo = dayFormatter.string(from: bounds.lowerBound)
        let hi = dayFormatter.string(from: bounds.upperBound)
        let enabled = key >= lo && key <= hi
        let s = selection.start, e = selection.end
        let isStart = key == s
        let isEnd = key == e
        let inside = s != nil && e != nil && key > s! && key < e!
        let complete = s != nil && e != nil && s != e
        ZStack {
            // The bar: full width inside the range, half width behind each end.
            HStack(spacing: 0) {
                Rectangle().fill((inside || (isEnd && complete)) ? rangeFill : .clear)
                Rectangle().fill((inside || (isStart && complete)) ? rangeFill : .clear)
            }
            .frame(height: 34)
            if isStart || isEnd {
                Circle().fill(accent).frame(width: 34, height: 34)
            }
            Text("\(day)")
                .font(.body.weight(isStart || isEnd ? .semibold : .regular))
                .foregroundColor(isStart || isEnd ? .white : text)
        }
        .frame(height: 40)
        .opacity(enabled ? 1 : 0.3)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { selection = selection.tapping(key) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)))
        .accessibilityAddTraits(isStart || isEnd || inside ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("date_range.day.\(key)")
    }

    private var yearList: some View {
        let lo = cal.component(.year, from: bounds.lowerBound)
        let hi = Swift.max(lo, cal.component(.year, from: bounds.upperBound))
        let current = cal.component(.year, from: shown)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(lo...hi, id: \.self) { y in
                        Button {
                            var c = cal.dateComponents([.year, .month], from: shown)
                            c.year = y
                            if let d = cal.date(from: c) {
                                month = Swift.min(Swift.max(d, firstOfMonth(bounds.lowerBound)), firstOfMonth(bounds.upperBound))
                            }
                            withAnimation(.easeInOut(duration: 0.2)) { showingYears = false }
                        } label: {
                            Text(String(y))
                                .font(.body.weight(y == current ? .semibold : .regular))
                                .foregroundColor(y == current ? .white : text)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(Capsule().fill(y == current ? accent : .clear))
                        }
                        .buttonStyle(.plain)
                        .id(y)
                        .accessibilityIdentifier("date_range.year.\(y)")
                    }
                }
            }
            .frame(height: 280)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}
