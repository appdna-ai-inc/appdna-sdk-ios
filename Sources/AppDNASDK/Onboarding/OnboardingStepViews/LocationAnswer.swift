import Foundation

/// What a location field stores as its answer. One rule for both writers (the form-step
/// Location field and the `input_location` content block) and for both platforms (Android
/// `LocationAnswer.kt`); the `location_answer_from_input` shared fixtures pin it.
///
/// - Typed but not selected: the typed `String`, as typed.
/// - A selection: a dict with `formatted_address` (and `address`, its legacy alias) plus each of
///   `city`, `state`, `state_code`, `country`, `country_code`, `latitude`, `longitude`, `timezone`,
///   `timezone_offset`, `postal_code` and `raw_query` ONLY when the lookup has it. A blank string, a
///   non-finite coordinate or a failed time-zone lookup is left out — never stored as `""`, `0` or
///   `"UTC"`. `timezone_offset` (minutes east of UTC) is kept only together with a `timezone`.
///   `raw_query` is the text the user typed to find the place.
enum LocationAnswer {

    /// Typing without selecting stores the text itself.
    static func typed(_ text: String) -> String { text }

    static func selection(
        formattedAddress: String,
        city: String? = nil,
        state: String? = nil,
        stateCode: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        timezone: String? = nil,
        timezoneOffsetMinutes: Int? = nil,
        postalCode: String? = nil,
        rawQuery: String? = nil
    ) -> [String: Any] {
        func present(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        var out: [String: Any] = ["formatted_address": formattedAddress, "address": formattedAddress]
        if let v = present(city) { out["city"] = v }
        if let v = present(state) { out["state"] = v }
        if let v = present(stateCode) { out["state_code"] = v }
        if let v = present(country) { out["country"] = v }
        if let v = present(countryCode) { out["country_code"] = v }
        if let v = latitude, v.isFinite { out["latitude"] = v }
        if let v = longitude, v.isFinite { out["longitude"] = v }
        if let tz = present(timezone) {
            out["timezone"] = tz
            if let off = timezoneOffsetMinutes { out["timezone_offset"] = off }
        }
        if let v = present(postalCode) { out["postal_code"] = v }
        if let v = present(rawQuery) { out["raw_query"] = v }
        return out
    }

    /// A server autocomplete suggestion the user picked. `rawQuery` is the text in the field; the
    /// suggestion's own `raw_query` is the fallback.
    static func selection(from s: LocationData, rawQuery: String?) -> [String: Any] {
        let typed = rawQuery.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return selection(
            formattedAddress: s.formatted_address,
            city: s.city, state: s.state, stateCode: s.state_code,
            country: s.country, countryCode: s.country_code,
            latitude: s.latitude, longitude: s.longitude,
            timezone: s.timezone, timezoneOffsetMinutes: s.timezone_offset,
            postalCode: s.postal_code,
            rawQuery: typed ?? s.raw_query
        )
    }

    /// The server's `data.suggestions` items → suggestions, read tolerantly with the same rules
    /// `getLocationData` uses (a wrong-typed field is absent; the suggestion is kept). It used to go
    /// through `JSONDecoder`, which dropped a whole suggestion over one wrong-typed field while Android
    /// kept it.
    static func decodeSuggestions(_ items: [[String: Any]]) -> [LocationData] {
        items.compactMap { LocationData.fromStoredAnswer($0) }
    }

}

/// The two lines one autocomplete suggestion shows in the dropdown.
///
/// 🔴 ONE RULE FOR EVERY SURFACE AND BOTH PLATFORMS (#963). This used to be four rules: the iOS
/// content block took MapKit's own `title`/`subtitle`, the iOS form-step field showed
/// `city` over `"state, country"`, and the two Android surfaces each split the address on its first
/// comma — one with a city/country fallback and one without. Routing the iOS content block through
/// the geocoding proxy removed MapKit's pre-split strings and so required picking a rule; picking
/// it once, here, is what stops a fifth appearing. `LocationAnswer.displayLines` in
/// `LocationAnswer.kt` is the Kotlin twin, and `location_suggestion_display_lines` pins the pair.
///
/// `formatted_address` is a comma-separated address, so its first segment is the place and the
/// remainder is where it is. The `city, country` fallback covers a single-segment address (a
/// country-level suggestion), which would otherwise show one line and no context.
extension LocationAnswer {
    static func displayLines(_ s: LocationData) -> (title: String, subtitle: String) {
        let address = s.formatted_address
        let comma = address.firstIndex(of: ",")
        let head = comma.map { String(address[address.startIndex..<$0]) } ?? address
        let tail = comma.map { String(address[address.index(after: $0)...]) } ?? ""
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = trimmed(head).isEmpty ? address : trimmed(head)
        var subtitle = trimmed(tail)
        if subtitle.isEmpty {
            // A fallback part equal to the title is dropped: a single-segment city suggestion would
            // otherwise read "Kyoto / Kyoto, Japan".
            subtitle = [s.city, s.country]
                .compactMap { $0.flatMap { trimmed($0).isEmpty ? nil : trimmed($0) } }
                .filter { $0 != title }
                .joined(separator: ", ")
        }
        return (title, subtitle)
    }
}
