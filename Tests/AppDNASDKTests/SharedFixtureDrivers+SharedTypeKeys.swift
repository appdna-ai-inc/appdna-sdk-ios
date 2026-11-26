import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // decode_shared_type_keys REAL: the `ContentBlock` decode for a block case, and the whole `PaywallConfig` decode
    // (with `layout.sections` as the console publishes it) for a section case, so a section that a field makes throw
    // shows up as `section_kept: false` rather than as a nil field.
    func runSharedTypeKeys(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] decode_shared_type_keys needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let name = c.objectValue?["name"]?.stringValue ?? "?"
            if let raw = c.objectValue?["block"]?.foundation {
                guard let data = try? JSONSerialization.data(withJSONObject: raw),
                      let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
                    XCTFail("[\(f.id)] case \(name): the block did not decode")
                    return NSNull()
                }
                return [
                    "lottie_speed": SharedFixtureTests.orNull(block.lottie_speed),
                    "speed": SharedFixtureTests.orNull(block.speed),
                ] as [String: Any]
            }
            guard let section = c.objectValue?["section"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] case \(name) has neither block nor section")
                return NSNull()
            }
            let doc: [String: Any] = ["id": "pw_fixture", "name": "Fixture", "layout": ["type": "stack", "sections": [section]]]
            guard let data = try? JSONSerialization.data(withJSONObject: doc),
                  let paywall = try? JSONDecoder().decode(PaywallConfig.self, from: data) else {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode")
                return NSNull()
            }
            let kept = paywall.sections.first { $0.id == section["id"] as? String }
            let d = kept?.data
            // The two readers the renderer uses: the icon grid's count and the comparison table's header row.
            let columnCount = d?.columns?.value as? Int
            let labels = PaywallTableColumns.resolve(structured: d?.tableColumns, fallback: d?.columns?.value).labels
            return [
                "section_kept": kept != nil,
                "column_count": SharedFixtureTests.orNull(columnCount),
                "table_column_labels": labels,
                "rating": SharedFixtureTests.orNull(d?.rating),
                "review_count": SharedFixtureTests.orNull(d?.reviewCount),
            ] as [String: Any]
        }
    }
}
