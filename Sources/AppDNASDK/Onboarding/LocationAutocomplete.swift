import Foundation

/// The ONE location-autocomplete call in the iOS SDK.
///
/// 🔴 #963 — THERE WERE TWO SEARCHES, AND THE SECOND ONE HONOURED NOTHING. The form-step Location
/// field POSTed to the geocoding proxy with all four Console settings; the `input_location` content
/// block ran `MKLocalSearchCompleter` against Apple's place index, which takes no country bias, no
/// language tag and has no city/region/country result type — so three of the four settings an
/// author could set on that block were structurally impossible to honour, and the SDK read none of
/// them. Setting Type = "City" produced street addresses, silently.
///
/// Android has had one search for both surfaces since #963's first half
/// (`fetchLocationSuggestions` in `LocationFieldComposable.kt`). This is iOS's, and the two
/// surfaces now differ only in their `defaultMinChars`.
///
/// What this changed for a published flow: the content block's answer gains `state_code` and the
/// proxy's time zone for the place (it used to reverse-geocode on the device), and loses nothing.
/// That shape change is why it needed the owner's decision rather than being a straight fix.
enum LocationAutocomplete {

    /// `POST /api/v1/sdk/geocode/autocomplete` → at most five suggestions. A failure is an empty
    /// list, never a throw: an autocomplete that cannot reach the server must leave the field
    /// typable rather than break the step.
    /// `session` is a test seam (`LocationAutocompleteTests` serves the proxy's reply from a stub
    /// protocol): production always uses the shared session.
    static func fetch(
        query: String,
        settings: LocationSearchSettings,
        client: APIClient?,
        session: URLSession = .shared
    ) async -> [LocationData] {
        guard let client else { return [] }
        var body: [String: Any] = ["query": query, "limit": 5]
        // Each only when the author chose one — see the note on `LocationSearchSettings.type`. The
        // proxy narrows results only when the key is PRESENT, so sending a substituted default
        // would filter a search the author asked to leave open (#964).
        if let t = settings.type { body["type"] = t }
        if let c = settings.biasCountry { body["bias_country"] = c }
        if let l = settings.language { body["language"] = l }

        guard let url = Endpoint.geocodeAutocomplete.url(environment: client.environment),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.apiKey, forHTTPHeaderField: "x-api-key")
        // The server answers null for a missing coordinate / zone only to an SDK that says it reads
        // null (iOS >= 1.0.82); without these headers it sends the legacy 0 / "UTC" shape.
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")

        do {
            let (data, _) = try await session.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataObj = json?["data"] as? [String: Any]
            let suggestionsArr = dataObj?["suggestions"] as? [[String: Any]] ?? []
            return LocationAnswer.decodeSuggestions(suggestionsArr)
        } catch {
            Log.warning("Location autocomplete failed: \(error.localizedDescription)")
            return []
        }
    }
}

/// A debounced autocomplete for a SwiftUI surface that holds its search as an object.
///
/// The `input_location` content block used to hold an `MKLocalSearchCompleter`, which debounced
/// internally; the proxy does not, so the 300 ms the form-step field has always used is explicit
/// here. Android's content block debounces by the same 300 ms
/// (`LocationFieldComposable.kt`), so a keystroke costs one request on both platforms.
final class LocationSuggestionSearch: ObservableObject {
    @Published var results: [LocationData] = []
    @Published var isSearching = false

    private var task: Task<Void, Never>?

    /// Debounces, then searches. An empty query clears without a request.
    func search(query: String, settings: LocationSearchSettings, client: APIClient? = AppDNA.geocodeClient) {
        task?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return
        }
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let found = await LocationAutocomplete.fetch(query: query, settings: settings, client: client)
            if Task.isCancelled { return }
            // `isSearching` drives a spinner, so it has to land on the main thread with the results
            // and not a tick later.
            DispatchQueue.main.async {
                self?.results = found
                self?.isSearching = false
            }
        }
    }

    /// Drops the pending request, the results and the spinner — what a query below the authored
    /// character threshold does.
    func clear() {
        task?.cancel()
        task = nil
        results = []
        isSearching = false
    }
}
