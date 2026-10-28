// LocationEditUndoTests.swift
//
// After a location field showing a Google answer's line restarts from the user's own text, the field's
// text is set by the app, not typed. Shake-to-undo must not replay the typing recorded before that set
// and bring Google's line back into a field that now stores typed text. Measured on the iOS 26
// simulator, UIKit drops a text field's whole undo history when its text is set programmatically; the
// location fields also clear it themselves on every such set (`clearsUndoOnProgrammaticSet`), so the
// guarantee does not rest on that UIKit behaviour holding on every iOS version.
//
// Operated on the REAL form step in a real key window (`HostedStep`): the field restores a Google
// answer, the user's typing is stood for by an undo action on the field's own undo manager, and a
// keystroke appended to Google's line goes through the field's own editingChanged action.
// All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class LocationEditUndoTests: XCTestCase {

    private let line = "Springfield, IL, USA"
    private var google: [String: Any] {
        ["formatted_address": line, "address": line, "city": "Springfield", "country": "United States",
         "country_code": "US", "latitude": 39.78, "longitude": -89.65, "raw_query": "Springf",
         "place_id": "ChIJ-synthetic-springfield"]
    }

    private func textField(in view: UIView) -> UITextField? {
        if let tf = view as? UITextField { return tf }
        for s in view.subviews { if let f = textField(in: s) { return f } }
        return nil
    }

    /// The end state, through the real view: nothing can be undone after the rewrite. (Disabling the
    /// field's own clearing does not turn this red on the iOS 26 simulator, because UIKit's set clears
    /// the history too; `testAProgrammaticSetClearsTheHistoryOnlyWhenItSets` proves the clearing itself.)
    func testTheRestartLeavesNothingToUndo() throws {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            #"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false}]}}"#.utf8
        ))
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {}, savedResponses: ["home": google]))
        defer { hosted.close() }
        guard let tf = textField(in: hosted.host.view) else { return XCTFail("no text field") }
        XCTAssertTrue(hosted.wait { tf.text == self.line }, "the field restored Google's line; it shows \(tf.text ?? "nil")")

        tf.becomeFirstResponder()
        hosted.spin(0.1)
        guard let undo = tf.undoManager else { return XCTFail("the field has no undo manager") }
        // The user's typing, as an undo action on the field's undo manager: undoing it would put
        // Google's line back.
        let typing = NSObject()
        undo.registerUndo(withTarget: typing) { [line, weak tf] _ in tf?.text = line }
        hosted.spin(0.1) // the event's undo group closes with the run loop pass
        XCTAssertTrue(undo.canUndo, "control: the harness can see an undo action")

        hosted.type(line + "i")
        XCTAssertTrue(hosted.wait { tf.text == "Springfi" }, "the edit restarted from the typed text; the field shows \(tf.text ?? "nil")")
        XCTAssertFalse(undo.canUndo, "after the rewrite nothing can be undone")
    }

    /// An input method commits its marked text without changing the text. No `editingChanged` arrives
    /// for that (and a package test dispatches none anyway), so the first edit of Google's line held
    /// back while composing must still be applied: the field reports the commit itself. Driven through
    /// the real field's own marked-text calls; nothing here calls `compositionChanged`.
    func testACommitThatLeavesTheTextUnchangedAppliesTheHeldBackEdit() throws {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            #"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false}]}}"#.utf8
        ))
        let hosted = HostedStep(OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {}, savedResponses: ["home": google]))
        defer { hosted.close() }
        guard let tf = textField(in: hosted.host.view) else { return XCTFail("no text field") }
        XCTAssertTrue(hosted.wait { tf.text == self.line }, "the field restored Google's line; it shows \(tf.text ?? "nil")")
        tf.becomeFirstResponder()
        hosted.spin(0.1)
        tf.selectedTextRange = tf.textRange(from: tf.endOfDocument, to: tf.endOfDocument)
        hosted.spin(0.1)

        // A keystroke the input method composes: the marked text, then the field's own editingChanged.
        tf.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(tf.markedTextRange, "control: the harness can compose marked text")
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
        hosted.spin(0.2)
        XCTAssertEqual(tf.text, line + "\u{306B}", "while composing, Google's line with the marked text is shown and nothing restarts")

        // The commit: no text change, no editingChanged.
        tf.unmarkText()
        XCTAssertNil(tf.markedTextRange)
        XCTAssertTrue(
            hosted.wait { tf.text == "Springf\u{306B}" },
            "the commit applied the held-back edit from the user's own text; the field shows \(tf.text ?? "nil")"
        )
    }

    /// The set itself: only a text that differs is set, and only then is the history cleared.
    func testAProgrammaticSetClearsTheHistoryOnlyWhenItSets() {
        final class Field: UITextField {
            let history: UndoManager = {
                let u = UndoManager()
                u.groupsByEvent = false
                return u
            }()
            override var undoManager: UndoManager? { history }
        }
        let tf = Field()
        tf.text = "Springfi"
        tf.history.beginUndoGrouping()
        tf.history.registerUndo(withTarget: tf) { $0.text = "x" }
        tf.history.endUndoGrouping()
        UIKitTextField.setText("Springfi", of: tf, clearingUndo: true)
        XCTAssertTrue(tf.history.canUndo, "an unchanged text is not set, and the history stays")
        UIKitTextField.setText("Springf", of: tf, clearingUndo: false)
        XCTAssertTrue(tf.history.canUndo, "control: a set that does not clear keeps the history")
        UIKitTextField.setText("Spring", of: tf, clearingUndo: true)
        XCTAssertFalse(tf.history.canUndo)
        XCTAssertEqual(tf.text, "Spring")
    }
}
