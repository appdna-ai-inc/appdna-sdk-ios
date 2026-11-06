import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_dropdown_field_ink REAL: the lenient `[ContentBlock]` decode → `DropdownFieldInk.light`, which the
    // dropdown Select's field draws its ink from.
    func runDropdownFieldInk(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_dropdown_field_ink needs action.cases")
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
            let obj = c.objectValue ?? [:]
            guard let raw = obj["block"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [raw]]),
                  let block = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks?.first else {
                XCTFail("[\(f.id)] a case did not decode")
                return NSNull()
            }
            return DropdownFieldInk.light(
                fieldBackground: block.field_style?.background_color,
                behind: .plain(hex: obj["backdrop"]?.foundation as? String),
                darkAppearance: (obj["dark_appearance"]?.foundation as? Bool) ?? false)
        }
    }
}
