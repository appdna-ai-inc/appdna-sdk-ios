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
        let listing = LocationListingRequest(
            query: query, type: settings.type, biasCountry: settings.biasCountry, language: settings.language
        )
        return await fetchItems(listing: listing, client: client, session: session).map(\.data)
    }

    /// The same request, keeping each suggestion's own `id` / `provider` for the tap
    /// path. `listing` is exactly what is sent, so the holder can keep it with the list it produced.
    static func fetchItems(
        listing: LocationListingRequest,
        client: APIClient?,
        session: URLSession = .shared
    ) async -> [LocationSuggestionItem] {
        guard let client else { return [] }
        let body = listing.autocompleteBody

        guard let url = Endpoint.geocodeAutocomplete.url(environment: client.environment),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.apiKey, forHTTPHeaderField: "x-api-key")
        // The server answers null for a missing coordinate / zone only to an SDK that says it reads
        // null (iOS >= 1.0.82); without these headers it sends the legacy 0 / "UTC" shape. Since
        // They also decide whether this build is shown display-only suggestions it
        // resolves on a tap (`MAPBOX_RESOLVE_SDK`).
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")

        do {
            let (data, _) = try await session.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataObj = json?["data"] as? [String: Any]
            let suggestionsArr = dataObj?["suggestions"] as? [[String: Any]] ?? []
            return LocationAnswer.decodeSuggestionItems(suggestionsArr)
        } catch {
            Log.warning("Location autocomplete failed: \(error.localizedDescription)")
            return []
        }
    }
}

/// The autocomplete request that produced a suggestion list, AS SENT. It is
/// kept WITH the list (`LocationListedSuggestion`), and a tap reads it from there, never from the
/// field's current text: the text can have changed while the list was on screen (the 300 ms debounce
/// shows a stale list after an edit), and the resolve must repeat the request that listed what the
/// user tapped.
struct LocationListingRequest: Equatable {
    let query: String
    /// Each nil when the author chose none — see `LocationSearchSettings.type` (#964).
    let type: String?
    let biasCountry: String?
    let language: String?

    /// The autocomplete body. Each setting only when the author chose one: the proxy narrows results
    /// only when the key is PRESENT, so sending a substituted default would filter a search the
    /// author asked to leave open (#964).
    var autocompleteBody: [String: Any] {
        var body: [String: Any] = ["query": query, "limit": 5]
        if let t = type { body["type"] = t }
        if let c = biasCountry { body["bias_country"] = c }
        if let l = language { body["language"] = l }
        return body
    }
}

/// One suggestion of the list on screen, paired with the request that listed it — so a tap pairs a
/// suggestion with ITS listing request even when the list was replaced between render and tap.
struct LocationListedSuggestion {
    let suggestion: LocationSuggestionItem
    let listing: LocationListingRequest
    var data: LocationData { suggestion.data }
}

/// What a resolve came back with.
enum LocationResolveOutcome: Sendable {
    /// `{resolved: true, suggestion}` — the answer that may be stored, carrying its provenance id.
    case resolved(LocationData)
    /// `{resolved: false, reason}` — e.g. `permanent_not_enabled`: only the typed text is stored.
    case refused(reason: String)
    /// Anything else: an HTTP error (400 / 401 / 429 / 5xx, a key-required refusal), a network
    /// failure, or a reply that does not parse. Also only the typed text.
    case failed(reason: String)
}

/// `POST /api/v1/sdk/geocode/resolve` — the ONE resolve call in the iOS SDK, used by both surfaces
/// through `LocationSuggestionSearch`.
enum LocationResolve {

    /// Sends `body` (built by `LocationSuggestionSearch.resolveRequest(for:)`) and reads the reply.
    /// Never throws: every failure is `.failed`, and the field stores the typed text.
    static func send(
        body: [String: Any],
        client: APIClient?,
        session: URLSession = .shared
    ) async -> LocationResolveOutcome {
        guard let client else { return .failed(reason: "no_client") }
        guard let url = Endpoint.geocodeResolve.url(environment: client.environment),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failed(reason: "request_not_built")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.apiKey, forHTTPHeaderField: "x-api-key")
        // The same two headers as autocomplete: the server reads the build from them (D4), and
        // `check:geocode-sdk-version-headers` holds every hand-built geocode request to them.
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return outcome(status: status, data: data)
        } catch {
            Log.warning("Location resolve failed: \(error.localizedDescription)")
            return .failed(reason: "network")
        }
    }

    /// The route's reply → an outcome. A success must carry a non-empty display line AND a provenance
    /// id (`mapbox_id`, or Google's `place_id`): the route always sends one, and a "resolved" answer
    /// without it would be stored on the device as if it were permanent while ingest treats it as
    /// legacy — so it fails closed, to typed text.
    static func outcome(status: Int, data: Data) -> LocationResolveOutcome {
        guard (200..<300).contains(status) else { return .failed(reason: "http_\(status)") }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reply = json["data"] as? [String: Any],
              let resolved = reply["resolved"] as? Bool else {
            return .failed(reason: "unparseable")
        }
        guard resolved else {
            return .refused(reason: (reply["reason"] as? String) ?? "unknown")
        }
        guard let suggestion = reply["suggestion"],
              let location = LocationData.fromStoredAnswer(suggestion),
              !location.formatted_address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              location.mapbox_id != nil || location.place_id != nil else {
            return .failed(reason: "unparseable")
        }
        return .resolved(location)
    }
}

/// THE ONE state holder both iOS location surfaces bind to — the form-step `LocationFieldView` and the
/// `input_location` content block (`FormInputLocationPlaceholderBlock`) — so the shared fixtures and
/// the unit tests drive the code the views run.
///
/// It owns:
/// - the suggestion list, each suggestion with the listing request it came from;
/// - the field text: (a) after a resolve, (b) restored from a stored answer, (c) every change through
///   `textChanged`, the one entry point;
/// - the tap: cancel the pending search, close the dropdown, then resolve (d);
/// - whether the dropdown is open (e).
///
/// The views own focus, layout and styling, and persist what the holder writes through `attach`.
///
/// Its fetch, its resolve call and its debounce clock are injectable (`init(storedAnswer:fetch:…)`),
/// so a test can hold a debounced search PENDING while it taps — CI timing cannot fire it early — and
/// stub a resolve reply while reading the body that was sent. Every method is called on the main
/// thread; the live closures deliver their completions there.
final class LocationSuggestionSearch: ObservableObject {

    typealias Fetch = (_ listing: LocationListingRequest, _ done: @escaping ([LocationSuggestionItem]) -> Void) -> Void
    typealias Resolve = (_ body: [String: Any], _ done: @escaping (LocationResolveOutcome) -> Void) -> Void
    /// Runs `work` after `delayMs`; returns a cancel.
    typealias Schedule = (_ delayMs: Int, _ work: @escaping () -> Void) -> (() -> Void)

    /// The debounce both platforms use, so a keystroke costs one request (Android's composables wait
    /// the same 300 ms).
    static let debounceMs = 300

    @Published private(set) var results: [LocationListedSuggestion] = []
    /// The field text. Views bind their text field to it and forward EVERY change to `textChanged`.
    @Published var text: String = ""
    @Published private(set) var isSearching = false
    /// A tap's resolve is in flight: the views show progress, and nothing is stored for the field.
    @Published private(set) var isResolving = false
    @Published private(set) var isDropdownOpen = false

    /// The answer as the holder last wrote or was told it is (`storedAnswerChanged`). Only its
    /// presence is read, for the reactive restore.
    private(set) var storedAnswer: Any?

    private let fetch: Fetch
    private let resolve: Resolve
    private let schedule: Schedule
    private var store: ((Any?) -> Void)?

    /// The ONE-SHOT expectation armed by a programmatic text set (a resolve, a
    /// restore, a clear). The next `textChanged` consumes it whatever its value: a match is the
    /// echo SwiftUI's `.onChange` sends for our own set, and is skipped; a mismatch is the user, and is
    /// processed. A value check, not a flag reset on the next main-queue turn — that was the block's
    /// timing-dependent `isRestoringFromSaved`.
    private var pendingEcho: String?
    private var cancelPendingSearch: (() -> Void)?
    /// Bumped by every new search and every cancel, so a fetch that completes for a superseded
    /// search is dropped instead of reopening the dropdown.
    private var searchGeneration = 0
    /// Bumped by every tap, every user edit and `detach`, so a resolve reply for a superseded tap is
    /// dropped: "the field's current text decides".
    private var resolveGeneration = 0

    /// Production: the live autocomplete and resolve calls, on a main-queue debounce. `client` is read
    /// when each request is made, not when the field is built, so a field shown before the SDK
    /// finished configuring still searches once it has.
    convenience init(storedAnswer: Any? = nil, client: @escaping () -> APIClient?) {
        self.init(
            storedAnswer: storedAnswer,
            fetch: { listing, done in
                // Read on the calling (main) thread, as the views always read it.
                let apiClient = client()
                Task {
                    let items = await LocationAutocomplete.fetchItems(listing: listing, client: apiClient)
                    DispatchQueue.main.async { done(items) }
                }
            },
            resolve: { body, done in
                let apiClient = client()
                Task {
                    let outcome = await LocationResolve.send(body: body, client: apiClient)
                    DispatchQueue.main.async { done(outcome) }
                }
            },
            schedule: { delayMs, work in
                let item = DispatchWorkItem(block: work)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
                return { item.cancel() }
            }
        )
    }

    /// The test seam: every dependency injected. `storedAnswer` is the field's answer when it is
    /// built — restored into the text at once.
    init(storedAnswer: Any?, fetch: @escaping Fetch, resolve: @escaping Resolve, schedule: @escaping Schedule) {
        self.fetch = fetch
        self.resolve = resolve
        self.schedule = schedule
        self.storedAnswer = storedAnswer
        if let restored = LocationAnswer.fieldText(forStored: storedAnswer) {
            setText(restored)
        }
    }

    // MARK: - Binding to a view

    /// Where the holder persists the field's answer (the form step's `value`, the block's
    /// `inputValues[fieldId]`). `nil` = no answer.
    func attach(store: @escaping (Any?) -> Void) {
        self.store = store
    }

    /// The view went away (the step advanced, or the user navigated back): a resolve reply that
    /// arrives now is dropped, and a pending search never fires.
    func detach() {
        store = nil
        dropResolveInFlight()
        cancelSearch()
    }

    /// The view saw its stored answer change. The restore is REACTIVE: on an absent →
    /// present transition while the text is empty, the answer is restored into the text. That covers a
    /// parent that seeds the answers after the field was built (`FormStepView`'s `.onAppear`).
    func storedAnswerChanged(_ value: Any?) {
        let wasPresent = LocationAnswer.fieldText(forStored: storedAnswer) != nil
        storedAnswer = value
        guard !wasPresent, text.isEmpty, let restored = LocationAnswer.fieldText(forStored: value) else { return }
        setText(restored)
    }

    // MARK: - Text

    /// EVERY change to the field text comes through here, programmatic ones included
    /// (SwiftUI's `.onChange(of:)` fires for our own sets too). The one echo of the holder's own set
    /// is skipped; anything else is the user typing: it drops a resolve in flight, stores the typed
    /// text, and searches.
    func textChanged(_ newText: String, settings: LocationSearchSettings) {
        if let echo = pendingEcho {
            pendingEcho = nil
            if newText == echo { return }
        }
        if text != newText { text = newText }
        dropResolveInFlight()
        storeTyped(newText)
        search(query: newText, settings: settings)
    }

    /// Typing without selecting stores the typed text (an empty field stores nothing). Editing after a
    /// selection replaces it with the text.
    private func storeTyped(_ newText: String) {
        if newText.isEmpty {
            if storedAnswer != nil { write(nil) }
            return
        }
        if let current = storedAnswer as? String, current == newText { return }
        write(LocationAnswer.typed(newText))
    }

    /// A programmatic set: arms the one-shot echo expectation, only when the text actually changes
    /// (SwiftUI sends no event for an unchanged value, so an armed expectation would swallow the
    /// user's next real edit that happened to match).
    private func setText(_ newText: String) {
        guard newText != text else { return }
        pendingEcho = newText
        text = newText
    }

    // MARK: - Search

    /// Debounces, then searches. A query below the authored Min characters (or blank) clears the list
    /// and closes the dropdown without a request. The listing request is built HERE, from the
    /// settings the surface resolved, and travels with the list it produces.
    private func search(query: String, settings: LocationSearchSettings) {
        cancelSearch()
        guard query.count >= settings.minChars,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isDropdownOpen = false
            return
        }
        let listing = LocationListingRequest(
            query: query, type: settings.type, biasCountry: settings.biasCountry, language: settings.language
        )
        let generation = searchGeneration
        isSearching = true
        cancelPendingSearch = schedule(Self.debounceMs) { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            self.cancelPendingSearch = nil
            self.fetch(listing) { [weak self] items in
                guard let self, generation == self.searchGeneration else { return }
                self.isSearching = false
                self.results = items.map { LocationListedSuggestion(suggestion: $0, listing: listing) }
                self.isDropdownOpen = !self.results.isEmpty
            }
        }
    }

    /// Cancels the pending debounced search and drops any fetch in flight.
    private func cancelSearch() {
        searchGeneration += 1
        cancelPendingSearch?()
        cancelPendingSearch = nil
        isSearching = false
    }

    /// The user left the field: close the dropdown, and let no pending search reopen it.
    func editingEnded() {
        cancelSearch()
        isDropdownOpen = false
    }

    /// The clear button: no answer, no text, no list.
    func clear() {
        cancelSearch()
        dropResolveInFlight()
        results = []
        isDropdownOpen = false
        write(nil)
        setText("")
    }

    // MARK: - Tap → resolve

    /// A tap ENDS the search: the pending debounced search is cancelled and the dropdown
    /// closes, and nothing reopens it until the user edits again. Then the tapped suggestion is
    /// resolved; nothing is stored while that is in flight (a required field keeps Continue gated).
    ///
    /// - Success → `LocationAnswer.selection(resolved)`, carrying `mapbox_id`; the field shows the
    ///   resolved `formatted_address`.
    /// - Any non-success, or a suggestion with no `id` (a server that predates resolving, or a rollback: it
    ///   cannot be resolved, and a full temporary result may not be stored) → the typed text.
    func select(_ listed: LocationListedSuggestion) {
        cancelSearch()
        isDropdownOpen = false
        results = []
        dropResolveInFlight()
        // The text the user typed to find this place, read before anything changes it.
        let typed = text
        let typedAnswer: Any? = typed.isEmpty ? nil : LocationAnswer.typed(typed)

        guard let body = resolveRequest(for: listed) else {
            write(typedAnswer)
            Log.debug("Location suggestion has no id; stored the typed text")
            return
        }
        write(nil)
        isResolving = true
        let generation = resolveGeneration
        resolve(body) { [weak self] outcome in
            guard let self, generation == self.resolveGeneration else { return }
            self.isResolving = false
            switch outcome {
            case .resolved(let location):
                let answer = LocationAnswer.selection(from: location, rawQuery: typed)
                self.write(answer)
                self.setText(LocationAnswer.fieldText(forStored: answer) ?? listed.data.formatted_address)
                // Never log the place itself.
                Log.debug("Location suggestion resolved")
            case .refused(let reason), .failed(let reason):
                self.write(typedAnswer)
                Log.debug("Location resolve not used (\(reason)); stored the typed text")
            }
        }
    }

    /// The tap at `index` of the list on screen.
    func select(at index: Int) {
        guard results.indices.contains(index) else { return }
        select(results[index])
    }

    /// The resolve body for a tapped suggestion: its `id`, its display line as
    /// `text`, and the autocomplete request that LISTED it (`query`, `type`, `bias_country`,
    /// `language` as sent) — never the field's current text, which may have changed while the list was
    /// on screen. A Google suggestion sends `{id, provider, language}` only, so Places
    /// prediction text never returns to the server. nil when the suggestion has no `id`.
    func resolveRequest(for listed: LocationListedSuggestion) -> [String: Any]? {
        guard let id = listed.suggestion.id else { return nil }
        let provider = listed.suggestion.provider ?? "mapbox"
        var body: [String: Any] = ["id": id, "provider": provider]
        if provider == "google" {
            if let l = listed.listing.language { body["language"] = l }
            return body
        }
        body["text"] = listed.data.formatted_address
        body["query"] = listed.listing.query
        if let t = listed.listing.type { body["type"] = t }
        if let c = listed.listing.biasCountry { body["bias_country"] = c }
        if let l = listed.listing.language { body["language"] = l }
        return body
    }

    private func dropResolveInFlight() {
        resolveGeneration += 1
        isResolving = false
    }

    private func write(_ value: Any?) {
        storedAnswer = value
        store?(value)
    }
}
