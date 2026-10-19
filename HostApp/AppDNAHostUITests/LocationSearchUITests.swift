// LocationSearchUITests.swift — #963 / #964
//
// The on-device half of #963: does the `location_type` an author sets on a Location CONTENT BLOCK
// reach the search request?
//
// Until 1.0.82 this surface ran `MKLocalSearchCompleter` against Apple's place index, which takes
// no country bias, no language tag and has no city / region / country result type — so three of
// the four Console settings were structurally impossible to honour, and the fourth (the character
// threshold) was not read either. The block now calls the same geocoding proxy the form-step
// Location field calls.
//
// 🔴 HOW THIS IS READABLE. The proxy checks a cache BEFORE calling its provider, and the cache key
// carries the type: `geocode:v2:<query>:<type ?? 'all'>:<country>:<language>`. The walk's backend
// has those entries seeded with text that NAMES the key it was stored under, so the suggestion the
// device draws is a direct read-out of the type the SDK sent:
//
//     a block with NO authored type   must draw  TYPE=all …
//     a block authored `city`         must draw  TYPE=city …
//
// Drawing the other line is the defect. Drawing nothing means no request happened. That is a
// sharper assertion than a live provider would give, where "city results" versus "unfiltered
// results" is a judgement about the provider's ranking rather than a fact about the request.
//
// It needs a backend, a key and a published flow, so it is SKIPPED unless `TestCredentials` has
// been filled in — `packages/appdna-sdk-ios/**` is a public mirror and must carry no credentials.
// `scripts/sdk-host-ios.ts --uitest --api-key … --onboarding …` writes them on the Mac before
// building, and `scripts/spec502/seed-963-geocode-cache.ts` seeds the entries.
import XCTest

final class LocationSearchUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.flowId.isEmpty ? nil : TestCredentials.flowId }

    /// The query the cache is seeded for. Four characters, so it also clears the block's authored
    /// `location_min_chars: 3` — a threshold this surface did not read before 1.0.83.
    private let query = "Lisb"

    func testTheAuthoredLocationTypeReachesTheRequest() throws {
        guard let apiKey, let flowId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaFlow", flowId]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        // The SDK fetches its config after configure(); the flow cannot present before it lands.
        // Tapping and retrying records how long that took instead of hiding it in one long sleep.
        var presented = false
        for attempt in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["No authored Type"].waitForExistence(timeout: 5)
            if !presented { NSLog("flow not up yet, attempt \(attempt + 1)") }
        }
        XCTAssertTrue(presented, "the flow never presented — config did not arrive")

        // ── Step 1: a content block with NO authored type ─────────────────────────────────────
        try select(app, expecting: "TYPE=all", absent: "TYPE=city", because:
            "a block with no authored Type must leave the search unfiltered (#964) — the proxy "
            + "narrows only when the key is present, so sending a substituted default is the defect")
        app.buttons["Next"].tap()

        // ── Step 2: the same block, authored `city` ───────────────────────────────────────────
        XCTAssertTrue(app.staticTexts["Type = City"].waitForExistence(timeout: 10), "step 2 never arrived")
        try select(app, expecting: "TYPE=city", absent: "TYPE=all", because:
            "an authored Type must reach the request — before 1.0.83 this surface searched Apple's "
            + "place index and sent nothing, so the author's City did nothing at all")
        app.buttons["Next"].tap()

        // ── Step 3: the character threshold, which this surface never read ────────────────────
        //
        // 🔴 ITS OWN NEGATIVE CONTROL. The backend is seeded for BOTH `Lisb` and `Lisbon`, so the
        // four-character search would answer if it were made. Nothing is drawn only because the
        // authored threshold of 6 stopped it — and before 1.0.83 this surface searched from the
        // FIRST keystroke, so it would have drawn here.
        XCTAssertTrue(app.staticTexts["Min characters = 6"].waitForExistence(timeout: 10), "step 3 never arrived")
        let short = app.textFields.firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 10))
        short.tap()
        short.typeText("Lisb")
        let anySuggestion = NSPredicate(format: "label BEGINSWITH %@", "TYPE=")
        XCTAssertFalse(
            app.staticTexts.containing(anySuggestion).element.waitForExistence(timeout: 6)
                || app.buttons.containing(anySuggestion).element.exists,
            "four characters must draw nothing when the authored threshold is 6 — the backend has "
            + "an answer for this query, so anything drawn means the threshold was ignored"
        )
        /*
         * 🔴 TYPE THE REMAINING TWO CHARACTERS — do not start again. `typeText` APPENDS, and the
         * first version of this test called the full type-and-select helper here: the field went
         * from "Lisbon" to "LisbonLisb", a query nothing is seeded for, and the test failed
         * claiming the request never reached the proxy. The element tree is what showed it
         * (`value: LisbonLisb`), which is why the failure message carries one.
         */
        short.typeText("on")
        try selectAlreadyTyped(app, expecting: "TYPE=all")
        app.buttons["Next"].tap()

        // ── Step 4: the OTHER surface — a form-step Location field ────────────────────────────
        XCTAssertTrue(
            app.staticTexts["Location (form-step field, no Type set)"].waitForExistence(timeout: 10),
            "the form step never arrived"
        )
        try select(app, expecting: "TYPE=all", absent: "TYPE=address", because:
            "the form-step field resolves through the same LocationSearchSettings and must send "
            + "nothing for an unauthored Type (#964) — `address` is the default Android used to "
            + "substitute")

        /*
         * The flow has one more step after the form — a plain "Done" screen, so that the form step
         * has somewhere to route to. iOS honours that rule and lands on it; the Android walk of the
         * same flow went straight to completion from the form step, which is a difference in how a
         * form step's `next_step_rules` is followed and not something this issue is about.
         * Tolerating both is what keeps this test about the location settings.
         */
        app.buttons["Continue"].tap()
        if app.staticTexts["Done"].waitForExistence(timeout: 8) {
            app.buttons["Finish"].tap()
        }
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20), "the flow did not complete")
    }

    /// Types, asserts the expected suggestion is drawn and the wrong one is not, then TAPS it and
    /// checks the field carries the selection afterwards (Rule 24 — a control is operated, not
    /// merely drawn).
    private func select(
        _ app: XCUIApplication,
        expecting prefix: String,
        absent: String?,
        because reason: String
    ) throws {
        let suggestion = try search(app, expecting: prefix, typing: true)
        if let absent {
            let gone = NSPredicate(format: "label BEGINSWITH %@", absent)
            XCTAssertFalse(app.staticTexts.containing(gone).element.exists, reason)
            XCTAssertFalse(app.buttons.containing(gone).element.exists, reason)
        }
        suggestion.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(
            (field.value as? String)?.hasPrefix(prefix) == true,
            "selecting a suggestion must fill the field with it; got \(String(describing: field.value))"
        )
    }

    /// Types into the step's location field and returns the suggestion whose first line begins with
    /// `expecting`, failing with what was drawn instead.
    /// Taps the suggestion already on screen, for a field whose text has been typed by the caller.
    private func selectAlreadyTyped(_ app: XCUIApplication, expecting prefix: String) throws {
        let suggestion = try search(app, expecting: prefix, typing: false)
        suggestion.tap()
    }

    private func search(_ app: XCUIApplication, expecting prefix: String, typing: Bool) throws -> XCUIElement {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the step has no location field")
        if typing {
            field.tap()
            field.typeText(query)
        }

        /*
         * 🔴 BOTH `staticTexts` AND `buttons`. Each suggestion row is a SwiftUI `Button` wrapping
         * two `Text`s, and SwiftUI may expose that either as the two labels or as ONE accessibility
         * element on the button — which of the two you get depends on the row's content and on the
         * OS version. Querying only one of them makes "the suggestion is absent" mean "I looked in
         * the wrong half of the tree", which is the shape of a test that proves nothing.
         */
        let matching = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let asText = app.staticTexts.containing(matching).element
        let asButton = app.buttons.containing(matching).element
        let appeared = asText.waitForExistence(timeout: 15) || asButton.waitForExistence(timeout: 3)
        if !appeared {
            let drawn = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex)
                .map(\.label).filter { $0.contains("TYPE=") }
            XCTFail(
                "no suggestion beginning \"\(prefix)\" appeared (field value: "
                + "\(String(describing: app.textFields.firstMatch.value))). "
                + "TYPE= labels on screen: \(drawn.isEmpty ? "none" : drawn.joined(separator: " | "))"
                + "\n--- what IS on screen ---\n"
                + String(app.debugDescription.prefix(4000))
            )
        }
        return asText.exists ? asText : asButton
    }
}
