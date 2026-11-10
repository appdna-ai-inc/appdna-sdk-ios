import Foundation

/// Time and date-and-time answers: the shapes they are stored in, the older shapes still read, and the text a template
/// draws for them. All in one zone: the app's (`AppDNA.appTimeZone`), UTC when the app has none.
///
/// - date-and-time: `2026-11-10T15:03:00+01:00` (UTC as `Z`);
/// - time: `15:03:00+01:00`, the offset the zone had on the day it was picked. A time of day has no date, so a full
///   moment would put a meaningless date into every template that shows it.
///
/// Older answers still read: a UTC instant (`2026-11-10T14:03:00Z`), and the phone-local `HH:mm` and
/// `yyyy-MM-dd HH:mm`, which are read in the zone given.
enum AnswerTime {
    static var zone: TimeZone { AppDNA.appTimeZone ?? TimeZone(identifier: "UTC")! }

    private static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }

    static func dateTimeString(_ date: Date, in zone: TimeZone) -> String {
        formatter("yyyy-MM-dd'T'HH:mm':00'XXXXX", zone).string(from: date)
    }

    static func timeString(_ date: Date, in zone: TimeZone) -> String {
        formatter("HH:mm':00'XXXXX", zone).string(from: date)
    }

    private static let offset = "(Z|[+-]\\d{2}:?\\d{2})"
    private static let dateTimePattern = try! NSRegularExpression(pattern: "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.\\d{1,9})?)?\(offset)$")
    private static let timePattern = try! NSRegularExpression(pattern: "^(\\d{2}):(\\d{2})(?::(\\d{2}))?\(offset)$")
    private static let localDateTimePattern = try! NSRegularExpression(pattern: "^(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2})$")
    private static let localTimePattern = try! NSRegularExpression(pattern: "^(\\d{2}):(\\d{2})$")

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
    }

    /// Seconds east of UTC for `Z`, `+01:00` or `+0100`.
    private static func offsetSeconds(_ s: String) -> Int? {
        if s == "Z" { return 0 }
        let digits = s.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)), h < 24, m < 60 else { return nil }
        return (s.first == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    private static func moment(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, in zone: TimeZone) -> Date? {
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) else { return nil }
        let got = cal.dateComponents([.year, .month, .day], from: date)
        return got.year == y && got.month == mo && got.day == d ? date : nil
    }

    /// The moment a stored time or date-and-time answer names. A time alone is placed on the day `now` falls on in its
    /// own offset (or, for an older phone-local time, in `zone`). Nil for anything else.
    static func date(from text: String, in zone: TimeZone, now: Date = Date()) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        func int(_ v: String?) -> Int { v.flatMap(Int.init) ?? 0 }
        if let g = groups(dateTimePattern, s), let off = g[6].flatMap(offsetSeconds), let fixed = TimeZone(secondsFromGMT: off) {
            return moment(int(g[0]), int(g[1]), int(g[2]), int(g[3]), int(g[4]), int(g[5]), in: fixed)
        }
        if let g = groups(timePattern, s), let off = g[3].flatMap(offsetSeconds), let fixed = TimeZone(secondsFromGMT: off) {
            return onDay(of: now, in: fixed, int(g[0]), int(g[1]), int(g[2]))
        }
        if let g = groups(localDateTimePattern, s) {
            return moment(int(g[0]), int(g[1]), int(g[2]), int(g[3]), int(g[4]), 0, in: zone)
        }
        if let g = groups(localTimePattern, s) {
            return onDay(of: now, in: zone, int(g[0]), int(g[1]), 0)
        }
        return nil
    }

    private static func onDay(of now: Date, in zone: TimeZone, _ h: Int, _ mi: Int, _ s: Int) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.dateComponents([.year, .month, .day], from: now)
        return moment(day.year ?? 2000, day.month ?? 1, day.day ?? 1, h, mi, s, in: zone)
    }

    /// The text a template draws for a stored answer: a date-and-time as `yyyy-MM-dd HH:mm` and a time as `HH:mm`, in
    /// `zone`. Nil for anything else (a date, a phone-local older answer, any other text), which is drawn as stored.
    static func display(_ text: String, in zone: TimeZone, now: Date = Date()) -> String? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if groups(dateTimePattern, s) != nil, let d = date(from: s, in: zone, now: now) {
            return formatter("yyyy-MM-dd HH:mm", zone).string(from: d)
        }
        if groups(timePattern, s) != nil, let d = date(from: s, in: zone, now: now) {
            return formatter("HH:mm", zone).string(from: d)
        }
        return nil
    }
}
