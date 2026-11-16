import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_text_input_border REAL: the `FormFieldBlockStyle` decode → the core `textInputBorderHex`, the rule
    // `FormInputTextBlock` strokes its border with.
    func runTextInputBorder(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_text_input_border needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            var style: FormFieldBlockStyle?
            if let raw = o["style"]?.foundation as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: raw) {
                style = try? JSONDecoder().decode(FormFieldBlockStyle.self, from: data)
                if style == nil { XCTFail("[\(f.id)] case \(o["name"]?.stringValue ?? "?"): the style did not decode") }
            }
            return textInputBorderHex(style, focused: o["focused"]?.boolValue ?? false, hasError: o["has_error"]?.boolValue ?? false)
        }
    }
}
