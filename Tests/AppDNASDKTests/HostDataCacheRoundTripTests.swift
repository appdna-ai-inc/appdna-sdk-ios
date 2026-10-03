import XCTest
@testable import AppDNASDK

/// "iOS cache round trip" (`ios_cache_round_trip_keeps_raw`).
///
/// iOS rewrites its onboarding cache by encoding the TYPED `OnboardingFlowConfig`, and the typed model
/// drops `data_templates`. `OnboardingStep.encode` therefore writes `raw_content_blocks` verbatim, and
/// the cache decoder (userInfo flag) prefers it — so a cold start keeps the host-data authoring, and
/// integer 0 / 1, a Bool and a fraction keep their JSON kinds (`AnyCodable.encode` checks `as Bool`
/// first, which would turn 0/1 into false/true).
final class HostDataCacheRoundTripTests: XCTestCase {

    private let flowJSON = """
    {
      "id": "flow_1", "name": "f", "version": 1,
      "steps": [{
        "id": "step8", "type": "custom",
        "config": { "content_blocks": [
          { "id": "block_recs_select", "type": "input_select", "field_id": "select_recs",
            "field_options": [{ "id": "opt_1", "label": "Recommended venue", "value": "recommended",
              "image_url": "https://assets.example.com/fallback.png",
              "data_templates": { "label": "{{item.name}}", "image_url": "{{item.imageUrl}}", "value": "{{item.id}}" } }],
            "field_config": { "repeat": { "source": "hook_data.recommendations", "template_option_id": "opt_1", "max": 4 },
                              "zero": 0, "one": 1, "flag": true, "ratio": 0.25 } },
          { "type": "text", "text": "Hi {{hook_data.name}}" }
        ] }
      }]
    }
    """

    private func cacheDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.userInfo[.appdnaOnboardingFromCache] = true
        return d
    }

    /// Exactly what `RemoteConfigManager.cacheAllFetchedConfigs` writes and `loadCachedConfigs` reads.
    private func cacheRoundTrip(_ flow: OnboardingFlowConfig, decoder: JSONDecoder) throws -> OnboardingFlowConfig {
        let encoded = try JSONEncoder().encode(flow)
        let obj = try JSONSerialization.jsonObject(with: encoded)
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try decoder.decode(OnboardingFlowConfig.self, from: data)
    }

    func test_ios_cache_round_trip_keeps_raw() throws {
        let live = try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(flowJSON.utf8))
        let liveRaw = try XCTUnwrap(live.steps.first?.rawContentBlocks)
        XCTAssertEqual(liveRaw.count, 2)
        // The id-less text block is stamped `<stepId>/<index>` at capture, in raw AND typed.
        XCTAssertEqual(liveRaw[1].objectValue?["id"], .string("step8/1"))
        XCTAssertEqual(live.steps.first?.config.content_blocks?[1].id, "step8/1")

        let cached = try cacheRoundTrip(live, decoder: cacheDecoder())
        let raw = try XCTUnwrap(cached.steps.first?.rawContentBlocks)
        XCTAssertEqual(raw, liveRaw, "raw blocks must survive the typed cache round trip verbatim")

        let fc = raw[0].objectValue?["field_config"]?.objectValue
        XCTAssertEqual(fc?["zero"], .int(0), "integer 0 must stay an integer, not false")
        XCTAssertEqual(fc?["one"], .int(1), "integer 1 must stay an integer, not true")
        XCTAssertEqual(fc?["flag"], .bool(true))
        XCTAssertEqual(fc?["ratio"], .double(0.25))
        let opt = raw[0].objectValue?["field_options"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(opt?["data_templates"]?.objectValue?["image_url"], .string("{{item.imageUrl}}"))

        // …and the typed decode still succeeds from the cached raw.
        XCTAssertEqual(cached.steps.first?.config.content_blocks?.count, 2)
        XCTAssertEqual(cached.steps.first?.config.content_blocks?.first?.field_options?.first?.id, "opt_1")
    }

    func test_live_decoder_ignores_the_cache_only_key() throws {
        // A document carrying `raw_content_blocks` through the SHARED decoder: the key is ignored and
        // the ladder is used (only our own cache may supply it).
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(flowJSON.utf8)) as? [String: Any])
        var steps = try XCTUnwrap(dict["steps"] as? [[String: Any]])
        steps[0]["raw_content_blocks"] = [["id": "injected", "type": "text", "text": "x"]]
        dict["steps"] = steps
        let flow = try JSONDecoder().decode(OnboardingFlowConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(flow.steps.first?.rawContentBlocks?.count, 2)
        XCTAssertEqual(flow.steps.first?.rawContentBlocks?.first?.objectValue?["id"], .string("block_recs_select"))
    }

    func test_step_built_in_code_has_no_raw() {
        XCTAssertNil(OnboardingStep(id: "s").rawContentBlocks)
    }
}
