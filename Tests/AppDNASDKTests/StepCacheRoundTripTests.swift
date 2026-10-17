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
        XCTAssertNil(after.hide_back)
    }
}
