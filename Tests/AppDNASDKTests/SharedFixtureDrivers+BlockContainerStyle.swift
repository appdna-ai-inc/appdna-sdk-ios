import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_block_container_style REAL: the lenient `[ContentBlock]` decode → `BlockContainerStyle.resolve`, which
    // every block's container style is drawn from, nested blocks included. NSNull when nothing is drawn.
    func runBlockContainerStyle(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_block_container_style needs action.cases")
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
            guard let st = BlockContainerStyle.resolve(block.field_config) else { return NSNull() }
            let border = st.borderWidth.map { "\(Int($0))@\(st.borderHex ?? "")" } ?? "none"
            return "fill=\(st.fillHex ?? "none") opacity=\(String(format: "%.1f", st.opacity)) blur=\(st.blur) border=\(border) radius=\(Int(st.cornerRadius))"
        }
    }
}
