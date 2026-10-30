// LocationLeaveWhileComposingTests.swift
//
// Leaving a location field while the input method is composing after Google's line: the twin
// of Android's `LocationFieldBlurComposingComposeTest`, on both surfaces — the form step's field and
// the `input_location` content block — each with a second text field to move to.
//
// Ending editing commits the marked text, and that commit is the first edit of Google's line: it
// restarts from the user's own text and starts a search. The leaving must still count: the other field
// keeps first responder, and the search the commit started never runs. On Android the field is drawn
// afresh on that restart and the new field took the focus back; here the field is kept and only its
// undo history is cleared, and `textFieldDidEndEditing` reports the leaving after the commit. The form
// step's field did not end its search on leaving at all — its focus flag was a `@FocusState` bound to no
// view, so it never changed — which these walks found; the plain typed case is walked too.
//
// Operated on the REAL step in a real key window (`HostedStep`), through the field's own marked-text
// calls and its own editingChanged action. A package test has no keyboard, so nothing commits the marked
// text when the field resigns (measured: it is still marked afterwards); the leave walk commits it with
// the field's own `unmarkText` in the same run-loop turn as the move, the order a device's keyboard uses.
// The network is stubbed (`GeocodeStallingProxy`, which
// answers every autocomplete with one row), so a search that ran is counted and would open the
// dropdown. The control in the same harness commits while STAYING in the field, and sees both.
// All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class LocationLeaveWhileComposingTests: XCTestCase {

    private let line = "Springfield, IL, USA"
    private var google: [String: Any] {
        ["formatted_address": line, "address": line, "city": "Springfield", "country": "United States",
         "country_code": "US", "latitude": 39.78, "longitude": -89.65, "raw_query": "Springf",
         "place_id": "ChIJ-synthetic-springfield"]
    }

    private let formStep =
        #"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false},{"id":"name","type":"text","label":"Name","required":false}]}}"#
    private let blockStep =
        #"{"id":"where","type":"custom","config":{"content_blocks":[{"id":"loc","type":"input_location","field_id":"home","field_config":{"location_min_chars":3}},{"id":"nm","type":"input_text","field_id":"name","field_config":{"label":"Name"}}]}}"#

    private var savedClient: APIClient?
    private var registered: LocationSuggestionSearch?

    override func setUp() {
        super.setUp()
        registered = nil
        LocationAdvanceSettlement.registeredForTesting = { [weak self] _, holder in self?.registered = holder }
        GeocodeStallingProxy.autocompleteCalls = 0
        GeocodeStallingProxy.resolveCalls = 0
        URLProtocol.registerClass(GeocodeStallingProxy.self)
        savedClient = AppDNA.apiClientForTesting
        AppDNA.apiClientForTesting = APIClient(apiKey: "synthetic-key", environment: .production)
    }

    override func tearDown() {
        LocationAdvanceSettlement.registeredForTesting = nil
        AppDNA.apiClientForTesting = savedClient
        URLProtocol.unregisterClass(GeocodeStallingProxy.self)
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func textFields(in view: UIView) -> [UITextField] {
        if let tf = view as? UITextField { return [tf] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private func editingChanged(_ tf: UITextField) {
        // A package test runs with no UIApplication, so `sendActions` dispatches nothing: the field's
        // own editingChanged targets are invoked directly instead.
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
    }

    /// Shows the step with a Google answer, focuses the location field and composes "x" after the line.
    /// Returns the step, the location field and the other field.
    private func composeAfterGooglesLine(_ json: String) throws -> (HostedStep, UITextField, UITextField)? {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {}, savedResponses: ["home": google]))
        XCTAssertTrue(hosted.wait { self.textFields(in: hosted.host.view).contains { $0.text == self.line } },
                      "the location field restored Google's line")
        let fields = textFields(in: hosted.host.view)
        guard let location = fields.first(where: { $0.text == line }),
              let other = fields.first(where: { $0 !== location }) else {
            XCTFail("expected a location field and a second field; found \(fields.count) fields")
            hosted.close()
            return nil
        }
        location.becomeFirstResponder()
        hosted.spin(0.1)
        XCTAssertTrue(location.isFirstResponder, "control: the location field took first responder")
        location.selectedTextRange = location.textRange(from: location.endOfDocument, to: location.endOfDocument)
        hosted.spin(0.1)
        location.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(location.markedTextRange, "control: the harness can compose marked text")
        editingChanged(location)
        hosted.spin(0.2)
        XCTAssertEqual(location.text, line + "x", "while composing, Google's line with the marked text is shown")
        XCTAssertEqual(GeocodeStallingProxy.autocompleteCalls, 0, "nothing is searched while composing on Google's line")
        return (hosted, location, other)
    }

    private func leaveWhileComposing(_ json: String) throws {
        guard let (hosted, location, other) = try composeAfterGooglesLine(json) else { return }
        defer { hosted.close() }
        // Tapping the other field. On a device the keyboard commits the marked text as the field resigns,
        // before `textFieldDidEndEditing`; a package test has no keyboard to do that, so the commit is
        // made here, in the same run-loop turn as the move, through the field's own `unmarkText`.
        location.unmarkText()
        other.becomeFirstResponder()
        // Past the debounce, and past the form step's 0.15 s leave delay.
        hosted.spin(1.0)
        let state = "otherFirstResponder=\(other.isFirstResponder) locationFirstResponder=\(location.isFirstResponder) " +
            "autocompleteCalls=\(GeocodeStallingProxy.autocompleteCalls) dropdown=\(registered?.isDropdownOpen ?? false)"
        XCTAssertEqual(
            state,
            "otherFirstResponder=true locationFirstResponder=false autocompleteCalls=0 dropdown=false",
            "the other field keeps first responder, and no search runs or opens a dropdown after the user left; " +
                "the location field shows \(location.text ?? "nil")"
        )
        XCTAssertNotNil(registered, "control: the field's holder registered, so the dropdown reading is real")
        XCTAssertNil(location.markedTextRange, "the marked text was committed as the field was left")
        XCTAssertEqual(location.text, "Springfx",
                       "the commit was the first edit of Google's line, restarted from the user's own text")
    }

    /// Control: the composition commits while the user STAYS in the field. The restart searches the
    /// user's own text and opens the dropdown, and the field keeps first responder.
    private func commitAndStay(_ json: String) throws {
        guard let (hosted, location, other) = try composeAfterGooglesLine(json) else { return }
        defer { hosted.close() }
        location.unmarkText()
        XCTAssertTrue(hosted.wait { GeocodeStallingProxy.autocompleteCalls == 1 && self.registered?.isDropdownOpen == true },
                      "staying in the field searches and opens the dropdown (calls \(GeocodeStallingProxy.autocompleteCalls))")
        XCTAssertEqual(location.text, "Springfx", "the commit restarted from the user's own text")
        XCTAssertTrue(location.isFirstResponder, "the location field keeps first responder")
        XCTAssertFalse(other.isFirstResponder)
    }

    /// The plain case, with no composition: typing, then leaving before the debounce fires. No search
    /// runs and no dropdown opens. Then, as the control in the same step, typing again WITHOUT leaving:
    /// the search runs and the dropdown opens, so the harness sees both when they happen.
    private func typeThenLeaveBeforeTheDebounce(_ json: String) throws {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {}))
        defer { hosted.close() }
        let fields = textFields(in: hosted.host.view)
        guard fields.count == 2 else { return XCTFail("expected the location field and a second field; found \(fields.count)") }
        let (location, other) = (fields[0], fields[1])
        location.becomeFirstResponder()
        hosted.spin(0.1)
        location.text = "Springf"
        editingChanged(location)
        other.becomeFirstResponder()
        hosted.spin(1.0)
        let state = "otherFirstResponder=\(other.isFirstResponder) locationFirstResponder=\(location.isFirstResponder) " +
            "autocompleteCalls=\(GeocodeStallingProxy.autocompleteCalls) dropdown=\(registered?.isDropdownOpen ?? false)"
        XCTAssertEqual(
            state,
            "otherFirstResponder=true locationFirstResponder=false autocompleteCalls=0 dropdown=false",
            "a search still pending when the user left the field never runs"
        )

        location.becomeFirstResponder()
        hosted.spin(0.1)
        location.text = "Springfi"
        editingChanged(location)
        XCTAssertTrue(hosted.wait { GeocodeStallingProxy.autocompleteCalls == 1 && self.registered?.isDropdownOpen == true },
                      "control: staying in the field searches and opens the dropdown")
    }

    func testTheFormStepLeftBeforeTheDebounceRunsNoSearch() throws {
        try typeThenLeaveBeforeTheDebounce(formStep)
    }

    func testTheBlockLeftBeforeTheDebounceRunsNoSearch() throws {
        try typeThenLeaveBeforeTheDebounce(blockStep)
    }

    func testTheFormStepLeftWhileComposingAfterGooglesLineRunsNoSearch() throws {
        try leaveWhileComposing(formStep)
    }

    func testTheBlockLeftWhileComposingAfterGooglesLineRunsNoSearch() throws {
        try leaveWhileComposing(blockStep)
    }

    func testControlTheFormStepSearchesWhenTheCompositionCommitsInTheField() throws {
        try commitAndStay(formStep)
    }

    func testControlTheBlockSearchesWhenTheCompositionCommitsInTheField() throws {
        try commitAndStay(blockStep)
    }
}
