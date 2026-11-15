// TextInputAccessibilityNameTests.swift
//
// A text input is named for VoiceOver: its label, else its placeholder. The label is drawn as a separate text above the
// field, so before this the field itself was an unnamed text field on every typed-answer step.
//
// The real views are rendered in a key window and their accessibility tree is read. A text input is an element that
// takes text entry: a `UITextField` / `UITextView`, or the element SwiftUI publishes for one (the text-entry trait).
// THE CONTROL: each test first finds the inputs at all, so an empty tree cannot pass.

import XCTest
import SwiftUI
@testable import AppDNASDK

@MainActor
final class TextInputAccessibilityNameTests: SurfaceInkTestCase {

    /// UIKit's text-entry trait (`UIAccessibilityTraitTextEntry`), which VoiceOver reads as "text field".
    private static let textEntry = UIAccessibilityTraits(rawValue: 1 << 18)

    /// The names VoiceOver reads for the text inputs under `roots`. A UIKit field whose SwiftUI element carries the name
    /// counts once, by that element.
    static func inputNames(_ roots: [NSObject]) -> [String] {
        let tree = A11yTree.raw(roots)
        let swiftUIInputs = tree.filter { !($0 is UIView) && $0.accessibilityTraits.contains(textEntry) }
        if !swiftUIInputs.isEmpty { return swiftUIInputs.map { $0.accessibilityLabel ?? "" } }
        return tree.compactMap { o in (o is UITextField || o is UITextView) ? (o.accessibilityLabel ?? "") : nil }
    }

    func testEachTextInputBlockCarriesItsLabelElseItsPlaceholder() throws {
        let blocks = [
            #"{"id":"b_num","type":"input_number","field_id":"amount","field_label":"Monthly savings goal"}"#,
            #"{"id":"b_txt","type":"input_text","field_id":"name","field_label":"Your first name","field_placeholder":"Type it here"}"#,
            #"{"id":"b_mail","type":"input_email","field_id":"mail","field_placeholder":"Email address"}"#,
            #"{"id":"b_area","type":"input_textarea","field_id":"note","field_label":"Anything else"}"#,
        ].joined(separator: ",")
        _ = try render(flow(background: Self.white, blocksJSON: blocks),
                       elements: ["Monthly savings goal", "Your first name", "Anything else"], appearance: .light)
        let names = Self.inputNames([try XCTUnwrap(lastWindow)])
        XCTAssertEqual(names.count, 4, "control: four text inputs are found: \(names)")
        XCTAssertEqual(Set(names), ["Monthly savings goal", "Your first name", "Email address", "Anything else"],
                       "every text input is named by its label, else its placeholder: \(names)")
    }

    func testALegacyFormStepNamesItsFields() throws {
        let config = try JSONDecoder().decode(StepConfig.self, from: Data((#"{"fields":["#
            + #"{"id":"f_name","type":"text","label":"Preferred name","required":false},"#
            + #"{"id":"f_age","type":"number","label":"Age in years","required":false},"#
            + #"{"id":"f_bio","type":"textarea","label":"A line about you","required":false}"#
            + #"]}"#).utf8))
        let step = HostedStep(FormStepView(config: config, onNext: { _ in }, apiClient: nil, savedValues: nil))
        defer { step.close() }
        _ = step.wait { Self.inputNames([step.host.view]).count >= 3 }
        let names = Self.inputNames([step.host.view])
        XCTAssertEqual(names.count, 3, "control: three text inputs are found: \(names)\(step.treeDiagnosis())")
        XCTAssertEqual(Set(names), ["Preferred name", "Age in years", "A line about you"],
                       "every legacy form field is named by its label: \(names)")
    }
}
