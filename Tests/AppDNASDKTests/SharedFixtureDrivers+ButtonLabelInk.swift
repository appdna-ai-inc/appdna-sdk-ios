import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_button_label_ink REAL: the lenient `[ContentBlock]` decode → `ButtonLabelColour.label`, the
    // colour the button's label is drawn in. The fill is the block's `bg_color`, else the default accent
    // (the runner sets no brand accent), as the renderer computes it with no CTA-state colours.
    func runButtonLabelInk(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_button_label_ink needs action.cases")
            return
        }
        struct Holder: Decodable {
            let content_blocks: [ContentBlock]?
            enum CodingKeys: String, CodingKey { case content_blocks }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "fixture")
            }
        }
        h.state["results"] = cases.map { c -> Any in
            guard let raw = c.objectValue?["block"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [raw]]),
                  let block = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks?.first else {
                XCTFail("[\(f.id)] a case did not decode")
                return NSNull()
            }
            return ButtonLabelColour.label(
                textColor: block.text_color, styleColor: block.style?.color,
                variant: block.variant ?? "primary", fillHex: block.bg_color ?? "#6366F1")
        }
    }
}
