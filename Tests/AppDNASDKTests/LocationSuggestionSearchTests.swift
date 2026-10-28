// LocationSuggestionSearchTests.swift
//
// The ONE location state holder both iOS surfaces bind to
// (`LocationSuggestionSearch`), driven through `LocationSearchRig`: the real holder, the real settings
// resolver, the real suggestion decoder, the real resolve-body builder and the real reply parser; only
// the socket and the clock are replaced. A debounced search stays PENDING until the test advances the
// clock, so "the tap cancelled it" cannot pass because CI was slow.
//
// RED CONTROLS (each run once against a mutated holder):
//   - the `textChanged` value check removed (every echo processed)  → the echo tests fail;
//   - the tap's cancel of the pending search removed                → the tap-ends-the-search test fails;
//   - an echo expectation that never resets / only a match consumes → the retype test fails;
//   - the field's text (or the display line) sent as `query`         → the body test fails.
//
// All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class LocationSuggestionSearchTests: XCTestCase {

    // MARK: - Synthetic data

    /// An interpolated address's id: base64 of `urn:mbxadr-itp:` + the request that produced it.
    static let listedAddressId = "dXJuOm1ieGFkci1pdHA6" + Data("synthetic-listing".utf8).base64EncodedString()
    static let resolvedAddressId = "dXJuOm1ieGFkci1pdHA6" + Data("synthetic-resolve".utf8).base64EncodedString()
    static let portoId = Data("urn:mbxplc:synthetic-porto".utf8).base64EncodedString()
    static let line = "12 Example Street, 4000-001 Porto, Portugal"

    static let addressSuggestion: [String: Any] = [
        "id": listedAddressId, "provider": "mapbox", "formatted_address": line,
        "name": "12 Example Street", "place_formatted": "4000-001 Porto, Portugal",
    ]
    static let avenueSuggestion: [String: Any] = [
        "id": Data("urn:mbxadr:synthetic-avenue".utf8).base64EncodedString(), "provider": "mapbox",
        "formatted_address": "12 Example Avenue, 4100-002 Porto, Portugal",
        "name": "12 Example Avenue", "place_formatted": "4100-002 Porto, Portugal",
    ]
    static let portoSuggestion: [String: Any] = [
        "id": portoId, "provider": "mapbox", "formatted_address": "Porto, Portugal",
        "name": "Porto", "place_formatted": "Portugal",
    ]

    static func resolvedReply(_ line: String = line, mapboxId: String? = resolvedAddressId) -> [String: Any] {
        var suggestion: [String: Any] = [
            "formatted_address": line, "city": "Porto", "state": "Porto", "state_code": "13",
            "country": "Portugal", "country_code": "PT", "latitude": 41.15, "longitude": -8.61,
            "timezone": "Europe/Lisbon", "timezone_offset": 0, "postal_code": "4000-001", "provider": "mapbox",
        ]
        if let mapboxId { suggestion["mapbox_id"] = mapboxId }
        return ["data": ["resolved": true, "suggestion": suggestion]]
    }

    static func settings(_ config: [String: Any]) -> LocationSearchSettings {
        LocationSearchSettings.from(blockConfig: config.mapValues { AnyCodable($0) }, defaultMinChars: 3)
    }

    static let addressSettings = settings(["location_type": "address", "location_bias_country": "pt", "location_language": "pt"])

    private func addressRig(storedAnswer: Any? = nil) -> LocationSearchRig {
        LocationSearchRig(
            settings: Self.addressSettings,
            storedAnswer: storedAnswer,
            autocomplete: [
                "12 Example": [Self.addressSuggestion, Self.avenueSuggestion],
                "12 Example Av": [Self.avenueSuggestion],
                "Porto": [Self.portoSuggestion],
            ]
        )
    }

    /// List "12 Example", edit to "12 Example Av" (its search left PENDING), tap the first row.
    private func staleListTap() -> LocationSearchRig {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        XCTAssertTrue(rig.holder.isDropdownOpen, "precondition: the list is on screen")
        XCTAssertEqual(rig.holder.results.count, 2)
        rig.type("12 Example Av")
        rig.tap(0)
        return rig
    }

    // MARK: - The resolve body

    /// The stale-list case: the body repeats the LISTING request, not the field's text at the tap, and
    /// carries the tapped suggestion's own id, provider and display line.
    /// Red control: sending the field's current text, or the display line, as `query` fails it.
    func testTheResolveBodyCarriesTheListingRequestNotTheFieldText() throws {
        let rig = staleListTap()
        XCTAssertEqual(rig.resolveBodies.count, 1)
        let body = try XCTUnwrap(rig.resolveBodies.first)
        XCTAssertEqual(body["query"] as? String, "12 Example", "the listing's query")
        XCTAssertNotEqual(body["query"] as? String, "12 Example Av", "never the field's text at the tap")
        XCTAssertNotEqual(body["query"] as? String, Self.line, "never the display line")
        XCTAssertEqual(body["text"] as? String, Self.line, "text is the tapped suggestion's display line")
        XCTAssertEqual(body["id"] as? String, Self.listedAddressId)
        XCTAssertEqual(body["provider"] as? String, "mapbox")
        XCTAssertEqual(body["type"] as? String, "address")
        XCTAssertEqual(body["bias_country"] as? String, "pt")
        XCTAssertEqual(body["language"] as? String, "pt")
        XCTAssertEqual(Set(body.keys), ["id", "provider", "text", "query", "type", "bias_country", "language"])
    }

    /// An unauthored setting is absent from the resolve body, as it is from the listing request (#964).
    func testAnUnauthoredSettingIsAbsentFromTheBody() throws {
        let rig = LocationSearchRig(settings: Self.settings([:]), autocomplete: ["Porto": [Self.portoSuggestion]])
        rig.type("Porto")
        rig.advance(ms: 300)
        rig.tap(0)
        let body = try XCTUnwrap(rig.resolveBodies.first)
        XCTAssertEqual(Set(body.keys), ["id", "provider", "text", "query"])
    }

    /// A Google body is exactly {id, provider, language}: Places prediction text never returns to
    /// the server. Red control: a `text` or `query` key fails it.
    func testAGoogleSuggestionSendsOnlyIdProviderAndLanguage() throws {
        let google: [String: Any] = ["id": "ChIJ-synthetic", "provider": "google", "formatted_address": "Springfield, IL, USA"]
        let rig = LocationSearchRig(settings: Self.settings(["location_language": "en"]), autocomplete: ["Springf": [google]])
        rig.type("Springf")
        rig.advance(ms: 300)
        rig.tap(0)
        let body = try XCTUnwrap(rig.resolveBodies.first)
        XCTAssertEqual(Set(body.keys), ["id", "provider", "language"])
        XCTAssertEqual(body["id"] as? String, "ChIJ-synthetic")
        XCTAssertEqual(body["provider"] as? String, "google")
    }

    // MARK: - A tap ends the search

    /// After the tap, the edit's pending search never fires and the dropdown stays closed: ONE
    /// autocomplete call in all. Red control: the tap's cancel removed → 2 calls and the dropdown open.
    func testATapCancelsThePendingSearchAndClosesTheDropdownForGood() {
        let rig = staleListTap()
        XCTAssertFalse(rig.holder.isDropdownOpen, "the tap closes the dropdown")
        rig.reply(status: 200, body: Self.resolvedReply())
        rig.echo()
        rig.advance(ms: 1_000)
        XCTAssertEqual(rig.autocompleteQueries, ["12 Example"], "the edit's pending search was cancelled by the tap")
        XCTAssertFalse(rig.holder.isDropdownOpen, "nothing reopens the dropdown until the user edits again")
        XCTAssertTrue(rig.holder.results.isEmpty)
    }

    /// A fetch already running when the search is cancelled (the user left the field; a tap cancels
    /// the same way) must not reopen the dropdown when it lands.
    func testAFetchInFlightWhenTheSearchIsCancelledIsDropped() {
        var heldFetch: (([LocationSuggestionItem]) -> Void)?
        var fired: [() -> Void] = []
        let holder = LocationSuggestionSearch(
            storedAnswer: nil,
            fetch: { _, done in heldFetch = done },
            resolve: { _, _ in },
            schedule: { _, work in fired.append(work); return {} }
        )
        holder.textChanged("Porto", settings: Self.addressSettings)
        fired.forEach { $0() }
        XCTAssertNotNil(heldFetch, "precondition: the fetch is in flight")
        holder.editingEnded()
        heldFetch?(LocationAnswer.decodeSuggestionItems([Self.portoSuggestion]))
        XCTAssertFalse(holder.isDropdownOpen)
        XCTAssertTrue(holder.results.isEmpty)
    }

    // MARK: - The echo — the form-step `storeTyped` red control

    /// After a resolve the holder sets the field to the resolved line, and SwiftUI's `.onChange` sends
    /// that set straight back. It must not be stored as typed text (which would overwrite the resolved
    /// answer — the old form-step `storeTyped` bug) nor searched.
    /// Red control: the `textChanged` value check removed → the answer becomes a String and a second
    /// search runs.
    func testTheEchoOfTheResolvedLineIsNotStoredAsTypedNorSearched() throws {
        let rig = staleListTap()
        rig.reply(status: 200, body: Self.resolvedReply())
        let writesAfterResolve = rig.storeWrites
        rig.echo()
        rig.advance(ms: 1_000)
        let stored = try XCTUnwrap(rig.stored as? [String: Any], "the resolved selection survives the echo")
        XCTAssertEqual(stored["mapbox_id"] as? String, Self.resolvedAddressId)
        XCTAssertEqual(rig.storeWrites, writesAfterResolve, "the echo wrote nothing")
        XCTAssertEqual(rig.autocompleteQueries.count, 1, "the echo started no search")
    }

    /// A restore is a programmatic set too: its echo starts no search and writes nothing.
    func testTheEchoOfARestoreStartsNoSearch() {
        let rig = addressRig()
        rig.storeFromOutside("Springfield")
        XCTAssertEqual(rig.holder.text, "Springfield")
        let writes = rig.storeWrites
        rig.echo()
        rig.advance(ms: 1_000)
        XCTAssertEqual(rig.autocompleteQueries, [])
        XCTAssertEqual(rig.storeWrites, writes)
    }

    /// The Compose shape (no echo ever sent): resolve → edit away → type the line back. The retype is
    /// the user's, so it is stored as typed and ONE search runs for it.
    /// Red controls: an expectation that never resets, and one that only a match consumes, each
    /// swallow the retype.
    func testRetypingTheResolvedLineWithoutAnEchoIsStoredAndSearched() {
        let rig = addressRig()
        rig.type("Porto")
        rig.advance(ms: 300)
        rig.tap(0)
        rig.reply(status: 200, body: Self.resolvedReply("Porto, Portugal", mapboxId: Self.portoId))
        XCTAssertEqual(rig.holder.text, "Porto, Portugal")
        rig.type("Porto, Portuga")
        rig.type("Porto, Portugal")
        rig.advance(ms: 300)
        XCTAssertEqual(rig.stored as? String, "Porto, Portugal", "the retyped text is the answer")
        XCTAssertEqual(rig.autocompleteQueries, ["Porto", "Porto, Portugal"], "one search ran for the retype")
    }

    /// The expectation is ONE-SHOT: consumed by the next change whatever its value. With an echo
    /// pending, a real edit that arrives first is processed, and does not leave the expectation armed.
    func testAMismatchConsumesTheExpectation() {
        let rig = addressRig()
        rig.storeFromOutside("Springfield") // restore → expectation armed, no echo delivered
        rig.type("Springfiel")              // a real edit: mismatch, processed, expectation cleared
        rig.type("Springfield")             // typed back: processed, not swallowed
        XCTAssertEqual(rig.stored as? String, "Springfield")
        rig.advance(ms: 300)
        XCTAssertEqual(rig.autocompleteQueries, ["Springfield"])
    }

    // MARK: - The resolve outcome

    /// While the resolve is in flight nothing is stored (a required field keeps Continue gated).
    func testNothingIsStoredWhileTheResolveIsInFlight() {
        let rig = staleListTap()
        XCTAssertNil(rig.stored, "the typed text stored while typing is withdrawn during the resolve")
        XCTAssertTrue(rig.holder.isResolving)
        XCTAssertEqual(rig.holder.text, "12 Example Av", "the field keeps the typed text meanwhile")
    }

    func testAResolvedReplyIsStoredWithItsMapboxIdAndTheFieldShowsItsLine() throws {
        let rig = staleListTap()
        rig.reply(status: 200, body: Self.resolvedReply())
        let stored = try XCTUnwrap(rig.stored as? [String: Any])
        XCTAssertEqual(stored["mapbox_id"] as? String, Self.resolvedAddressId)
        XCTAssertEqual(stored["formatted_address"] as? String, Self.line)
        XCTAssertEqual(stored["raw_query"] as? String, "12 Example Av", "the text at the tap, not the listing query")
        XCTAssertEqual(stored["timezone"] as? String, "Europe/Lisbon")
        XCTAssertNil(stored["provider"], "the reply's provider is not part of the stored answer")
        XCTAssertNil(stored["id"])
        XCTAssertEqual(rig.holder.text, Self.line, "the field shows the resolved formatted_address")
        XCTAssertFalse(rig.holder.isResolving)
    }

    /// Every non-success stores the typed text and keeps showing it.
    func testEveryNonSuccessStoresTheTypedText() {
        let cases: [(String, (LocationSearchRig) -> Void)] = [
            ("refused permanent_not_enabled", { $0.reply(status: 200, body: ["data": ["resolved": false, "reason": "permanent_not_enabled"]]) }),
            ("refused token_refused", { $0.reply(status: 200, body: ["data": ["resolved": false, "reason": "token_refused"]]) }),
            ("400", { $0.reply(status: 400, body: ["error": ["code": "VALIDATION_ERROR"]]) }),
            ("401", { $0.reply(status: 401, body: ["error": ["code": "UNAUTHORIZED"]]) }),
            ("429", { $0.reply(status: 429, body: ["error": ["code": "RATE_LIMITED"]]) }),
            ("500", { $0.reply(status: 500, body: ["error": ["code": "INTERNAL"]]) }),
            ("network", { $0.replyNetworkError() }),
            ("unparseable 200", { $0.reply(status: 200, body: ["unexpected": true]) }),
            // Fails closed: a "resolved" answer without its provenance would be stored as permanent on
            // the device while ingest treats it as legacy.
            ("resolved without mapbox_id", { $0.reply(status: 200, body: Self.resolvedReply("Porto, Portugal", mapboxId: nil)) }),
            // A blank id is no provenance either (Android reads ids as non-blank only).
            ("resolved with a blank mapbox_id", { $0.reply(status: 200, body: Self.resolvedReply("Porto, Portugal", mapboxId: "  ")) }),
            // Fails closed too: a "resolved" answer with no display line would leave the field blank.
            ("resolved without a line", { $0.reply(status: 200, body: Self.resolvedReply("", mapboxId: Self.portoId)) }),
        ]
        for (name, answer) in cases {
            let rig = addressRig()
            rig.type("Porto")
            rig.advance(ms: 300)
            rig.tap(0)
            XCTAssertNil(rig.stored, "[\(name)] nothing stored in flight")
            answer(rig)
            XCTAssertEqual(rig.stored as? String, "Porto", "[\(name)] the typed text is the answer")
            XCTAssertEqual(rig.holder.text, "Porto", "[\(name)] the field keeps the typed text")
            XCTAssertFalse(rig.holder.isResolving, "[\(name)]")
            XCTAssertFalse(rig.holder.isDropdownOpen, "[\(name)]")
        }
    }

    /// A suggestion with no `id` (a server that treats this build as old, or a rollback) cannot be
    /// resolved, and its full temporary result may not be stored: no request, the typed text stored.
    func testASuggestionWithoutAnIdIsNotResolvedAndStoresTheTypedText() {
        let full: [String: Any] = [
            "formatted_address": "Porto, Portugal", "city": "Porto", "country": "Portugal",
            "latitude": 41.15, "longitude": -8.61, "provider": "mapbox",
        ]
        let rig = LocationSearchRig(settings: Self.addressSettings, autocomplete: ["Oporto": [full]])
        rig.type("Oporto")
        rig.advance(ms: 300)
        rig.tap(0)
        XCTAssertEqual(rig.resolveBodies.count, 0)
        XCTAssertEqual(rig.stored as? String, "Oporto")
        XCTAssertEqual(rig.holder.text, "Oporto")
        XCTAssertFalse(rig.holder.isResolving)
    }

    /// "A resolve reply that arrives after the user has edited the field's text is dropped; the
    /// field's current text decides."
    func testAReplyAfterAnEditIsDropped() {
        let rig = addressRig()
        rig.type("Porto")
        rig.advance(ms: 300)
        rig.tap(0)
        rig.type("Portoo")
        rig.reply(status: 200, body: Self.resolvedReply("Porto, Portugal", mapboxId: Self.portoId))
        XCTAssertEqual(rig.stored as? String, "Portoo")
        XCTAssertEqual(rig.holder.text, "Portoo")
        XCTAssertFalse(rig.holder.isResolving)
    }

    // MARK: - The step advances while a resolve is in flight

    /// The view goes away (`detach`) with a resolve in flight: the field stores the text the user had
    /// typed at the tap — the resolve's `raw_query` — as for any failed resolve, and the late reply
    /// changes nothing. Red control: `detach` without the settle → nothing stored (the typed text is
    /// lost) and this fails on the first assertion.
    func testDetachWhileResolvingStoresTheTypedTextAndDropsTheLateReply() {
        let rig = staleListTap()
        XCTAssertTrue(rig.holder.isResolving, "precondition: the resolve is held in flight")
        XCTAssertNil(rig.stored, "precondition: nothing stored while it is")
        rig.holder.detach()
        XCTAssertEqual(rig.stored as? String, "12 Example Av", "the typed text at the tap is stored")
        XCTAssertFalse(rig.holder.isResolving)
        let writes = rig.storeWrites
        rig.reply(status: 200, body: Self.resolvedReply())
        XCTAssertEqual(rig.storeWrites, writes, "the late reply writes nothing")
        XCTAssertEqual(rig.stored as? String, "12 Example Av")
        XCTAssertEqual(rig.holder.text, "12 Example Av", "the late reply does not set the field text")
    }

    /// The step's settlement (what Continue runs before it submits) does the same, and reports the
    /// answer under the field's id so the step can add it to a payload it already built. A second
    /// settle, and a settle with nothing in flight, write nothing.
    func testTheStepSettlementStoresTheTypedTextBeforeTheStepSubmits() {
        let rig = staleListTap()
        let settlement = LocationAdvanceSettlement()
        settlement.register(fieldId: "where", holder: rig.holder)
        let payload = settlement.settleInto(["action": "next"])
        XCTAssertEqual(payload?["where"] as? String, "12 Example Av", "the submitted payload carries the typed text")
        XCTAssertEqual(payload?["action"] as? String, "next")
        XCTAssertEqual(rig.stored as? String, "12 Example Av", "and the field's answer holds it")
        let writes = rig.storeWrites
        XCTAssertTrue(settlement.settle().isEmpty, "nothing is in flight any more")
        rig.reply(status: 200, body: Self.resolvedReply())
        rig.holder.detach()
        XCTAssertEqual(rig.storeWrites, writes, "the late reply and the later detach write nothing")
        XCTAssertEqual(rig.stored as? String, "12 Example Av")
    }

    /// With no resolve in flight, `detach` and the settlement write nothing: a resolved answer stays
    /// the resolved answer.
    func testDetachWithNoResolveInFlightWritesNothing() throws {
        let rig = staleListTap()
        rig.reply(status: 200, body: Self.resolvedReply())
        let resolved = try XCTUnwrap(rig.stored as? [String: Any])
        let writes = rig.storeWrites
        let settlement = LocationAdvanceSettlement()
        settlement.register(fieldId: "where", holder: rig.holder)
        XCTAssertTrue(settlement.settle().isEmpty, "the settlement settles nothing")
        rig.holder.detach()
        XCTAssertEqual(rig.storeWrites, writes, "detach writes nothing")
        XCTAssertEqual((rig.stored as? [String: Any])?["mapbox_id"] as? String, resolved["mapbox_id"] as? String,
                       "the resolved answer is kept")
    }

    /// A second tap supersedes the first: the first reply is dropped.
    func testASecondTapSupersedesTheFirstReply() throws {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        rig.tap(0)
        rig.type("12 Example Av")
        rig.advance(ms: 300)
        rig.tap(0)
        XCTAssertEqual(rig.resolvesInFlight, 2)
        rig.reply(status: 200, body: Self.resolvedReply())          // the first tap's: dropped
        XCTAssertNil(rig.stored)
        rig.reply(status: 200, body: Self.resolvedReply("12 Example Avenue, 4100-002 Porto, Portugal",
                                                        mapboxId: "synthetic-avenue-resolved"))
        let stored = try XCTUnwrap(rig.stored as? [String: Any])
        XCTAssertEqual(stored["mapbox_id"] as? String, "synthetic-avenue-resolved")
    }

    // MARK: - The field text

    func testTheFieldTextForAStoredAnswer() {
        let address: [String: Any] = ["formatted_address": Self.line, "address": Self.line, "city": "Porto", "mapbox_id": "m"]
        let region: [String: Any] = ["formatted_address": "California, United States", "city": "California",
                                     "state": "California", "state_code": "CA", "country": "United States", "mapbox_id": "m"]
        let country: [String: Any] = ["formatted_address": "Portugal", "city": "Portugal", "country": "Portugal", "mapbox_id": "m"]
        let legacy: [String: Any] = ["address": "Lisbon, Portugal", "latitude": 38.72, "longitude": -9.14]
        let expectations: [(Any?, String)] = [
            (address, Self.line),
            (region, "California, United States"),
            (country, "Portugal"),
            ("Springfield", "Springfield"),
            (legacy, "Lisbon, Portugal"),
            ("", ""),
            (nil, ""),
            (NSNumber(value: 4), ""),
        ]
        for (answer, text) in expectations {
            let rig = LocationSearchRig(settings: Self.addressSettings, storedAnswer: answer)
            XCTAssertEqual(rig.holder.text, text, "stored \(String(describing: answer))")
        }
    }

    /// The restore is REACTIVE: an answer seeded after construction (FormStepView fills `values` in
    /// its own `.onAppear`) is restored while the text is empty.
    func testARestoreIsReactiveWhenTheAnswerIsSeededLater() {
        let rig = addressRig()
        XCTAssertEqual(rig.holder.text, "")
        rig.storeFromOutside(["formatted_address": "California, United States", "city": "California", "mapbox_id": "m"])
        XCTAssertEqual(rig.holder.text, "California, United States")
        XCTAssertEqual(rig.storeWrites, 0, "a restore writes nothing")
    }

    /// …but never over text the user typed, and only on an absent → present transition.
    func testALaterAnswerDoesNotOverwriteTypedText() {
        let rig = addressRig()
        rig.type("Spr")
        rig.storeFromOutside(["formatted_address": "California, United States", "mapbox_id": "m"])
        XCTAssertEqual(rig.holder.text, "Spr")
    }

    /// The one state where the text guard decides: a tap's resolve is in flight, so nothing is stored while the
    /// field still shows what the user typed. A parent seeding an answer then must not replace the typed text.
    /// Red control: drop `text.isEmpty` from the restore guard and this fails.
    func testAnAnswerSeededWhileAResolveIsInFlightDoesNotReplaceTheTypedText() {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        rig.tap(0)
        XCTAssertTrue(rig.holder.isResolving)
        XCTAssertNil(rig.stored, "nothing is stored while the resolve is in flight")
        rig.storeFromOutside(["formatted_address": "California, United States", "mapbox_id": "m"])
        XCTAssertEqual(rig.holder.text, "12 Example", "the typed text was replaced by a seeded answer")
    }

    // MARK: - The search

    func testBelowMinCharsNoSearchAndTheDropdownCloses() {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        XCTAssertTrue(rig.holder.isDropdownOpen)
        rig.type("12")
        rig.advance(ms: 300)
        XCTAssertFalse(rig.holder.isDropdownOpen)
        XCTAssertTrue(rig.holder.results.isEmpty)
        XCTAssertEqual(rig.autocompleteQueries, ["12 Example"])
        XCTAssertEqual(rig.stored as? String, "12", "typed text is still stored below the threshold")
    }

    func testTheDebounceSendsOneRequestPerPause() {
        let rig = addressRig()
        rig.type("12 E")
        rig.advance(ms: 100)
        rig.type("12 Ex")
        rig.advance(ms: 299)
        XCTAssertEqual(rig.autocompleteQueries, [], "still inside the debounce")
        rig.advance(ms: 1)
        XCTAssertEqual(rig.autocompleteQueries, ["12 Ex"])
    }

    /// Each row keeps the request that listed it, even after the list is replaced.
    func testEachListCarriesItsOwnListingRequest() throws {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        XCTAssertEqual(rig.holder.results.first?.listing.query, "12 Example")
        rig.type("12 Example Av")
        rig.advance(ms: 300)
        XCTAssertEqual(rig.holder.results.count, 1)
        XCTAssertEqual(rig.holder.results.first?.listing.query, "12 Example Av")
        rig.tap(0)
        XCTAssertEqual(try XCTUnwrap(rig.resolveBodies.first)["query"] as? String, "12 Example Av")
    }

    func testClearEmptiesTheTextTheAnswerAndTheList() {
        let rig = addressRig()
        rig.type("12 Example")
        rig.advance(ms: 300)
        rig.holder.clear()
        rig.echo()
        rig.advance(ms: 1_000)
        XCTAssertEqual(rig.holder.text, "")
        XCTAssertNil(rig.stored)
        XCTAssertFalse(rig.holder.isDropdownOpen)
        XCTAssertEqual(rig.autocompleteQueries, ["12 Example"], "clearing searched nothing")
    }

    // MARK: - The carriers

    /// A suggestion keeps its own id and provider on the internal wrapper, and NEVER fills the public
    /// provenance fields, whatever keys it carries.
    func testTheSuggestionDecoderKeepsIdAndProviderButNeverFillsProvenance() throws {
        var odd = Self.portoSuggestion
        odd["mapbox_id"] = "should-not-land"
        odd["place_id"] = "should-not-land"
        let item = try XCTUnwrap(LocationAnswer.decodeSuggestionItems([odd]).first)
        XCTAssertEqual(item.id, Self.portoId)
        XCTAssertEqual(item.provider, "mapbox")
        XCTAssertEqual(item.data.formatted_address, "Porto, Portugal")
        XCTAssertNil(item.data.mapbox_id)
        XCTAssertNil(item.data.place_id)
        XCTAssertNil(item.data.latitude, "a display-only suggestion carries no coordinates")
        // A blank id is no id.
        var blank = Self.portoSuggestion
        blank["id"] = "  "
        XCTAssertNil(LocationAnswer.decodeSuggestionItems([blank]).first?.id)
    }

    /// The stored answer carries the provenance a resolve reply had, and `getLocationData`'s reader
    /// returns it.
    func testTheStoredAnswerAndItsReaderKeepTheProvenanceIds() throws {
        let mapbox = LocationAnswer.selection(
            from: LocationData(formatted_address: "Porto, Portugal", mapbox_id: "m-1"), rawQuery: "Por"
        )
        XCTAssertEqual(mapbox["mapbox_id"] as? String, "m-1")
        XCTAssertNil(mapbox["place_id"])
        XCTAssertEqual(LocationData.fromStoredAnswer(mapbox)?.mapbox_id, "m-1")

        let google = LocationAnswer.selection(
            from: LocationData(formatted_address: "Springfield, IL, USA", place_id: "ChIJ-synthetic"), rawQuery: "Spr"
        )
        XCTAssertEqual(google["place_id"] as? String, "ChIJ-synthetic")
        XCTAssertEqual(LocationData.fromStoredAnswer(google)?.place_id, "ChIJ-synthetic")

        // A legacy answer has neither.
        let legacy = LocationData.fromStoredAnswer(["formatted_address": "Lisbon, Portugal"])
        XCTAssertNil(legacy?.mapbox_id)
        XCTAssertNil(legacy?.place_id)
    }
}

// MARK: - The resolve request on the wire

/// Captures every request and answers each one with `ResolveStubProxy.status` / `.reply`.
private final class ResolveStubProxy: URLProtocol {
    static var bodies: [[String: Any]] = []
    static var headers: [[String: String]] = []
    static var methods: [String] = []
    static var urls: [String] = []
    static var status = 200
    static var reply = Data()

    static func reset() { bodies = []; headers = []; methods = []; urls = []; status = 200; reply = Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "")
        Self.urls.append(request.url?.absoluteString ?? "")
        Self.headers.append(request.allHTTPHeaderFields ?? [:])
        let raw: Data? = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            return data
        }
        if let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            Self.bodies.append(obj)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LocationResolveTransportTests: XCTestCase {

    private var session: URLSession!
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        ResolveStubProxy.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResolveStubProxy.self]
        session = URLSession(configuration: config)
        client = APIClient(apiKey: "test-key", environment: .production)
    }

    override func tearDown() {
        session = nil
        client = nil
        ResolveStubProxy.reset()
        super.tearDown()
    }

    private func send(_ body: [String: Any]) async -> LocationResolveOutcome {
        await LocationResolve.send(body: body, client: client, session: session)
    }

    /// NEGATIVE CONTROL for everything below: the stub saw the request and read its body.
    func testTheResolveIsPostedToTheResolveRouteWithBothSdkHeaders() async throws {
        ResolveStubProxy.reply = try JSONSerialization.data(withJSONObject: LocationSuggestionSearchTests.resolvedReply())
        let body: [String: Any] = ["id": "x", "provider": "mapbox", "text": "Porto, Portugal", "query": "Porto"]
        _ = await send(body)
        XCTAssertEqual(ResolveStubProxy.methods, ["POST"])
        XCTAssertEqual(ResolveStubProxy.urls.first, "https://api.appdna.ai/api/v1/sdk/geocode/resolve")
        let sent = try XCTUnwrap(ResolveStubProxy.bodies.first, "the stub read no body")
        XCTAssertEqual(sent["query"] as? String, "Porto")
        XCTAssertEqual(Set(sent.keys), Set(body.keys), "the body is sent as built")
        let headers = try XCTUnwrap(ResolveStubProxy.headers.first)
        XCTAssertEqual(headers["x-api-key"], "test-key")
        XCTAssertEqual(headers["x-sdk-platform"], "ios")
        XCTAssertEqual(headers["x-sdk-version"], AppDNA.sdkVersion)
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func testAResolvedReplyParses() async throws {
        ResolveStubProxy.reply = try JSONSerialization.data(withJSONObject: LocationSuggestionSearchTests.resolvedReply())
        guard case .resolved(let location) = await send(["id": "x", "provider": "mapbox"]) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(location.mapbox_id, LocationSuggestionSearchTests.resolvedAddressId)
        XCTAssertEqual(location.formatted_address, LocationSuggestionSearchTests.line)
        XCTAssertNil(location.raw_query, "the reply carries no raw_query; the SDK sets it from the tap")
    }

    func testARefusalIsRefused() async throws {
        ResolveStubProxy.reply = try JSONSerialization.data(withJSONObject: ["data": ["resolved": false, "reason": "permanent_not_enabled"]])
        guard case .refused(let reason) = await send(["id": "x", "provider": "mapbox"]) else {
            return XCTFail("expected .refused")
        }
        XCTAssertEqual(reason, "permanent_not_enabled")
    }

    func testAnHttpErrorFails() async throws {
        ResolveStubProxy.status = 429
        ResolveStubProxy.reply = try JSONSerialization.data(withJSONObject: ["error": ["code": "RATE_LIMITED"]])
        guard case .failed(let reason) = await send(["id": "x", "provider": "mapbox"]) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(reason, "http_429")
    }

    func testWithoutAClientNoRequestIsMade() async {
        guard case .failed = await LocationResolve.send(body: ["id": "x"], client: nil, session: session) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(ResolveStubProxy.methods, [])
    }

    /// A display-only suggestion keeps its id and provider through the real autocomplete request.
    func testTheAutocompleteKeepsEachSuggestionsIdAndProvider() async throws {
        ResolveStubProxy.reply = try JSONSerialization.data(withJSONObject: [
            "data": ["suggestions": [LocationSuggestionSearchTests.addressSuggestion]],
        ])
        let listing = LocationListingRequest(query: "12 Example", type: "address", biasCountry: nil, language: "pt")
        let items = await LocationAutocomplete.fetchItems(listing: listing, client: client, session: session)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, LocationSuggestionSearchTests.listedAddressId)
        XCTAssertEqual(items.first?.provider, "mapbox")
        XCTAssertEqual(items.first?.data.formatted_address, LocationSuggestionSearchTests.line)
        let sent = try XCTUnwrap(ResolveStubProxy.bodies.first)
        XCTAssertEqual(Set(sent.keys), ["query", "limit", "type", "language"], "the listing request is what was sent")
        XCTAssertEqual(ResolveStubProxy.urls.first, "https://api.appdna.ai/api/v1/sdk/geocode/autocomplete")
    }
}
