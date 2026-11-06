import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_row_fill REAL: the lenient `[ContentBlock]` decode → `RowFill.resolve`, which both row
    // renderers draw their fill from. "<hex>@<opacity>" per case, NSNull for no fill.
    func runRowFill(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_row_fill needs action.cases")
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
            guard let fill = RowFill.resolve(block.field_config) else { return NSNull() }
            return "\(fill.hex)@\(String(format: "%.1f", fill.opacity))"
        }
    }
}
