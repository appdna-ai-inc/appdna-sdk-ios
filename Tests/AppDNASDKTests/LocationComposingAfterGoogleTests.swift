// LocationComposingAfterGoogleTests.swift
//
// The first edit after a Google answer's line, still composing (marked text from an input method that
// composes, as Japanese and Chinese keyboards do), is the user's own text the moment the step moves
// on: Continue submits it, instead of the Google answer the field showed. The restart rule applies:
// Google's line is never submitted; the answer is the user's query plus the edit. The Kotlin twin is
// `LocationComposingAfterGoogleTest`.
//
// Operated on the REAL form step and the REAL `input_location` block in a key window: the field
// restores a Google answer, marked text goes in through the field's own `setMarkedText`, and Continue
// is a real tap. The control taps Continue with no edit and gets the Google answer back unchanged.
// All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class LocationComposingAfterGoogleTests: XCTestCase {

    private let line = "Springfield, IL, USA"
    private var google: [String: Any] {
        ["formatted_address": line, "address": line, "city": "Springfield", "country": "United States",
         "country_code": "US", "latitude": 39.78, "longitude": -89.65, "raw_query": "Springf",
         "place_id": "ChIJ-synthetic-springfield"]
    }

    private let formStep =
        #"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false}]}}"#
    private let blockStep =
        #"{"id":"where","type":"custom","config":{"content_blocks":[{"id":"loc","type":"input_location","field_id":"home","zone":"bottom"},{"id":"go","type":"button","text":"Continue","action":"next","zone":"bottom"}]}}"#

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func textField(in view: UIView) -> UITextField? {
        if let tf = view as? UITextField { return tf }
        for s in view.subviews { if let f = textField(in: s) { return f } }
        return nil
    }

    /// Restores the Google answer, optionally composes a character after its line, taps Continue, and
    /// returns what the step handed on for the field.
    private func submitted(_ stepJSON: String, compose: Bool) throws -> Any? {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(stepJSON.utf8))
        var payloads: [[String: Any]?] = []
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { payloads.append($0) }, onSkip: {}, savedResponses: ["home": google]))
        defer { hosted.close() }
        guard let tf = textField(in: hosted.host.view) else { XCTFail("no text field"); return nil }
        XCTAssertTrue(hosted.wait { tf.text == self.line }, "the field restored Google's line; it shows \(tf.text ?? "nil")")
        if compose {
            tf.becomeFirstResponder()
            hosted.spin(0.1)
            tf.selectedTextRange = tf.textRange(from: tf.endOfDocument, to: tf.endOfDocument)
            hosted.spin(0.1)
            tf.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertNotNil(tf.markedTextRange, "control: the harness composes marked text")
            for target in tf.allTargets {
                for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                    _ = (target as NSObject).perform(Selector(action), with: tf)
                }
            }
            hosted.spin(0.2)
            XCTAssertEqual(tf.text, line + "\u{306B}", "while composing, Google's line with the marked text is shown")
        }
        hosted.tap("Continue") { $0 == "Continue" }
        XCTAssertTrue(hosted.wait { !payloads.isEmpty }, "Continue advanced the step")
        return payloads.first??["home"]
    }

    func testContinueOnTheFormStepSubmitsTheComposingEditAfterAGoogleLine() throws {
        XCTAssertEqual(try submitted(formStep, compose: true) as? String, "Springf\u{306B}")
    }

    func testContinueOnTheBlockSubmitsTheComposingEditAfterAGoogleLine() throws {
        XCTAssertEqual(try submitted(blockStep, compose: true) as? String, "Springf\u{306B}")
    }

    /// Control: Continue with no edit hands on the Google answer as it is.
    func testContinueWithoutAnEditSubmitsTheGoogleAnswer() throws {
        let answer = try submitted(blockStep, compose: false) as? [String: Any]
        XCTAssertEqual(answer?["formatted_address"] as? String, line)
    }
}
