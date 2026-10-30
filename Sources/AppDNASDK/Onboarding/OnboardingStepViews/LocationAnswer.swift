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
///   `raw_query` is the text the user typed to find the place. `mapbox_id` / `place_id`
///   only for an answer a resolve reply produced — the provenance the server's ingest keys on.
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
        rawQuery: String? = nil,
        mapboxId: String? = nil,
        placeId: String? = nil
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
        if let v = present(mapboxId) { out["mapbox_id"] = v }
        if let v = present(placeId) { out["place_id"] = v }
        return out
    }

    /// A location the user picked: a resolve reply, or a full suggestion from a
    /// path that predates resolving. `rawQuery` is the text in the field; the location's own `raw_query` is the
    /// fallback (a resolve reply carries none). The provenance ids are written only when the
    /// location carries them, which only a decoded resolve reply does (`decodeSuggestionItems` never
    /// fills them).
    static func selection(from s: LocationData, rawQuery: String?) -> [String: Any] {
        let typed = rawQuery.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return selection(
            formattedAddress: s.formatted_address,
            city: s.city, state: s.state, stateCode: s.state_code,
            country: s.country, countryCode: s.country_code,
            latitude: s.latitude, longitude: s.longitude,
            timezone: s.timezone, timezoneOffsetMinutes: s.timezone_offset,
            postalCode: s.postal_code,
            rawQuery: typed ?? s.raw_query,
            mapboxId: s.mapbox_id,
            placeId: s.place_id
        )
    }

    /// The server's `data.suggestions` items → suggestions, read tolerantly with the same rules
    /// `getLocationData` uses (a wrong-typed field is absent; the suggestion is kept). It used to go
    /// through `JSONDecoder`, which dropped a whole suggestion over one wrong-typed field while Android
    /// kept it.
    static func decodeSuggestions(_ items: [[String: Any]]) -> [LocationData] {
        decodeSuggestionItems(items).map(\.data)
    }

    /// The same decode, keeping each suggestion's own `id` and `provider` on
    /// the internal wrapper the tap path reads. A display-only suggestion (`{id, provider,
    /// formatted_address, name, place_formatted}`) decodes to a `LocationData` holding only its
    /// display line.
    ///
    /// 🔴 A suggestion never fills `mapbox_id` / `place_id`, whatever keys it carries: those mark an
    /// answer a resolve reply produced, and a suggestion is a temporary result that may not be stored.
    static func decodeSuggestionItems(_ items: [[String: Any]]) -> [LocationSuggestionItem] {
        items.compactMap { item in
            guard let d = LocationData.fromStoredAnswer(item) else { return nil }
            let data = LocationData(
                formatted_address: d.formatted_address,
                city: d.city, state: d.state, state_code: d.state_code,
                country: d.country, country_code: d.country_code,
                latitude: d.latitude, longitude: d.longitude,
                timezone: d.timezone, timezone_offset: d.timezone_offset,
                postal_code: d.postal_code, raw_query: d.raw_query
            )
            func nonBlank(_ key: String) -> String? {
                guard let s = item[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return s
            }
            return LocationSuggestionItem(data: data, id: nonBlank("id"), provider: nonBlank("provider"))
        }
    }

    /// The ONE rule for the text a location field shows for a stored answer, on
    /// both iOS surfaces, after a tap and on a restore alike: a selection shows its
    /// `formatted_address` (else the legacy `address`), a typed answer shows itself. Anything else
    /// (absent, empty, a number) shows nothing (nil).
    ///
    /// It replaces two city / state / country builders (`formatDisplay`, `formatLocationDisplay`),
    /// which for a resolved address showed the containing city instead of the tapped street, and for
    /// a resolved region or country an empty or comma-led line.
    static func fieldText(forStored value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        let dict: [String: Any]?
        if let d = value as? [String: Any] { dict = d }
        else if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            dict = out
        } else { dict = nil }
        guard let dict else { return nil }
        let line = (dict["formatted_address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (dict["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return line
    }

    /// Whether a stored answer came from Google: a selection carrying a non-blank `place_id`, which
    /// only a Google resolve reply fills. Google's terms require attribution wherever such an
    /// answer's content is shown without a Google map, so this one rule decides the logo kept beside
    /// a field, the credit an onboarding step draws for text templating the answer, and the typed
    /// text every other surface's templates show in its place.
    static func carriesPlaceId(_ value: Any?) -> Bool {
        let dict: [String: Any]
        if let d = value as? [String: Any] { dict = d }
        else if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            dict = out
        } else { return false }
        guard let id = dict["place_id"] as? String else { return false }
        return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text the first edit of a field showing a Google answer restarts from. The field shows
    /// Google's line (`shown`), which must never be stored or sent, so the edit goes back to the
    /// user's own words, the answer's `raw_query`. It is decided by the RESULTING text, not by the
    /// gesture that produced it: when `edited` is Google's whole line followed by more characters,
    /// those characters are appended to `raw_query`; any other result (shorter than the line, or not
    /// beginning with all of it) leaves the typed text alone. So a paste or a replacement inside the
    /// line that leaves the line intact at the start, with more after it, is an append too. The
    /// result is ordinary typed text from then on.
    ///
    /// Compared in UTF-16 code units, exactly as Android compares them: a combining mark typed after the
    /// line's last letter (U+0301 after "A") is an append of one unit here, though Swift's own `String`
    /// would count it as part of the last character.
    static func editRestart(rawQuery: String, shown: String, edited: String) -> String {
        let e = Array(edited.utf16), s = Array(shown.utf16)
        if e.count > s.count, e.starts(with: s) {
            return rawQuery + String(decoding: e[s.count...], as: UTF16.self)
        }
        return rawQuery
    }

    /// A Google answer's `raw_query` ("" when it has none). nil for anything that is not a Google
    /// answer.
    static func googleRawQuery(_ value: Any?) -> String? {
        guard carriesPlaceId(value) else { return nil }
        let raw = (value as? [String: Any])?["raw_query"] ?? (value as? NSDictionary)?["raw_query"]
        return (raw as? String) ?? ""
    }

}

/// One autocomplete suggestion as the tap path needs it: the decoded display data,
/// and the suggestion's own `id` / `provider`. Internal on purpose: the public `Codable`
/// `LocationData` never carries a suggestion id, so `getLocationData` and the wrapper mappers cannot
/// expose one. A suggestion with no `id` (a server that predates resolving, or a rollback) cannot be resolved,
/// and a tap on it stores the typed text.
struct LocationSuggestionItem: Sendable {
    let data: LocationData
    let id: String?
    let provider: String?
}

/// The two lines one autocomplete suggestion shows in the dropdown.
///
/// 🔴 ONE RULE FOR EVERY SURFACE AND BOTH PLATFORMS. This used to be four rules: the iOS
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
