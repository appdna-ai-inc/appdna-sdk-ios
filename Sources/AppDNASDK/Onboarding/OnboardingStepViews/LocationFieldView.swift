import SwiftUI

/// Structured location data — a geocoding suggestion, or what `AppDNA.getLocationData(fieldId:)`
/// builds from a stored location answer.
///
/// Every field except `formatted_address` is optional: a stored answer may be a typed string (no
/// coordinates), a legacy `{address, latitude, longitude}` dict, or a selection that lacked some keys.
public struct LocationData: Codable, Equatable {
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
        raw_query: String? = nil
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
            raw_query: str("raw_query")
        )
    }
}

/// Autocomplete location field for onboarding form steps.
/// Debounces user input, calls backend proxy for suggestions, displays dropdown.
struct LocationFieldView: View {
    let field: FormField
    @Binding var value: Any?
    let apiClient: APIClient?

    @State private var query = ""
    @State private var suggestions: [LocationData] = []
    @State private var isLoading = false
    @State private var isExpanded = false
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var selectedLocation: LocationData? {
        if let loc = value as? LocationData { return loc }
        // A selection is a dict; a typed string is not a selection.
        guard value is [String: Any] || value is NSDictionary else { return nil }
        return LocationData.fromStoredAnswer(value)
    }

    private var minChars: Int {
        (field.config?.location_min_chars as? Int) ?? 2
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
                    text: $query,
                    placeholder: placeholder,
                    keyboardType: .default,
                    onEditingChanged: { editing in
                        if editing { isFocused = true } else { isFocused = false }
                    }
                )
                .frame(height: 20)
                .onChange(of: query) { newValue in
                    onQueryChanged(newValue)
                    storeTyped(newValue)
                }

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if selectedLocation != nil {
                    Button(action: clearSelection) {
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

            if isExpanded && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(5).enumerated()), id: \.offset) { idx, suggestion in
                        Button(action: { selectSuggestion(suggestion) }) {
                            HStack {
                                Image(systemName: "mappin")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    // Primary line: City (or fallback to country if city empty)
                                    Text((suggestion.city ?? "").isEmpty ? (suggestion.country ?? "") : (suggestion.city ?? ""))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    // Secondary line: "State, Country" or just "Country"
                                    // (no street names per user request)
                                    let secondary: String = {
                                        let state = suggestion.state ?? "", country = suggestion.country ?? ""
                                        if !state.isEmpty && !country.isEmpty {
                                            return "\(state), \(country)"
                                        } else if !country.isEmpty {
                                            return country
                                        }
                                        return ""
                                    }()
                                    if !secondary.isEmpty {
                                        Text(secondary)
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
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused {
                // Delay slightly so button taps on dropdown items register first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !isFocused {
                        isExpanded = false
                    }
                }
            }
        }
        .onAppear {
            // Restore from saved dict on re-entry (back navigation). Rebuild the
            // display query text from city/state/country so the field doesn't
            // show an empty placeholder after back-navigating to this step.
            if query.isEmpty, let typed = value as? String, !typed.isEmpty {
                // A typed (not selected) answer is restored as typed.
                query = typed
            } else if query.isEmpty, let dict = value as? [String: Any] {
                let city = (dict["city"] as? String) ?? ""
                let state = (dict["state"] as? String) ?? ""
                let country = (dict["country"] as? String) ?? ""
                if !city.isEmpty {
                    query = Self.formatDisplay(city: city, state: state, country: country)
                }
                // Never log the restored dict — it carries city/state/country and
                // (for placemark-backed values) coordinates.
                Log.debug("LocationField restored a saved value")
            }
            // Pre-warm the iOS keyboard subsystem so the first keystroke
            // doesn't show the 200-400ms lag customers see on empty-field
            // first-focus. An invisible UITextField is briefly added to the
            // key window, made firstResponder, then immediately resigned —
            // enough to trigger keyboard extension / dictionary / haptic
            // engine loading without any visible flash.
            KeyboardPrewarmer.prewarmOnce()
        }
    }

    private func onQueryChanged(_ newValue: String) {
        debounceTask?.cancel()

        if newValue.count < minChars {
            suggestions = []
            isExpanded = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            if !Task.isCancelled {
                await fetchSuggestions(query: newValue)
            }
        }
    }

    private func fetchSuggestions(query: String) async {
        guard let client = apiClient else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var body: [String: Any] = ["query": query, "limit": 5]
            if let t = field.config?.location_type { body["type"] = t }
            if let c = field.config?.location_bias_country { body["bias_country"] = c }
            if let l = field.config?.location_language { body["language"] = l }

            let jsonData = try JSONSerialization.data(withJSONObject: body)

            let endpoint = Endpoint.geocodeAutocomplete
            guard let url = endpoint.url(environment: client.environment) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(client.apiKey, forHTTPHeaderField: "x-api-key")
            // The server answers null for a missing coordinate / zone only to an SDK that says it reads
            // null (iOS >= 1.0.82); without these headers it sends the legacy 0 / "UTC" shape.
            request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
            request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataObj = json?["data"] as? [String: Any]
            let suggestionsArr = dataObj?["suggestions"] as? [[String: Any]] ?? []

            let decoded = LocationAnswer.decodeSuggestions(suggestionsArr)
            await MainActor.run {
                suggestions = decoded
                isExpanded = !decoded.isEmpty
            }
        } catch {
            Log.warning("Location autocomplete failed: \(error.localizedDescription)")
        }
    }

    private func selectSuggestion(_ suggestion: LocationData) {
        // The text the user typed to find this place — read before `query` shows the selection.
        let typed = query
        // Build display: "City / State, Country" or "City, Country"
        let display = Self.formatDisplay(
            city: suggestion.city ?? "",
            state: suggestion.state ?? "",
            country: suggestion.country ?? ""
        )
        // The one stored shape on both platforms and both writers (`LocationAnswer`).
        // Stored BEFORE `query` changes, so `storeTyped` sees the selection and leaves it alone.
        value = LocationAnswer.selection(from: suggestion, rawQuery: typed)
        query = display

        suggestions = []
        isExpanded = false
        isFocused = false  // dismiss keyboard

        // Log the fact of a selection, never the user's location. A raw `print`
        // here is unconditional — it reaches release builds and the host's crash
        // reporter / device console.
        Log.debug("Location suggestion selected")
    }

    /// Typing without selecting stores the typed text, as Android and the
    /// `input_location` block do (this field used to store nothing, so `getLocationData` returned nil
    /// and a required field stayed empty). Editing after a selection replaces it with the text. The
    /// display text a selection or a restore writes into `query` is not typing: it is skipped.
    private func storeTyped(_ newValue: String) {
        if let dict = value as? [String: Any] {
            let shown = Self.formatDisplay(
                city: (dict["city"] as? String) ?? "",
                state: (dict["state"] as? String) ?? "",
                country: (dict["country"] as? String) ?? ""
            )
            if newValue == shown { return }
        }
        if let current = value as? String, current == newValue { return }
        if newValue.isEmpty && value == nil { return }
        value = newValue.isEmpty ? nil : LocationAnswer.typed(newValue)
    }

    private func clearSelection() {
        query = ""
        value = nil
        suggestions = []
        isExpanded = false
    }

    /// Formats "City / State, Country" or "City, Country" based on whether state is present.
    static func formatDisplay(city: String, state: String, country: String) -> String {
        if !state.isEmpty && !country.isEmpty {
            return "\(city) / \(state), \(country)"
        } else if !country.isEmpty {
            return "\(city), \(country)"
        } else {
            return city
        }
    }
}
