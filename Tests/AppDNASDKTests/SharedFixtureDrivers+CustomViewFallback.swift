import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_custom_view_fallback REAL: the lenient `[ContentBlock]` decode → `CustomViewFallback.resolve`.
    func runCustomViewFallback(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_custom_view_fallback needs action.cases")
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
            let registered = (obj["registered"]?.foundation as? Bool) ?? false
            let debug = (obj["debug"]?.foundation as? Bool) ?? false
            return CustomViewFallback.resolve(
                viewKey: block.view_key, registered: registered,
                placeholderImageUrl: block.placeholder_image_url, placeholderText: block.placeholder_text, debug: debug)
        }
    }
}
