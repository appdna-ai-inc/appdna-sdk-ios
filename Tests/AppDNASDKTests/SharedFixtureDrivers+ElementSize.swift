import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_element_size REAL: the `ContentBlock` decode (`lenientSize`) → the size grammar `SizeValue.parse`, the
    // two steps `RelativeSizingModifier` draws a block's width and height from.
    func runElementSize(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_element_size needs action.cases")
            return
        }
        func formatNumber(_ d: Double) -> String {
            let r = (d * 1000).rounded() / 1000
            return r.rounded() == r ? String(Int(r)) : String(r)
        }
        func describe(_ v: SizeValue?) -> String {
            switch v {
            case .fill: return "fill"
            case .auto_: return "auto"
            case .percent(let p): return "percent:\(formatNumber(Double(p)))"
            case .px(let p): return "px:\(formatNumber(Double(p)))"
            case nil: return "none"
            }
        }
        h.state["results"] = cases.map { c -> Any in
            var raw: [String: Any] = ["id": "b", "type": "text", "text": "x"]
            for k in ["element_width", "element_height"] { if let v = c.objectValue?[k]?.foundation { raw[k] = v } }
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
                XCTFail("[\(f.id)] case \(c.objectValue?["name"]?.stringValue ?? "?") did not decode")
                return NSNull()
            }
            return [describe(SizeValue.parse(block.element_width)), describe(SizeValue.parse(block.element_height))]
        }
    }
}
