// LocationReturnKeyTests.swift
//
// The keyboard's return key (labelled Search) in a location field leaves the field: the suggestion
// dropdown closes, the keyboard goes away, and the typed text stays. The Android twin is
// `LocationFieldSearchKeyComposeTest`; the two pin the same behaviour.
//
// On each REAL surface, in a real key window: the form step's field and the `input_location` block.
// The autocomplete is stubbed (`GeocodeStallingProxy`, one synthetic row), the dropdown is shown open
// first (the control that the harness sees it), and return is pressed through the text field's own
// delegate, as UIKit calls it.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class LocationReturnKeyTests: XCTestCase {

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

    private func textField(in view: UIView) -> UITextField? {
        if let tf = view as? UITextField { return tf }
        for s in view.subviews { if let f = textField(in: s) { return f } }
        return nil
    }

    private func walk(_ json: String) throws {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {}))
        defer { hosted.close() }
        guard let tf = textField(in: hosted.host.view) else { return XCTFail("no text field") }
        XCTAssertEqual(tf.returnKeyType, .search, "the field's key is Search")
        _ = tf.becomeFirstResponder()
        hosted.spin(0.2)
        hosted.type("Springf")
        XCTAssertTrue(hosted.wait { self.registered?.isDropdownOpen == true },
                      "control: typing opens the dropdown, and the harness sees it")
        XCTAssertTrue(tf.isFirstResponder, "control: the field holds the keyboard")

        _ = tf.delegate?.textFieldShouldReturn?(tf)
        hosted.spin(0.5)

        XCTAssertFalse(tf.isFirstResponder, "return leaves the field and the keyboard goes away")
        XCTAssertEqual(registered?.isDropdownOpen, false, "return closes the dropdown")
        XCTAssertEqual(tf.text, "Springf", "the typed text stays")
        let calls = GeocodeStallingProxy.autocompleteCalls
        hosted.spin(1.0)
        XCTAssertEqual(registered?.isDropdownOpen, false, "nothing reopens it")
        XCTAssertEqual(GeocodeStallingProxy.autocompleteCalls, calls, "no search runs after leaving")
    }

    func testTheFormStepsReturnKeyClosesTheDropdownAndTheKeyboard() throws {
        try walk(#"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false}]}}"#)
    }

    func testTheBlocksReturnKeyClosesTheDropdownAndTheKeyboard() throws {
        try walk(#"{"id":"where","type":"custom","config":{"content_blocks":[{"id":"loc","type":"input_location","field_id":"home","zone":"bottom"}]}}"#)
    }
}
