// GoogleAttributionTests.swift
//
// Google's attribution for location content shown without a Google map:
//   - the "Google Maps" logo under a dropdown listing Google suggestions, and beside a field holding a
//     Google answer (both location views);
//   - the credit an onboarding step's container draws when its text templates a Google answer
//     (`GoogleCredit`), each case the walk has to get right, with its red control named;
//   - the TemplateEngine's surface rule: off onboarding, a Google answer is the user's typed text.
//
// The render tests draw the REAL views in a real key window (the harness `SurfaceSnapshotTests` uses)
// and compare two frames that differ in ONE input, so a difference can only be the attribution. Each
// carries its negative control: two renders of the same input are identical, so the harness is not
// reporting noise as a difference.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

// MARK: - Synthetic answers

enum GoogleAttributionData {
    static let google: [String: Any] = [
        "formatted_address": "Springfield, IL, USA", "address": "Springfield, IL, USA",
        "city": "Springfield", "state": "Illinois", "country_code": "US",
        "latitude": 39.78, "longitude": -89.65, "timezone": "America/Chicago", "timezone_offset": -300,
        "raw_query": "Springf", "place_id": "ChIJ-synthetic-springfield",
    ]
    /// The SAME display values as `google`, from Mapbox: a frame that differs between the two can only
    /// differ by Google's attribution.
    static let mapboxSameText: [String: Any] = [
        "formatted_address": "Springfield, IL, USA", "address": "Springfield, IL, USA",
        "city": "Springfield", "state": "Illinois", "country_code": "US",
        "latitude": 39.78, "longitude": -89.65, "timezone": "America/Chicago", "timezone_offset": -300,
        "raw_query": "Springf", "mapbox_id": "dXJuOm1ieHBsYzpzeW50aGV0aWMtc3ByaW5nZmllbGQ=",
    ]
    static let legacy: [String: Any] = [
        "formatted_address": "Springfield, IL, USA", "city": "Springfield", "timezone": "America/Chicago",
    ]
}

// MARK: - The credit walk

final class GoogleCreditTests: XCTestCase {

    private func step(_ json: String) throws -> OnboardingStep {
        try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
    }

    private func answers(
        accumulated: [String: Any] = ["places": ["home": GoogleAttributionData.google]],
        store: [String: [String: Any]] = ["places": ["home": GoogleAttributionData.google]],
        inputs: [String: Any] = [:]
    ) -> GoogleCredit.Answers {
        GoogleCredit.Answers(accumulated: accumulated, stepInputs: inputs, sessionStore: store)
    }

    private func shows(_ s: OnboardingStep, override: StepConfigOverride? = nil,
                       patches: [String: [String: Any]] = [:], answers a: GoogleCredit.Answers) -> Bool {
        GoogleCredit.shows(step: s, override: override, fieldConfigOverrides: patches, fieldOptionsOverrides: [:], answers: a)
    }

    private let textBlockStep = """
    {"id":"greet","type":"custom","config":{"content_blocks":[
      {"id":"hello","type":"text","text":"Welcome from {{responses.places.home.city}}"}]}}
    """

    /// An option sheet decides its credit from the options picked when it asks, not when the step last
    /// drew: a pick recorded after the context was built (the pick that opens the sheet, or one inside
    /// it) counts.
    /// RED CONTROL: `GoogleCreditSheetContext.shows` reading `answers.selected` only (the snapshot the
    /// step drew with) fails the live leg.
    func testASheetsCreditReadsTheOptionsPickedWhenItAsks() throws {
        let s = try step("""
        {"id":"s","type":"custom","config":{"content_blocks":[{"id":"sel","type":"input_select","field_id":"stop",
          "field_config":{"display_style":"list"},"field_options":[{"id":"o1","label":"Open","value":"o1",
          "sheet_blocks":[{"id":"sh","type":"text","text":"You chose {{selected.near.label}}"}]}]}]}}
        """)
        let store = SelectedOptionStore()
        let sources = GoogleCredit.stepSources(step: s, override: nil, fieldConfigOverrides: [:], fieldOptionsOverrides: [:])
        let context = GoogleCreditSheetContext(
            sources: { sources }, answers: answers(store: [:]), selected: { store.snapshot }
        )
        let frozen = GoogleCreditSheetContext(sources: { sources }, answers: answers(store: [:]))
        func ask(_ c: GoogleCreditSheetContext) -> Bool {
            c.shows(blockId: "sel", optionId: "o1", presentedSheetBlocks: [], sheetInputs: [:])
        }
        XCTAssertFalse(ask(context), "nothing picked yet: no credit")
        var near = try JSONDecoder().decode(InputOption.self, from: Data(#"{"id":"n","label":"Springfield","value":"n"}"#.utf8))
        near.googleKeys = ["label": "Springf"]
        store.record(fieldId: "near", option: near)
        XCTAssertTrue(ask(context), "the pick made since the context was built credits")
        XCTAssertFalse(ask(frozen), "control: a context holding only the snapshot it was built with does not")
    }

    /// A content-block token reaching a Google answer credits; the same token on a Mapbox or a
    /// legacy answer does not.
    func testAContentBlockTokenCreditsOnlyAGoogleAnswer() throws {
        let s = try step(textBlockStep)
        XCTAssertTrue(shows(s, answers: answers()))
        let mapbox = ["places": ["home": GoogleAttributionData.mapboxSameText]]
        XCTAssertFalse(shows(s, answers: answers(accumulated: mapbox, store: mapbox)))
        let legacy = ["places": ["home": GoogleAttributionData.legacy]]
        XCTAssertFalse(shows(s, answers: answers(accumulated: legacy, store: legacy)))
    }

    /// RED CONTROL (spec): a walk that skips nested arrays misses a question option's label.
    func testAQuestionOptionLabelCredits() throws {
        let s = try step("""
        {"id":"pick","type":"question","config":{"title":"Where next?","options":[
          {"id":"stay","label":"Stay in {{input.home.city}}"},{"id":"go","label":"Somewhere else"}]}}
        """)
        XCTAssertTrue(shows(s, answers: answers(accumulated: [:])))
    }

    /// RED CONTROL (spec): ignoring the override map fails this — the step itself holds no token.
    func testATokenInTheConfigOverrideCredits() throws {
        let s = try step(#"{"id":"w","type":"welcome","config":{"title":"Welcome","cta_text":"Next"}}"#)
        XCTAssertFalse(shows(s, answers: answers()), "control: without the override nothing credits")
        let override = StepConfigOverride(title: "Welcome to {{responses.places.home.city}}")
        XCTAssertTrue(shows(s, override: override, answers: answers()))
    }

    /// The interaction patches are walked with the step.
    func testATokenInAnInteractionPatchCredits() throws {
        let s = try step("""
        {"id":"p","type":"custom","config":{"content_blocks":[
          {"id":"sel","type":"input_select","field_id":"pick","field_options":[{"id":"a","label":"A"}]}]}}
        """)
        XCTAssertFalse(shows(s, answers: answers()))
        XCTAssertTrue(shows(s, patches: ["sel": ["search_placeholder": "Near {{responses.places.home.city}}"]], answers: answers()))
    }

    /// A visibility condition names its variable without braces and outside `bindings`: no credit.
    /// RED CONTROL: reading every bare dotted string as a path would credit it.
    func testAVisibilityConditionAloneDoesNotCredit() throws {
        let s = try step("""
        {"id":"v","type":"custom","config":{"content_blocks":[
          {"id":"hello","type":"text","text":"Nice to meet you",
           "visibility_condition":{"type":"when_not_empty","variable":"responses.places.home.place_id"}}]}}
        """)
        XCTAssertFalse(shows(s, answers: answers()))
    }

    /// RED CONTROL (spec): skipping `bindings` fails this.
    func testATextBoundThroughBindingsCredits() throws {
        let s = try step("""
        {"id":"b","type":"custom","config":{"content_blocks":[
          {"id":"hello","type":"text","text":"placeholder","bindings":{"text":"responses.places.home.city"}}]}}
        """)
        XCTAssertTrue(shows(s, answers: answers()))
    }

    /// A token inside an option's `sheet_blocks` credits INSIDE the sheet, never on the step.
    /// RED CONTROL: a step walk that does not skip `sheet_blocks` credits the step.
    func testATokenInAnOptionSheetCreditsTheSheetNotTheStep() throws {
        let s = try step("""
        {"id":"sh","type":"custom","config":{"content_blocks":[
          {"id":"sel","type":"input_select","field_id":"pick","field_options":[
            {"id":"near","label":"Near me","sheet_blocks":[{"id":"t","type":"text","text":"Close to {{responses.places.home.city}}"}]},
            {"id":"far","label":"Far away"}]}]}}
        """)
        let a = answers()
        XCTAssertFalse(shows(s, answers: a), "the step's own walk skips sheet_blocks")
        let context = GoogleCreditSheetContext(
            sources: { GoogleCredit.stepSources(step: s, override: nil, fieldConfigOverrides: [:], fieldOptionsOverrides: [:]) },
            answers: a
        )
        XCTAssertTrue(context.shows(blockId: "sel", optionId: "near", presentedSheetBlocks: [], sheetInputs: [:]))
        XCTAssertFalse(context.shows(blockId: "sel", optionId: "far", presentedSheetBlocks: [], sheetInputs: [:]))
    }

    /// A sheet's `step` root reads the SHEET's own inputs, not the step's.
    func testASheetStepRootReadsTheSheetInputs() throws {
        let s = try step("""
        {"id":"sh2","type":"custom","config":{"content_blocks":[
          {"id":"sel","type":"input_select","field_id":"pick","field_options":[
            {"id":"near","label":"Near","sheet_blocks":[{"id":"t","type":"text","text":"{{step.where.city}}"}]}]}]}}
        """)
        let none: [String: Any] = [:]
        let a = answers(accumulated: none, store: [:], inputs: ["where": GoogleAttributionData.google])
        let context = GoogleCreditSheetContext(
            sources: { GoogleCredit.stepSources(step: s, override: nil, fieldConfigOverrides: [:], fieldOptionsOverrides: [:]) },
            answers: a
        )
        XCTAssertFalse(context.shows(blockId: "sel", optionId: "near", presentedSheetBlocks: [], sheetInputs: [:]),
                       "the step's inputs are not the sheet's")
        XCTAssertTrue(context.shows(blockId: "sel", optionId: "near", presentedSheetBlocks: [],
                                    sheetInputs: ["where": GoogleAttributionData.google]))
    }

    /// RED CONTROL (spec): a legacy step shown FIRST in a re-presented flow — nothing accumulated, the
    /// session store still holding the previous run's Google answer — credits. Reading only the
    /// accumulated answers fails this.
    func testARepresentedFlowsFirstStepCreditsTheSessionStore() throws {
        let s = try step(#"{"id":"again","type":"welcome","config":{"title":"Back in {{responses.places.home.city}}?","cta_text":"Yes"}}"#)
        XCTAssertTrue(shows(s, answers: answers(accumulated: [:])))
    }

    /// Each legacy view's text: a form title, a welcome heading, a value-prop item, a custom subtitle
    /// and a form field's placeholder.
    func testEveryLegacyViewsTextCredits() throws {
        let cases = [
            #"{"id":"f","type":"form","config":{"title":"Your home: {{onboarding.places.home.city}}","fields":[{"id":"n","type":"text","label":"Nick","required":false}]}}"#,
            #"{"id":"w","type":"welcome","config":{"title":"Hello, {{responses.places.home.state}}","cta_text":"Start"}}"#,
            #"{"id":"v","type":"value_prop","config":{"title":"Why","items":[{"icon":"star","title":"Local","subtitle":"Made for {{onboarding.places.home.city}}"}]}}"#,
            #"{"id":"c","type":"custom","config":{"title":"Almost","subtitle":"Shipping to {{onboarding.places.home.country_code}}"}}"#,
            #"{"id":"a","type":"form","config":{"title":"Details","fields":[{"id":"st","type":"text","label":"Street","placeholder":"A street in {{onboarding.places.home.city}}","required":false}]}}"#,
        ]
        for json in cases {
            XCTAssertTrue(shows(try step(json), answers: answers(accumulated: [:])), json)
        }
    }

    /// A step that templates nothing never credits, whatever answers exist.
    func testAStepWithoutTokensNeverCredits() throws {
        let s = try step(#"{"id":"w","type":"welcome","config":{"title":"Hello","cta_text":"Go"}}"#)
        XCTAssertFalse(shows(s, answers: answers()))
    }
}

// MARK: - The TemplateEngine surface rule

final class TemplateSurfaceTests: XCTestCase {

    private func context(_ surface: TemplateSurface) -> TemplateContext {
        var ctx = TemplateContext(
            userTraits: nil, remoteConfig: { _ in nil },
            onboardingResponses: ["places": ["home": GoogleAttributionData.google, "work": GoogleAttributionData.mapboxSameText]],
            computedData: [:], sessionData: [:], deviceInfo: [:]
        )
        ctx.surface = surface
        return ctx
    }

    /// RED CONTROL: an engine that ignores the surface prints the Google city here.
    func testOffOnboardingAGoogleAnswerIsTheTypedText() {
        let t = "{{responses.places.home.city}}|{{responses.places.home}}|{{input.home}}|{{onboarding.places.home.state}}"
        XCTAssertEqual(TemplateEngine.shared.interpolate(t, context: context(.other)), "Springf|Springf|Springf|Springf")
    }

    func testOffOnboardingAMapboxAnswerKeepsItsCity() {
        XCTAssertEqual(TemplateEngine.shared.interpolate("{{responses.places.work.city}}", context: context(.other)), "Springfield")
    }

    func testOnOnboardingAGoogleAnswerKeepsItsCity() {
        XCTAssertEqual(TemplateEngine.shared.interpolate("{{responses.places.home.city}}", context: context(.onboarding)), "Springfield")
    }

    /// A whole step stringified off onboarding never carries the Google answer's content.
    func testOffOnboardingAStepHoldingAGoogleAnswerIsRedacted() {
        let out = TemplateEngine.shared.interpolate("{{input.home}} {{responses.places}}", context: context(.other))
        XCTAssertFalse(out.contains("Illinois"), out)
        XCTAssertFalse(out.contains("ChIJ"), out)
    }

    /// A hand-built context defaults to the restrictive surface.
    func testAHandBuiltContextDefaultsToOther() {
        let ctx = TemplateContext(userTraits: nil, remoteConfig: { _ in nil }, onboardingResponses: [:],
                                  computedData: [:], sessionData: [:], deviceInfo: [:])
        XCTAssertEqual(ctx.surface, .other)
    }
}

// MARK: - The logo: asset, variant, and the holder

final class GoogleMapsLogoTests: XCTestCase {

    /// Every variant ships in the SDK's resource bundle — the same lookup CocoaPods and SwiftPM hosts
    /// both reach — and reads at Google's 4x render size.
    func testEveryVariantLoadsFromTheResourceBundle() {
        for v in GoogleMapsAttribution.Variant.allCases {
            let image = GoogleMapsAttribution.image(v)
            XCTAssertNotNil(image, "\(v.rawValue) is missing from AppDNAResources.bundle")
            if let image { XCTAssertEqual(image.scale, 4) }
        }
    }

    func testTheVariantFollowsTheSurface() {
        typealias A = GoogleMapsAttribution
        XCTAssertEqual(A.variant(on: .plain(hex: nil), darkAppearance: false), .gray)
        XCTAssertEqual(A.variant(on: .plain(hex: nil), darkAppearance: true), .white)
        XCTAssertEqual(A.variant(on: .plain(hex: "#FFFFFF"), darkAppearance: true), .gray, "an authored light colour decides")
        XCTAssertEqual(A.variant(on: .plain(hex: "#101828"), darkAppearance: false), .white, "an authored dark colour decides")
        XCTAssertEqual(A.variant(on: .busy, darkAppearance: false), .lightOutline)
        XCTAssertEqual(A.variant(on: .busy, darkAppearance: true), .darkOutline)
        XCTAssertEqual(A.backdrop(of: nil), .plain(hex: nil))
    }

    private let googleRow: [String: Any] = ["id": "ChIJ-synthetic-springfield", "provider": "google",
                                            "formatted_address": "Springfield, IL, USA"]
    private let mapboxRow: [String: Any] = ["id": "dXJuOm1ieHBsYzpzeW50aGV0aWMtcG9ydG8=", "provider": "mapbox",
                                            "formatted_address": "Springfield, IL, USA"]

    private func settings() -> LocationSearchSettings {
        LocationSearchSettings.from(blockConfig: ["location_language": AnyCodable("en")], defaultMinChars: 3)
    }

    func testTheHolderShowsTheLogoForAGoogleListOnly() {
        let g = LocationSearchRig(settings: settings(), autocomplete: ["Springf": [googleRow]])
        g.type("Springf"); g.advance(ms: 300)
        XCTAssertTrue(g.holder.isDropdownOpen)
        XCTAssertTrue(g.holder.showsGoogleLogo)
        let m = LocationSearchRig(settings: settings(), autocomplete: ["Springf": [mapboxRow]])
        m.type("Springf"); m.advance(ms: 300)
        XCTAssertTrue(m.holder.isDropdownOpen)
        XCTAssertFalse(m.holder.showsGoogleLogo)
    }

    /// A Google tap, end to end through the ONE holder both views bind to, with a stubbed reply: the
    /// body is `{id, provider, language}`, and the stored answer keeps `place_id`, the typed text as
    /// `raw_query`, and the resolved line in the field — which then carries the attribution.
    func testAGoogleTapStoresThePlaceIdAndTheResolvedLine() throws {
        let rig = LocationSearchRig(settings: settings(), autocomplete: ["Springf": [googleRow]])
        rig.type("Springf"); rig.advance(ms: 300)
        rig.tap(0)
        XCTAssertNil(rig.stored, "nothing is stored while the resolve is in flight")
        let body = try XCTUnwrap(rig.resolveBodies.first)
        XCTAssertEqual(Set(body.keys), ["id", "provider", "language"])
        var reply = GoogleAttributionData.google
        reply.removeValue(forKey: "raw_query"); reply.removeValue(forKey: "address")
        reply["provider"] = "google"
        rig.reply(status: 200, body: ["data": ["resolved": true, "suggestion": reply]])
        rig.echo()
        let stored = try XCTUnwrap(rig.stored as? [String: Any])
        XCTAssertEqual(stored["place_id"] as? String, "ChIJ-synthetic-springfield")
        XCTAssertEqual(stored["raw_query"] as? String, "Springf")
        XCTAssertEqual(stored["city"] as? String, "Springfield")
        XCTAssertEqual(rig.holder.text, "Springfield, IL, USA")
        XCTAssertTrue(LocationAnswer.carriesPlaceId(rig.stored))
        XCTAssertFalse(rig.holder.showsGoogleLogo, "the dropdown closed; the field's attribution takes over")
    }

    /// `geocoding_api_not_enabled`: only the typed text, and no attribution.
    func testARefusedGoogleTapStoresTheTypedTextWithoutAttribution() {
        let rig = LocationSearchRig(settings: settings(), autocomplete: ["Springf": [googleRow]])
        rig.type("Springf"); rig.advance(ms: 300)
        rig.tap(0)
        rig.reply(status: 200, body: ["data": ["resolved": false, "reason": "geocoding_api_not_enabled"]])
        XCTAssertEqual(rig.stored as? String, "Springf")
        XCTAssertFalse(LocationAnswer.carriesPlaceId(rig.stored))
    }
}

// MARK: - Rendered frames

@MainActor
final class GoogleAttributionRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    /// The view drawn by the real renderer in a real key window (the `SurfaceSnapshotTests` path),
    /// as RGBA bytes.
    private func pixels(_ view: some View, dark: Bool = false) -> (w: Int, h: Int, px: [UInt8]) {
        let sized = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(dark ? .black : .white))
            // The simulator's window has safe-area insets; without this the 852 pt frame is centred
            // in the smaller safe region and its bottom band falls outside the window — exactly where
            // a step's credit is drawn.
            .ignoresSafeArea()
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = UIHostingController(rootView: sized)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        guard let cg = image.cgImage else { return (0, 0, []) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, px)
    }

    /// How many pixels differ between two frames, and the rows they span (top-down).
    private func diff(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8])) -> (count: Int, minRow: Int, maxRow: Int) {
        guard a.w == b.w, a.h == b.h, !a.px.isEmpty else { return (-1, 0, 0) }
        var count = 0, minRow = Int.max, maxRow = -1
        // One channel per statement: as one expression this is beyond the type-checker's time limit on a slower machine.
        func differs(_ i: Int) -> Bool {
            let red: Int = abs(Int(a.px[i]) - Int(b.px[i]))
            let green: Int = abs(Int(a.px[i + 1]) - Int(b.px[i + 1]))
            let blue: Int = abs(Int(a.px[i + 2]) - Int(b.px[i + 2]))
            return red > 8 || green > 8 || blue > 8
        }
        for i in stride(from: 0, to: a.px.count, by: 4) where differs(i) {
            count += 1
            // A bitmap context's first row in memory is the top of the frame.
            let row = (i / 4) / a.w
            minRow = min(minRow, row); maxRow = max(maxRow, row)
        }
        return (count, minRow, maxRow)
    }

    /// The darkest pixel count — proof the frame drew something, not a blank page.
    private func inked(_ f: (w: Int, h: Int, px: [UInt8])) -> Int {
        var n = 0
        for i in stride(from: 0, to: f.px.count, by: 4) where f.px[i] < 200 && f.px[i + 1] < 200 && f.px[i + 2] < 200 { n += 1 }
        return n
    }

    // MARK: the dropdown

    private func formField(_ rows: [[String: Any]], value: Any? = nil) -> (AnyView, LocationSearchRig) {
        let settings = LocationSearchSettings.from(fieldConfig: nil, defaultMinChars: 2)
        let rig = LocationSearchRig(settings: settings, storedAnswer: value, autocomplete: ["Springf": rows])
        rig.type("Springf"); rig.advance(ms: 300)
        let field = FormField.synthetic(id: "home", type: .location)
        let view = LocationFieldView(field: field, value: .constant(value), apiClient: nil, search: rig.holder)
            .padding(16)
        return (AnyView(view), rig)
    }

    private let googleRow: [String: Any] = ["id": "ChIJ-synthetic-springfield", "provider": "google",
                                            "formatted_address": "Springfield, IL, USA"]
    private let mapboxRow: [String: Any] = ["id": "dXJuOm1ieHBsYzpzeW50aGV0aWMtcG9ydG8=", "provider": "mapbox",
                                            "formatted_address": "Springfield, IL, USA"]

    /// The form-step field: a Google list draws Google's logo at its head; the same rows from Mapbox do
    /// not. RED CONTROLS: the logo removed from the dropdown → the two frames are equal; the logo drawn
    /// after the rows → `assertTheLogoHeadsTheList` fails.
    func testTheFormStepDropdownDrawsTheLogoForGoogleOnly() {
        let (g, gRig) = formField([googleRow])
        let (m, mRig) = formField([mapboxRow])
        XCTAssertTrue(gRig.holder.isDropdownOpen && mRig.holder.isDropdownOpen)
        let gf = pixels(g), mf = pixels(m), mf2 = pixels(formField([mapboxRow]).0)
        XCTAssertGreaterThan(inked(mf), 500, "the dropdown drew")
        XCTAssertEqual(diff(mf, mf2).count, 0, "control: the same input renders the same frame")
        let d = diff(gf, mf)
        print("[google-logo] form-step dropdown: \(d.count) px differ, rows \(d.minRow)–\(d.maxRow)")
        XCTAssertGreaterThan(d.count, 200, "Google's logo is drawn in a Google list, and only there")
        // Where the dropdown starts: the same typed field with no suggestions draws no dropdown.
        assertTheLogoHeadsTheList(google: gf, mapbox: mf, closed: pixels(formField([]).0), what: "form step")
    }

    /// The logo HEADS the list, directly under the field, so it is on screen whenever the field is (the
    /// system keeps a focused field above the keyboard). Measured in rendered pixels: the first row where
    /// the Google frame differs from the Mapbox one lies within the dropdown's head, less than a
    /// suggestion row below the dropdown's top edge. Under the last row (the old place) the first
    /// difference came after a whole row. RED CONTROL: the logo moved back after the rows → this fails.
    private func assertTheLogoHeadsTheList(google gf: (w: Int, h: Int, px: [UInt8]), mapbox mf: (w: Int, h: Int, px: [UInt8]),
                                           closed cf: (w: Int, h: Int, px: [UInt8]), what: String) {
        let dropdownTop = diff(mf, cf).minRow
        let firstGoogle = diff(gf, mf).minRow
        // The logo's own clear space is 10 pt above it, so its first ink lands ~11 pt (22 px at 2x) under the
        // dropdown's top edge; after a suggestion row (the old place) it landed 43–47 pt down. 24 pt splits them.
        let rowPx = 48
        print("[google-logo] \(what): dropdown top row \(dropdownTop), first Google-only row \(firstGoogle)")
        XCTAssertGreaterThanOrEqual(firstGoogle, dropdownTop, "[\(what)] the logo is inside the dropdown")
        XCTAssertLessThan(firstGoogle - dropdownTop, rowPx,
                          "[\(what)] the logo heads the list: it starts \(firstGoogle - dropdownTop) px below the dropdown's top, after a row")
    }

    /// The `input_location` block (the onboarding block and the Screens section, which renders through
    /// the same block): the same.
    func testTheBlockDropdownDrawsTheLogoForGoogleOnly() throws {
        func block(_ rows: [[String: Any]]) throws -> (AnyView, LocationSearchRig) {
            let b = try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"id":"loc","type":"input_location","field_id":"home"}"#.utf8))
            let settings = LocationSearchSettings.from(blockConfig: nil, defaultMinChars: 3)
            let rig = LocationSearchRig(settings: settings, autocomplete: ["Springf": rows])
            rig.type("Springf"); rig.advance(ms: 300)
            return (AnyView(FormInputLocationPlaceholderBlock(block: b, inputValues: .constant([:]), search: rig.holder).padding(16)), rig)
        }
        let (g, gRig) = try block([googleRow])
        let (m, _) = try block([mapboxRow])
        XCTAssertTrue(gRig.holder.showsGoogleLogo)
        let gf = pixels(g), mf = pixels(m), mf2 = pixels(try block([mapboxRow]).0)
        XCTAssertGreaterThan(inked(mf), 500, "the dropdown drew")
        XCTAssertEqual(diff(mf, mf2).count, 0, "control: the same input renders the same frame")
        let d = diff(gf, mf)
        print("[google-logo] block dropdown: \(d.count) px differ, rows \(d.minRow)–\(d.maxRow)")
        XCTAssertGreaterThan(d.count, 200)
        assertTheLogoHeadsTheList(google: gf, mapbox: mf, closed: pixels(try block([]).0), what: "block")
    }

    /// The logo in dark appearance is a different variant (white), not the light one drawn dark.
    func testTheLogoHasADarkVariant() {
        let light = pixels(GoogleMapsLogoView(backdrop: .plain(hex: nil)), dark: false)
        let dark = pixels(GoogleMapsLogoView(backdrop: .plain(hex: nil)), dark: true)
        XCTAssertGreaterThan(inked(light), 50, "the light logo drew")
        // On black, a white logo leaves light pixels behind.
        var lightOnDark = 0
        for i in stride(from: 0, to: dark.px.count, by: 4) where dark.px[i] > 200 && dark.px[i + 1] > 200 && dark.px[i + 2] > 200 { lightOnDark += 1 }
        XCTAssertGreaterThan(lightOnDark, 50, "the dark appearance draws the white variant")
    }

    // MARK: after the tap

    /// A field holding a Google answer keeps the logo beside it once the dropdown is closed (after the
    /// tap, and on a restore); the same line from Mapbox, or a legacy answer, keeps none.
    /// RED CONTROL: the field's attribution removed → the Google and Mapbox frames are equal.
    func testAFieldHoldingAGoogleAnswerKeepsTheLogo() {
        func field(_ answer: [String: Any]) -> AnyView {
            let field = FormField.synthetic(id: "home", type: .location)
            return AnyView(LocationFieldView(field: field, value: .constant(answer as Any?), apiClient: nil).padding(16))
        }
        let g = pixels(field(GoogleAttributionData.google))
        let m = pixels(field(GoogleAttributionData.mapboxSameText))
        let l = pixels(field(GoogleAttributionData.legacy))
        XCTAssertGreaterThan(inked(m), 200, "the field drew")
        XCTAssertEqual(diff(m, l).count, 0, "a Mapbox and a legacy answer draw the same field")
        let d = diff(g, m)
        print("[google-logo] field after tap: \(d.count) px differ, rows \(d.minRow)–\(d.maxRow)")
        XCTAssertGreaterThan(d.count, 200, "a Google answer keeps Google's logo beside the field")
    }

    // MARK: the step's credit

    private func router(_ stepJSON: String, answer: [String: Any]) throws -> AnyView {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(stepJSON.utf8))
        SessionDataStore.shared.setOnboardingResponses(["places": ["home": answer]])
        return AnyView(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {},
                                            accumulatedResponses: ["places": ["home": answer]]))
    }

    /// Each step renders through the REAL step view — a legacy welcome heading, a legacy form title, a
    /// legacy question option and a content block — with a Google answer and then a Mapbox answer
    /// whose text is identical. Only the Google one draws the credit, below the step's content.
    func testAStepTemplatingAGoogleAnswerDrawsTheCredit() throws {
        let steps = [
            ("welcome_heading", #"{"id":"w","type":"welcome","config":{"title":"Hello from {{onboarding.places.home.city}}","cta_text":"Start"}}"#),
            ("form_title", #"{"id":"f","type":"form","config":{"title":"Home: {{onboarding.places.home.city}}","fields":[{"id":"n","type":"text","label":"Nick","required":false}]}}"#),
            ("question_option", #"{"id":"q","type":"question","config":{"title":"Where next?","options":[{"id":"s","label":"Stay in {{onboarding.places.home.city}}"},{"id":"g","label":"Elsewhere"}]}}"#),
            ("content_block", #"{"id":"c","type":"custom","config":{"content_blocks":[{"id":"t","type":"text","text":"Welcome from {{responses.places.home.city}}"}]}}"#),
        ]
        for (name, json) in steps {
            let g = pixels(try router(json, answer: GoogleAttributionData.google))
            let m = pixels(try router(json, answer: GoogleAttributionData.mapboxSameText))
            let m2 = pixels(try router(json, answer: GoogleAttributionData.mapboxSameText))
            XCTAssertGreaterThan(inked(m), 200, "[\(name)] the step drew")
            XCTAssertEqual(diff(m, m2).count, 0, "[\(name)] control: the same input renders the same frame")
            let d = diff(g, m)
            print("[google-credit] \(name): \(d.count) px differ, rows \(d.minRow)–\(d.maxRow) of \(g.h)")
            XCTAssertGreaterThan(d.count, 100, "[\(name)] the credit is drawn for a Google answer")
            // The credit sits BELOW the step's content: the change reaches the bottom of the frame.
            XCTAssertGreaterThan(d.maxRow, g.h * 85 / 100, "[\(name)] the credit is at the bottom of the step")
        }
    }

    // MARK: what is behind a field

    private let darkStep: GoogleMapsAttribution.Backdrop = .plain(hex: "#0F172A")

    /// A field inside an option's sheet draws its logo on the SHEET, not on the step under it: the
    /// sheet renders the same frame whatever the step's background. RED CONTROL: a sheet that hands
    /// down nothing of its own lets the dark step's white logo reach the light sheet, and the frames
    /// differ.
    func testAFieldInASheetPicksItsLogoFromTheSheet() throws {
        let option = try JSONDecoder().decode(InputOption.self, from: Data(
            #"{"id":"tpl","label":"Stop","sheet_blocks":[{"id":"loc","type":"input_location","field_id":"home"}]}"#.utf8
        ))
        func sheet(_ answer: [String: Any], on backdrop: GoogleMapsAttribution.Backdrop) -> AnyView {
            AnyView(OptionBottomSheetView(option: option, onDismiss: {}, inputs: ["home": answer])
                .environment(\.googleAttributionBackdrop, backdrop))
        }
        let onDark = pixels(sheet(GoogleAttributionData.google, on: darkStep))
        let onLight = pixels(sheet(GoogleAttributionData.google, on: .plain(hex: nil)))
        let mapbox = pixels(sheet(GoogleAttributionData.mapboxSameText, on: darkStep))
        XCTAssertGreaterThan(inked(mapbox), 200, "the sheet drew its field")
        XCTAssertGreaterThan(diff(onDark, mapbox).count, 200, "control: the field in the sheet draws Google's logo")
        let d = diff(onDark, onLight)
        print("[google-logo] sheet field, dark vs light step: \(d.count) px differ, rows \(d.minRow)–\(d.maxRow)")
        XCTAssertEqual(d.count, 0, "the logo in a sheet is picked from the sheet, whatever the step draws")
    }

    /// A field inside a filled container draws its logo on the container's fill: the same container
    /// renders the same frame whatever the step's background. RED CONTROL: a block that hands down
    /// nothing of its own lets the dark step's white logo reach the white container.
    func testAFieldInAFilledContainerPicksItsLogoFromTheFill() throws {
        let stack = try JSONDecoder().decode(ContentBlock.self, from: Data(
            ##"{"id":"st","type":"stack","block_style":{"background_color":"#FFFFFF"},"height":160,"children":[{"id":"loc","type":"input_location","field_id":"home"}]}"##.utf8
        ))
        func container(_ answer: [String: Any], on backdrop: GoogleMapsAttribution.Backdrop) -> AnyView {
            AnyView(ContentBlockRendererView(blocks: [stack], onAction: { _, _ in }, toggleValues: .constant([:]),
                                             inputValues: .constant(["home": answer]))
                .padding(16)
                .environment(\.googleAttributionBackdrop, backdrop))
        }
        let onDark = pixels(container(GoogleAttributionData.google, on: darkStep))
        let onLight = pixels(container(GoogleAttributionData.google, on: .plain(hex: nil)))
        let mapbox = pixels(container(GoogleAttributionData.mapboxSameText, on: darkStep))
        XCTAssertGreaterThan(inked(mapbox), 200, "the container drew its field")
        XCTAssertGreaterThan(diff(onDark, mapbox).count, 200, "control: the field in the container draws Google's logo")
        let d = diff(onDark, onLight)
        print("[google-logo] container field, dark vs light step: \(d.count) px differ, rows \(d.minRow)–\(d.maxRow)")
        XCTAssertEqual(d.count, 0, "the logo in a filled container is picked from its fill, whatever the step draws")
    }
}

private extension FormField {
    static func synthetic(id: String, type: FormFieldType) -> FormField {
        let json = #"{"id":"\#(id)","type":"\#(type.rawValue)","label":"Home","required":false}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(FormField.self, from: Data(json.utf8))
    }
}
