import SwiftUI

/// Structured location data — a geocoding suggestion, or what `AppDNA.getLocationData(fieldId:)`
/// builds from a stored location answer.
///
/// Every field except `formatted_address` is optional: a stored answer may be a typed string (no
/// coordinates), a legacy `{address, latitude, longitude}` dict, or a selection that lacked some keys.
public struct LocationData: Codable, Equatable, Sendable {
    public let formatted_address: String
    public let city: String?
    public let state: String?
    public let state_code: String?
    public let country: String?
    public let country_code: String?
    public let latitude: Double?
    public let longitude: Double?
    public let timezone: String?
    public let timezone_offset: Int?
    public let postal_code: String?
    public let raw_query: String?
    /// The provenance of a RESOLVED answer: `mapbox_id` marks a Mapbox answer
    /// geocoded permanently, `place_id` a Google one. Only a resolve reply fills them; a
    /// suggestion's own `id` never lands here (it rides on the internal `LocationSuggestionItem`), so an
    /// unresolved or typed answer stays legacy and ingest reduces it to the typed text.
    /// `mapbox_id` is an opaque marker, not a stable place id: for an interpolated address it encodes
    /// the request that produced it and runs to hundreds of characters.
    public let mapbox_id: String?
    public let place_id: String?

    init(
        formatted_address: String,
        city: String? = nil,
        state: String? = nil,
        state_code: String? = nil,
        country: String? = nil,
        country_code: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        timezone: String? = nil,
        timezone_offset: Int? = nil,
        postal_code: String? = nil,
        raw_query: String? = nil,
        mapbox_id: String? = nil,
        place_id: String? = nil
    ) {
        self.formatted_address = formatted_address
        self.city = city
        self.state = state
        self.state_code = state_code
        self.country = country
        self.country_code = country_code
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.timezone_offset = timezone_offset
        self.postal_code = postal_code
        self.raw_query = raw_query
        self.mapbox_id = mapbox_id
        self.place_id = place_id
    }

    /// Builds the result from a stored location answer, tolerantly and WITHOUT any
    /// serialisation. (`JSONSerialization.data(withJSONObject:)` raises an Objective-C exception for a
    /// string / number / `NSNull` top level, which `try?` cannot catch — that aborted the host app.)
    ///
    /// - A non-empty `String` (typed, not selected) → `{formatted_address, raw_query}` = the text.
    /// - A `[String: Any]` → every field read with `as?`; a legacy `address` key maps to
    ///   `formatted_address`; a coordinate is kept only when it is a finite number.
    /// - Anything else (empty string, number, `NSNull`, absent) → nil.
    static func fromStoredAnswer(_ value: Any?) -> LocationData? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : LocationData(formatted_address: text, raw_query: text)
        }
        let dict: [String: Any]
        if let d = value as? [String: Any] {
            dict = d
        } else if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            dict = out
        } else {
            return nil
        }
        func str(_ key: String) -> String? {
            guard let s = dict[key] as? String else { return nil }
            return s
        }
        func coord(_ key: String) -> Double? {
            // Every number (Swift or bridged) arrives as an NSNumber; only a CFBoolean is a Bool.
            // (`raw is Bool` was also true for an NSNumber 0 / 1 — it dropped the 0.0 and 1.0
            // coordinates.)
            guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d: Double? = n.doubleValue
            guard let d, d.isFinite else { return nil }
            return d
        }
        func int(_ key: String) -> Int? {
            if let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
            return dict[key] as? Int
        }
        let formatted = str("formatted_address") ?? str("address") ?? ""
        return LocationData(
            formatted_address: formatted,
            city: str("city"),
            state: str("state"),
            state_code: str("state_code"),
            country: str("country"),
            country_code: str("country_code"),
            latitude: coord("latitude"),
            longitude: coord("longitude"),
            timezone: str("timezone"),
            timezone_offset: int("timezone_offset"),
            postal_code: str("postal_code"),
            raw_query: str("raw_query"),
            // The provenance a resolve reply carries, kept with the stored answer.
            // Never a suggestion's `id`: that key is not read here.
            mapbox_id: str("mapbox_id"),
            place_id: str("place_id")
        )
    }
}

/// Autocomplete location field for onboarding form steps.
///
/// The list, the text, the debounce, the tap → resolve and the dropdown live in
/// `LocationSuggestionSearch`, the ONE holder this field and the `input_location` content block share
/// (they were `private @State` here and could not be driven by a test). This view owns focus and
/// layout, and persists what the holder writes into `value`.
struct LocationFieldView: View {
    let field: FormField
    @Binding var value: Any?
    let apiClient: APIClient?

    @StateObject private var locationSearch: LocationSuggestionSearch
    /// Whether the text field is being edited, as its own `onEditingChanged` reports it. Plain state:
    /// this was a `@FocusState` bound to no view, and SwiftUI drops writes to one of those, so it never
    /// changed, `.onChange(of: isFocused)` never ran, and leaving the field never ended its search — a
    /// debounced search still pending (the one a blur's commit of a composition after Google's line
    /// starts, among others) fired and opened the dropdown under a field the user had left. The
    /// `input_location` block already reports the leaving through its own state.
    @State private var isFocused = false
    /// The form step's settlement: Continue settles this field before it submits (a resolve in
    /// flight stores the typed text). `onDisappear` runs only after the answers were submitted.
    @SwiftUI.Environment(\.locationAdvanceSettlement) private var locationSettlement
    /// What is behind the field, for the Google logo kept beside a Google answer.
    @SwiftUI.Environment(\.googleAttributionBackdrop) private var attributionBackdrop

    /// `search` is a test seam: a render test hands in a holder it drives. Production builds its own.
    init(field: FormField, value: Binding<Any?>, apiClient: APIClient?, search: LocationSuggestionSearch? = nil) {
        self.field = field
        self._value = value
        self.apiClient = apiClient
        // Built once per field (a `@StateObject`'s autoclosure): the answer held when the step is
        // entered is restored into the text at once; one seeded later is restored reactively.
        _locationSearch = StateObject(wrappedValue: search ?? LocationSuggestionSearch(
            storedAnswer: value.wrappedValue,
            client: { apiClient }
        ))
    }

    private var selectedLocation: LocationData? {
        if let loc = value as? LocationData { return loc }
        // A selection is a dict; a typed string is not a selection.
        guard value is [String: Any] || value is NSDictionary else { return nil }
        return LocationData.fromStoredAnswer(value)
    }

    /// Resolved by the shared `LocationSearchSettings`, the same one the `input_location`
    /// content block uses, so the two surfaces cannot drift apart again.
    private var search: LocationSearchSettings {
        LocationSearchSettings.from(fieldConfig: field.config, defaultMinChars: 2)
    }

    private var placeholder: String {
        (field.config?.location_placeholder as? String) ?? "Search for a location..."
    }

    var body: some View {
        // Inline layout — dropdown is a real VStack child (clickable + no
        // hit-test issues). Parent ScrollView uses .ignoresSafeArea(.keyboard)
        // to prevent keyboard auto-scroll from repositioning siblings.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                // Use UIKitTextField to prevent SwiftUI's auto-scroll-to-focus
                // behavior which pushes the location field upward when keyboard
                // appears. UIKit-backed fields don't participate in SwiftUI's
                // ScrollView focus tracking system.
                UIKitTextField(
                    text: $locationSearch.text,
                    placeholder: placeholder,
                    keyboardType: .default,
                    // The key reads Search, as on the `input_location` block and on Android; pressing it
                    // leaves the field, which closes the dropdown.
                    returnKeyType: .search,
                    onEditingChanged: { editing in
                        if editing { isFocused = true } else { isFocused = false }
                    },
                    // An IME composition is not an edit until it commits.
                    onCompositionChange: { locationSearch.compositionChanged($0, settings: search) },
                    // Google's line, replaced by the user's own text, must not come back by an undo:
                    // the history goes with every text the holder sets, and with a first edit of the
                    // line that already left the user's own text.
                    clearsUndoOnProgrammaticSet: true,
                    undoHistoryGeneration: locationSearch.textSets
                )
                .frame(height: 20)
                // Every change, programmatic ones included, goes to the holder's
                // one entry point, which skips the echo of its own set (a resolve or a restore) and
                // treats anything else as typing.
                .onChange(of: locationSearch.text) { newValue in
                    locationSearch.textChanged(newValue, settings: search)
                }

                if locationSearch.isSearching || locationSearch.isResolving {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if selectedLocation != nil {
                    Button(action: { locationSearch.clear() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            let suggestions = locationSearch.results
            if locationSearch.isDropdownOpen && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    // Google's attribution heads the Google suggestions, inside the dropdown: the list
                    // is Google content shown without a Google map. At the TOP, directly under the
                    // field, which the system keeps above the keyboard, so the logo is on screen
                    // whenever the list is; under the last row it fell behind the keyboard and the
                    // pinned button. The dropdown's surface is the system background, so the plain
                    // variant follows the appearance.
                    if locationSearch.showsGoogleLogo {
                        GoogleMapsLogoView(backdrop: .plain(hex: nil))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(suggestions.prefix(5).enumerated()), id: \.offset) { idx, listed in
                        Button(action: { selectSuggestion(listed) }) {
                            HStack {
                                Image(systemName: "mappin")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                // The ONE row rule every surface draws from. This row
                                // used to be built from city / state / country, which a display-only
                                // suggestion does not carry: every row would have been a bare pin. The
                                // "no street names" choice is the field's TYPE now — an address field
                                // lists streets; a city / region / country display line holds none.
                                let lines = LocationAnswer.displayLines(listed.data)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lines.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    if !lines.subtitle.isEmpty {
                                        Text(lines.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < min(suggestions.count, 5) - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            } else if LocationAnswer.carriesPlaceId(value) {
                // A Google answer keeps its attribution after the dropdown closes, and when it is
                // restored on returning to the step: the field shows Google content.
                GoogleMapsLogoView(backdrop: attributionBackdrop)
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused {
                // Delay slightly so button taps on dropdown items register first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !isFocused {
                        locationSearch.editingEnded()
                    }
                }
            }
        }
        // A stored answer that appears after the field was built (the parent seeds
        // `values` in its own `.onAppear`) is restored while the text is empty. The key is the text
        // the answer would show, which changes exactly when the answer's presence or line does.
        .onChange(of: LocationAnswer.fieldText(forStored: value)) { _ in
            locationSearch.storedAnswerChanged(value)
        }
        .onAppear {
            locationSearch.attach(store: { newValue in value = newValue })
            locationSettlement?.register(fieldId: field.id, holder: locationSearch)
            locationSearch.storedAnswerChanged(value)
            // Pre-warm the iOS keyboard subsystem so the first keystroke
            // doesn't show the 200-400ms lag customers see on empty-field
            // first-focus. An invisible UITextField is briefly added to the
            // key window, made firstResponder, then immediately resigned —
            // enough to trigger keyboard extension / dictionary / haptic
            // engine loading without any visible flash.
            KeyboardPrewarmer.prewarmOnce()
        }
        .onDisappear {
            // A resolve still in flight stores the typed text, and its late reply is dropped.
            locationSettlement?.unregister(locationSearch)
            locationSearch.detach()
        }
    }

    private func selectSuggestion(_ listed: LocationListedSuggestion) {
        // The keyboard stays as it was, as on Android's form-step field: this line used to write
        // `isFocused = false` to "dismiss the keyboard", which never did anything (see `isFocused`), and
        // with `isFocused` live it would mark a field still being edited as left.
        locationSearch.select(listed)
        // Log the fact of a selection, never the user's location. A raw `print`
        // here is unconditional — it reaches release builds and the host's crash
        // reporter / device console.
        Log.debug("Location suggestion selected")
    }
}
