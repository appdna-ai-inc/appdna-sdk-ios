import XCTest

/**
 #1086 / #995 — A REAL PROVIDER SUGGESTION IS SELECTED, AND WHAT GETS STORED IS REAL.

 Every earlier proof of the location path read a SEEDED cache entry, because no geocoding key
 existed anywhere: `LocationSearchUITests` deliberately asserts text that NAMES the cache key it was
 stored under, which answers #963's question (does the authored `location_type` reach the request?)
 and says nothing about a provider ever having answered.

 A real key exists now. This types a city the seed does not cover, so the proxy misses the cache and
 calls the provider for real, and then asserts the thing #995 actually asked for: *"a selected one
 stores a real city, country, coordinates and time zone."*

 🔴 THE ASSERTION IS ON WHAT WAS STORED, NOT ON WHAT WAS DRAWN. A dropdown row proves the provider
 answered; it says nothing about whether the structured answer reached the store in the shape both
 SDKs decode — which is the half #995 called "most likely to bite", because a wrong assumption about
 a provider's response shape looks exactly like "no results". So the app is TERMINATED and
 RELAUNCHED, and the answer is read back through `AppDNA.getLocationData(fieldId:)` — the same API an
 integrator would call — from `UserDefaults`, where `setOnboardingResponses` persists it
 incrementally on step advance. A value that survives a relaunch was stored, not remembered.

 It coexists with `LocationSearchUITests` on purpose: that one types `Lisb`, which IS seeded, and
 this one types a city that is not, so the two do not compete for cache state.
 */
final class RealLocationSuggestionUITests: XCTestCase {

    /// Not seeded by `seed-963-geocode-cache.ts` (which seeds `lisb`), so this query reaches the
    /// provider. A city whose name is the same in English and Portuguese, so `language` cannot
    /// turn it into a homonym the way "Vienna" with `de` does (#995).
    private static let query = "Porto"

    /// The first step's content-block field — see `probe-963-location-walk-flow.ts`.
    private static let fieldId = "probe963_loc_all"

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.locationFlowId.isEmpty ? nil : TestCredentials.locationFlowId }

    func testARealSuggestionIsStoredWithItsCityCountryCoordinatesAndZone() throws {
        guard let apiKey, let flowId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest --location-flow <id>")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-appdnaApiKey", apiKey, "-appdnaFlow", flowId, "-appdnaLocationField", Self.fieldId,
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        // The SDK fetches its config after configure(); the flow cannot present before it lands.
        var presented = false
        for attempt in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["No authored Type"].waitForExistence(timeout: 5)
            if !presented { NSLog("[#1086] flow not up yet, attempt \(attempt + 1)") }
        }
        if !presented {
            /*
             🔴 SAY WHAT IS ON SCREEN. "the flow never presented" is a conclusion, and the two
             causes need opposite fixes: the config did not arrive (nothing but the host's own
             buttons is drawn) or it did and this test is waiting for the wrong heading. Dumping the
             labels turns one failed run into the answer instead of another round trip.
             */
            let drawn = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex)
                .map(\.label).filter { !$0.isEmpty }.prefix(30)
            XCTFail("the flow never presented. On screen: \(Array(drawn))")
            return
        }

        // ── type a query the cache does not hold, so the provider answers ─────────────────────
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the step has no location field")
        type(Self.query, into: field, in: app)

        let suggestion = try realSuggestion(in: app)
        NSLog("[#1086] a real suggestion was drawn: \(suggestion.label)")
        let beforeTap = (field.value as? String) ?? ""
        suggestion.tap()

        /*
         🔴 ASSERT THE FIELD CHANGED, not that it contains the query.

         The first version of this check asked whether the field contained "Porto" — which is the
         text the test had just TYPED, so it passed whether or not the suggestion tap registered. A
         tautological assertion is worse than none: it reported the selection as taken while the
         stored answer stayed empty, and sent me looking at persistence for three runs.

         Selecting replaces the typed text with the place's formatted address ("Porto, Porto,
         Portugal"), so a CHANGE is the thing only a selection produces.
         */
        var afterTap = (field.value as? String) ?? ""
        for _ in 0..<12 where afterTap == beforeTap {
            Thread.sleep(forTimeInterval: 0.25)
            afterTap = (field.value as? String) ?? ""
        }
        NSLog("[#1086] field before the tap: \(beforeTap) | after: \(afterTap)")
        XCTAssertNotEqual(
            afterTap, beforeTap,
            "tapping the suggestion did not change the field, so the selection never registered — "
                + "the field still holds the typed text (\(beforeTap))",
        )
        XCTAssertTrue(
            afterTap.localizedCaseInsensitiveContains(Self.query),
            "the field changed but no longer names the place that was selected: \(afterTap)",
        )

        /*
         Advancing is what persists the answer — `OnboardingRenderer` collects the step's input
         values into the advance payload and `setOnboardingResponses` writes them ("persist
         responses incrementally"), rather than only at completion.
         */
        app.buttons["Next"].tap()

        /*
         🔴 ASSERT THE ADVANCE, because "nothing was stored" has two causes needing opposite fixes:
         the step never advanced (nothing to persist) or it advanced and the value did not arrive.
         */
        XCTAssertTrue(
            app.staticTexts["Type = City"].waitForExistence(timeout: 15),
            "the step did not advance, so the answer was never persisted — the Next tap did not take",
        )

        /*
         🔴 DISMISS, DO NOT KILL. Reading the host's readback needs the host view, and the earlier
         version got there by terminating and relaunching the app — which turned this into a test of
         whether `UserDefaults` had flushed before a SIGKILL, a question #1086 never asked. Three
         runs read UNANSWERED for that reason alone.

         The flow has a Close control, so the honest route is to leave the flow the way a user can
         and read what the SDK holds. Persistence across a cold start is a different claim and is
         not what this asserts.
         */
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["host.title"].waitForExistence(timeout: 20),
            "the flow did not close, so the host's readback is unreachable",
        )

        let stored = try readback(in: app)
        NSLog("[#1086] stored answer, read through AppDNA.getLocationData: \(stored)")

        // ── the shape #995 asked for ──────────────────────────────────────────────────────────
        XCTAssertTrue(stored.contains("city="), "no city was stored — \(stored)")
        XCTAssertTrue(stored.contains("country="), "no country was stored — \(stored)")
        XCTAssertTrue(stored.contains("lat="), "no latitude was stored — \(stored)")
        XCTAssertTrue(stored.contains("lng="), "no longitude was stored — \(stored)")
        XCTAssertTrue(stored.contains("tz="), "no time zone was stored — \(stored)")

        /*
         And the values are the PLACE, not merely present. A stored answer of `city=` with the typed
         text and null coordinates is exactly what a typed-but-unselected field stores, so asserting
         only that the keys exist would pass for the case this test is meant to distinguish.
         */
        XCTAssertTrue(
            stored.localizedCaseInsensitiveContains(Self.query),
            "the stored answer does not name the place that was selected — \(stored)",
        )
        XCTAssertFalse(
            stored.contains("TYPE="),
            "the stored answer came from a SEEDED cache entry, so no provider was called — \(stored)",
        )
    }

    // MARK: - helpers

    /*
     🔴 A TAP IS NOT FOCUS. A tap landing while the step is still settling leaves the field
     un-focused and `typeText` then fails with "Neither element nor any descendant has keyboard
     focus" — a flake that reads exactly like the field being broken. The KEYBOARD is the
     observable that says the tap took. (Same reasoning as `LocationSearchUITests`.)
     */
    /**
     Types and VERIFIES, retrying if the text did not land.

     🔴 One run in four typed nothing: the field was present, the tap reported success, and no
     search fired — so the dropdown was empty and the failure read as "the provider returned
     nothing", which sent me to check the server instead of the keyboard. Asserting the field's own
     value is what tells the two apart.
     */
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        for attempt in 1...4 {
            focus(field, in: app)
            field.typeText(text)
            if (field.value as? String)?.localizedCaseInsensitiveContains(text) == true { return }
            NSLog("[#1086] the text did not land, attempt \(attempt) — field holds "
                + "\(String(describing: field.value))")
        }
        XCTFail("could not type \(text) into the location field after four attempts")
    }

    private func focus(_ field: XCUIElement, in app: XCUIApplication) {
        for attempt in 0..<5 {
            field.tap()
            if app.keyboards.element.waitForExistence(timeout: 3) { return }
            NSLog("[#1086] field did not take focus, attempt \(attempt + 1)")
        }
        XCTFail("the location field never took keyboard focus")
    }

    /**
     A suggestion row that names the query and is NOT a seeded read-out.

     Both `staticTexts` and `buttons` are queried: each row is a SwiftUI `Button` wrapping two
     `Text`s, and SwiftUI may expose that as the two labels or as one element on the button
     depending on the row's content and the OS version. Querying one half makes "no suggestion
     appeared" mean "I looked in the wrong half of the tree".
     */
    private func realSuggestion(in app: XCUIApplication) throws -> XCUIElement {
        let matching = NSPredicate(
            format: "label CONTAINS[c] %@ AND NOT (label BEGINSWITH %@)", Self.query, "TYPE=",
        )
        /*
         🔴 `firstMatch`, NOT `.element`. `.element` demands exactly one match and throws
         "Multiple matching elements found" otherwise — which is what a REAL provider answer
         produces: typing "Porto" returns Porto, Portofino, Portoferraio… The seeded fixture the
         older test uses returns one row, so `.element` works there and cannot work here. The
         ambiguity is the evidence that a real list was drawn.
         */
        let asText = app.staticTexts.containing(matching).firstMatch
        let asButton = app.buttons.containing(matching).firstMatch
        if asText.waitForExistence(timeout: 20) { return asText }
        if asButton.waitForExistence(timeout: 5) { return asButton }

        let drawn = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex)
            .map(\.label).filter { !$0.isEmpty }.prefix(25)
        XCTFail(
            "no real suggestion for \"\(Self.query)\" appeared. Either the provider returned nothing "
                + "— check MAPBOX_ACCESS_TOKEN reaches the server and that geocode:v2:* holds no "
                + "stale empty entry for this query — or the dropdown drew a seeded read-out. "
                + "Drawn: \(Array(drawn))",
        )
        throw XCTSkip("no suggestion to select")
    }

    /// The host's readback, polled: the SDK loads its store on init and the view re-evaluates as
    /// events arrive, so the first paint can legitimately precede the value.
    private func readback(in app: XCUIApplication) throws -> String {
        let mirror = app.staticTexts["host.locationData"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 15), "the host has no location readback surface")
        for _ in 0..<20 {
            let value = mirror.label
            if !value.contains("UNANSWERED") && !value.contains("no field asked for") { return value }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("the stored answer never appeared — the readback said: \(mirror.label)")
        throw XCTSkip("nothing stored")
    }
}
