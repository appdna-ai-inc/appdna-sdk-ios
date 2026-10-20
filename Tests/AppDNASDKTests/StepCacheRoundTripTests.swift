// StepCacheRoundTripTests.swift — #937
//
// Does a step survive the SDK's OWN CACHE with its fields intact?
//
// #928 gated the shape that bit us: a `CodingKeys` case decoded and never encoded, which lost
// `request_store_review` on every cold start — the step rendered identically and silently stopped
// asking for a review prompt. That gate is a SYNTAX check. It passes on a field encoded under the
// WRONG key, on one written at the root and read from `layout`, and on one transformed on the way
// out but not on the way back.
//
// This is the value-level half: build a step with every optional SET, encode it with the cache
// encoder, decode it with the cache decoder, and compare.
//
// 🔴 EVERY VALUE IS DISTINGUISHABLE ON PURPOSE. `true`/`1` collide across fields, so a swap between
// two booleans would round-trip "correctly" and prove nothing — `hide_back` is true while
// `hide_progress` is false, and the two numbers differ.
import XCTest
@testable import AppDNASDK

final class StepCacheRoundTripTests: XCTestCase {

    /// The decoder `RemoteConfigManager` uses for the cache, flag and all.
    private func cacheDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.userInfo[.appdnaOnboardingFromCache] = true
        return d
    }

    private func fullyPopulatedStep() throws -> OnboardingStep {
        // Built from JSON rather than the memberwise init, so the DECODE path is the one under
        // test on the way in as well as on the way out.
        let json = """
        {
          "id": "s_round_trip",
          "name": "Round trip",
          "type": "splash",
          "hide_progress": false,
          "hide_back": true,
          "request_store_review": true,
          "auto_advance_seconds": 3.5,
          "wait_for_host": false,
          "tap_anywhere_advances": true,
          "next_step_rules": [{ "condition": "always", "target_step_id": "s_next" }],
          "content_blocks": [
            { "id": "b1", "type": "heading", "text": "Kept" },
            { "id": "b2", "type": "text", "text": "Also kept" }
          ]
        }
        """
        return try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
    }

    func testEveryFieldSurvivesTheCache() throws {
        let before = try fullyPopulatedStep()
        // Sanity: the fixture really is populated, or the round trip below compares nils.
        XCTAssertEqual(before.request_store_review, true)
        XCTAssertEqual(before.auto_advance_seconds, 3.5)
        XCTAssertEqual(before.wait_for_host, false)
        XCTAssertEqual(before.tap_anywhere_advances, true)
        XCTAssertEqual(before.hide_back, true)
        XCTAssertEqual(before.hide_progress, false)

        let data = try JSONEncoder().encode(before)
        let after = try cacheDecoder().decode(OnboardingStep.self, from: data)

        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.type, before.type)
        XCTAssertEqual(after.hide_progress, before.hide_progress, "hide_progress")
        XCTAssertEqual(after.hide_back, before.hide_back, "hide_back")
        XCTAssertEqual(after.request_store_review, before.request_store_review, "#928's own field")
        XCTAssertEqual(after.auto_advance_seconds, before.auto_advance_seconds, "#921's timer")
        XCTAssertEqual(after.wait_for_host, before.wait_for_host, "#921's host-driven flag")
        // #1014's flag joined the ladder and not the encoder — a splash authored "tap anywhere to
        // advance" advanced on the launch that wrote the cache and had no way forward on the next
        // cold one. The #928 round-trip gate is what found it; this is the behaviour behind it.
        XCTAssertEqual(after.tap_anywhere_advances, before.tap_anywhere_advances, "#1014's gesture flag")
        XCTAssertEqual(after.next_step_rules?.count, before.next_step_rules?.count)
        XCTAssertEqual(after.next_step_rules?.first?.target_step_id, "s_next")
    }

    /**
     🔴 THE CONTROL THAT MAKES THE ONE ABOVE MEAN SOMETHING.

     A round trip that returns an EMPTY step would satisfy every `XCTAssertEqual(after.x, before.x)`
     if `before.x` were also nil — which is exactly the false green the accessibility-tree read gave
     in #923. So the decoded step must differ from a default one in every field that was set.
     */
    func testTheRoundTrippedStepIsNotJustAnEmptyStep() throws {
        let data = try JSONEncoder().encode(try fullyPopulatedStep())
        let after = try cacheDecoder().decode(OnboardingStep.self, from: data)
        let empty = OnboardingStep(id: "x")

        XCTAssertNotEqual(after.hide_back, empty.hide_back)
        XCTAssertNotEqual(after.request_store_review, empty.request_store_review)
        XCTAssertNotEqual(after.auto_advance_seconds, empty.auto_advance_seconds)
        XCTAssertNotEqual(after.wait_for_host, empty.wait_for_host)
        XCTAssertNotEqual(after.tap_anywhere_advances, empty.tap_anywhere_advances)
        XCTAssertNotNil(after.next_step_rules)
        XCTAssertNil(empty.next_step_rules)
    }

    /// The blocks ride as `raw_content_blocks` — the typed encode is lossy, which is why the key
    /// exists — so what matters is that the step comes back with its blocks at all.
    func testTheBlocksSurviveTheCache() throws {
        let data = try JSONEncoder().encode(try fullyPopulatedStep())
        let after = try cacheDecoder().decode(OnboardingStep.self, from: data)
        XCTAssertEqual(after.config.content_blocks?.count, 2, "both blocks must come back")
        XCTAssertEqual(after.config.content_blocks?.first?.text, "Kept")
    }

    /// A step with nothing set must not gain anything by going through the cache.
    func testAnEmptyStepStaysEmpty() throws {
        let json = #"{ "id": "s_bare", "type": "custom" }"#
        let before = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        let after = try cacheDecoder().decode(OnboardingStep.self, from: try JSONEncoder().encode(before))

        XCTAssertNil(after.request_store_review)
        XCTAssertNil(after.auto_advance_seconds)
        XCTAssertNil(after.wait_for_host)
        XCTAssertNil(after.tap_anywhere_advances)
        XCTAssertNil(after.hide_back)
    }

    // MARK: - #944: the LADDER, through the production writer

    /**
     🔴 WRITTEN TO `layout`, READ BACK FROM THE ROOT — the asymmetry the tests above do not touch.

     Five flags are decoded root-first and then from `layout`, because `updateNodeData` (the flow
     editor's only writer) puts every Logic-panel flag into `data.stepConfig`, which
     `buildStepsFromGraph` ships as the step's `layout`. The tests above write and read the ROOT.
     A cached step takes the OTHER rung on the way in and the root on the way out, so the two
     halves of the ladder are only connected on this path — and `encode(to:)` emits no `layout`
     object at all, which means the layout rung has exactly one chance to be read.

     This drives the real writer: `RemoteConfigManager.cacheAllFetchedConfigs()` encodes the parsed
     flow, a second manager decodes it back with the real `parseOnboarding(fromCache:)`, and
     `__cache_marker` — a key no DTO declares, so the typed encode cannot carry it — is how the
     test knows the asynchronous write landed rather than sleeping and hoping.
     */
    func testFlagsAuthoredONLYInLayoutSurviveTheProductionCache() throws {
        let flow: [String: Any] = [
            "__cache_marker": "raw",
            "id": "f_ladder",
            "name": "Ladder",
            "steps": [[
                "id": "s_ladder",
                "type": "splash",
                // NOTHING at the step root. Every flag is one rung down, where the console writes it.
                "layout": [
                    "content_blocks": [["id": "b1", "type": "heading", "text": "Only in layout"]],
                    "hide_progress": false,
                    "hide_back": true,
                    "request_store_review": true,
                    "auto_advance_seconds": 2.5,
                    "wait_for_host": false,
                    "tap_anywhere_advances": true,
                ],
            ]],
        ]

        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        cache.storeOnboarding(try JSONSerialization.data(
            withJSONObject: ["active_flow_id": "f_ladder", "flows": ["f_ladder": flow]]))

        let first = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        let before = try XCTUnwrap(first.getOnboardingFlow(id: "f_ladder")?.steps.first,
                                   "the seeded flow did not parse")
        // The layout rung must have been read on the way IN, or the round trip below is vacuous.
        XCTAssertEqual(before.hide_back, true, "layout.hide_back")
        XCTAssertEqual(before.hide_progress, false, "layout.hide_progress")
        XCTAssertEqual(before.request_store_review, true, "layout.request_store_review")
        XCTAssertEqual(before.auto_advance_seconds, 2.5, "layout.auto_advance_seconds")
        XCTAssertEqual(before.wait_for_host, false, "layout.wait_for_host")
        XCTAssertEqual(before.tap_anywhere_advances, true, "layout.tap_anywhere_advances")

        first.cacheAllFetchedConfigs()

        // Assert the HARNESS first: without this, "the flags match" and "the re-cache never ran,
        // and we read the raw document twice" are the same green.
        let deadline = Date().addingTimeInterval(5)
        var rewritten = false
        while Date() < deadline {
            if let d = cache.loadOnboarding(),
               !String(decoding: d, as: UTF8.self).contains("__cache_marker") {
                rewritten = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(rewritten, "the production re-cache never wrote — nothing below is a round trip")

        let second = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        let after = try XCTUnwrap(second.getOnboardingFlow(id: "f_ladder")?.steps.first,
                                  "the re-cached flow did not parse back")

        XCTAssertEqual(after.hide_back, before.hide_back, "hide_back lost its layout rung")
        XCTAssertEqual(after.hide_progress, before.hide_progress, "hide_progress lost its layout rung")
        XCTAssertEqual(after.request_store_review, before.request_store_review, "#928's own field")
        XCTAssertEqual(after.auto_advance_seconds, before.auto_advance_seconds, "#921's timer")
        XCTAssertEqual(after.wait_for_host, before.wait_for_host, "#921's host-driven flag")
        XCTAssertEqual(after.tap_anywhere_advances, before.tap_anywhere_advances, "#1014's gesture flag")
        XCTAssertEqual(after.config.content_blocks?.first?.text, "Only in layout",
                       "and the content that rode in the same layout object")
    }
}
