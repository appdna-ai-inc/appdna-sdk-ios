// GoogleSheetCreditRenderTests.swift
//
// An option sheet draws its own Google credit when its text shows a pick whose label came from a
// Google answer, and the pick that counts is the one made when the sheet draws — the pick that opened
// it — not whatever was picked when the step last drew.
//
// Drawn through the REAL sheet view (`OptionBottomSheetView`) in a real key window, with the context
// the onboarding step hands its sheets (`GoogleCreditSheetContext.live`), and read off the drawn
// accessibility tree. The step's own presentation of the sheet is not driven here: a package test has
// no UIApplication to run a presentation, so a presented sheet is never installed in a window and
// draws nothing to read (`DropdownOptionSheetTests`). The sheet view is therefore hosted directly,
// as the presentation would host it.
//
// All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class GoogleSheetCreditRenderTests: XCTestCase {

    override func tearDown() {
        SelectedOptionStore.shared.resetForTesting()
        super.tearDown()
    }

    private let stepJSON = """
    {"id":"s","type":"custom","config":{"content_blocks":[{"id":"sel","type":"input_select","field_id":"stop",
      "field_config":{"display_style":"list"},"field_options":[
        {"id":"home","label":"{{responses.places.home.city}}","value":"home",
         "sheet_blocks":[{"id":"sh","type":"text","text":"You chose {{selected.stop.label}}"}]},
        {"id":"far","label":"Far away","value":"far"}]}]}}
    """

    private func credits(_ hosted: HostedStep) -> Int {
        hosted.labels().filter { $0 == GoogleMapsAttribution.label }.count
    }

    /// RED CONTROL: a context whose picks are the ones held when it was built (`answers.selected`, as
    /// `.live` would give without its `selected` reader) draws no credit in the sheet.
    func testASheetDrawsTheCreditOfThePickThatOpenedIt() throws {
        SelectedOptionStore.shared.resetForTesting()
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(stepJSON.utf8))
        let sources = GoogleCredit.stepSources(step: step, override: nil, fieldConfigOverrides: [:], fieldOptionsOverrides: [:])
        let answers = GoogleCredit.Answers(
            accumulated: ["places": ["home": GoogleAttributionData.google]], stepInputs: [:], sessionStore: [:],
            selected: SelectedOptionStore.shared.snapshot
        )
        // Built when the step drew: nothing was picked yet.
        let live = GoogleCreditSheetContext.live(index: { GoogleCredit.sheetSources(in: sources) }, answers: answers)
        let frozen = GoogleCreditSheetContext(index: { GoogleCredit.sheetSources(in: sources) }, answers: answers)

        // The pick that opens the sheet: the option as the step drew it, its label a Google city.
        var option = try JSONDecoder().decode(InputOption.self, from: Data(
            #"{"id":"home","label":"Springfield","value":"home","sheet_blocks":[{"id":"sh","type":"text","text":"You chose {{selected.stop.label}}"}]}"#.utf8
        ))
        option.googleKeys = ["label": "Springf"]
        SelectedOptionStore.shared.record(fieldId: "stop", option: option)

        func host(_ context: GoogleCreditSheetContext) -> HostedStep {
            HostedStep(OptionBottomSheetView(option: option, onDismiss: {}, blockId: "sel")
                .environment(\.googleCreditSheetContext, context))
        }

        let drawn = host(live)
        defer { drawn.close() }
        XCTAssertTrue(drawn.wait { self.credits(drawn) == 1 },
                      "the sheet draws its own credit for the pick that opened it; labels \(drawn.labels())")

        let stale = host(frozen)
        defer { stale.close() }
        stale.spin(0.5)
        XCTAssertEqual(credits(stale), 0, "control: a context holding only the picks it was built with draws none")
    }
}
