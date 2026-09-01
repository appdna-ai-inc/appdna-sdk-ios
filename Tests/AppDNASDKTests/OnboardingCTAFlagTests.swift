import XCTest
@testable import AppDNASDK

/// The flag CTA's parsing and the fold into the flat `flags` bucket.
///
/// Mirrors Android `OnboardingCTAFlagTest.kt` case for case. iOS needs no wire encoding — its
/// `onAction` has a real second parameter and forwards `block.action_value` directly — so the
/// `OnboardingActionPair` round-trip cases have no counterpart here. Everything else must agree
/// exactly, because the shared fixtures assert one expectation against both platforms.
final class OnboardingCTAFlagTests: XCTestCase {

    // MARK: - parse

    func testBareKeyRecordsStringTrue() {
        let flag = OnboardingCTAFlag.parse("wants_callback")
        XCTAssertEqual(flag?.key, "wants_callback")
        // A String, not a Bool: this value crosses to Flutter and React Native through JSON and
        // lands in analytics props, and a String is the one representation all four agree on.
        XCTAssertEqual(flag?.value, "true")
    }

    func testKeyEqualsValueSplitsOnFirstEqualsOnly() {
        XCTAssertEqual(OnboardingCTAFlag.parse("upsell_choice=booking"),
                       OnboardingCTAFlag.Flag(key: "upsell_choice", value: "booking"))
    }

    func testValueMayContainAnEqualsSign() {
        XCTAssertEqual(OnboardingCTAFlag.parse("utm=a=b"),
                       OnboardingCTAFlag.Flag(key: "utm", value: "a=b"))
    }

    func testClearedValueMeansThePlainFlag() {
        // "key=" is what the console writes if an author types a value and deletes it. An empty
        // string would still pass a `flags["k"] != nil` check while failing `== "true"` — a flag
        // that reads as set and as unset at the same time.
        XCTAssertEqual(OnboardingCTAFlag.parse("wants_callback=")?.value, "true")
    }

    func testWhitespaceIsTrimmedFromBothHalves() {
        XCTAssertEqual(OnboardingCTAFlag.parse("  upsell_choice = booking  "),
                       OnboardingCTAFlag.Flag(key: "upsell_choice", value: "booking"))
    }

    func testNoKeyMeansNoFlag() {
        // The CTA still advances; it just records nothing. A blank-keyed flag would write an empty
        // string into the bucket a host routes on.
        XCTAssertNil(OnboardingCTAFlag.parse(nil))
        XCTAssertNil(OnboardingCTAFlag.parse(""))
        XCTAssertNil(OnboardingCTAFlag.parse("   "))
        XCTAssertNil(OnboardingCTAFlag.parse("=booking"))
    }

    // MARK: - the fold into the flat bucket

    func testMergeCollectsFlagsWithoutTouchingStepAnswers() {
        let before: [String: Any] = ["summary": ["upsell_choice": "booking"]]
        let after = OnboardingCTAFlag.merge(into: before, flags: ["upsell_choice": "booking"])
        XCTAssertEqual(after[OnboardingCTAFlag.responsesKey] as? [String: String],
                       ["upsell_choice": "booking"])
        XCTAssertEqual((after["summary"] as? [String: String]), ["upsell_choice": "booking"])
    }

    func testMergeAccumulatesFlagsFromSeveralSteps() {
        var responses = OnboardingCTAFlag.merge(into: [:], flags: ["a": "1"])
        responses = OnboardingCTAFlag.merge(into: responses, flags: ["b": "2"])
        XCTAssertEqual(responses[OnboardingCTAFlag.responsesKey] as? [String: String],
                       ["a": "1", "b": "2"])
    }

    func testNoFlagsMeansNoBucketAtAll() {
        // An onboarding with no flag CTAs must not grow an empty `flags` key that a host would then
        // have to distinguish from "flags I did set".
        XCTAssertTrue(OnboardingCTAFlag.merge(into: [:], flags: [:]).isEmpty)
    }

    // MARK: - applyTo: which keys count as flags comes from the CTA CONFIG

    private func step(withBlocks json: String) throws -> OnboardingStep {
        try JSONDecoder().decode(OnboardingStep.self, from: Data("""
        {"id":"summary","type":"custom","layout":{"content_blocks":\(json)}}
        """.utf8))
    }

    func testApplyToCollectsOnlyKeysDeclaredByAFlagCTA() throws {
        let s = try step(withBlocks: """
        [{"id":"cta","type":"button","text":"Add it","action":"flag","action_value":"upsell_choice=booking"}]
        """)
        let out = OnboardingCTAFlag.applyTo(
            responses: [:],
            step: s,
            stepData: ["upsell_choice": "booking", "full_name": "Alex"]
        )
        // The form field rode along in the same step payload and must NOT reach the bucket.
        XCTAssertEqual(out[OnboardingCTAFlag.responsesKey] as? [String: String],
                       ["upsell_choice": "booking"])
    }

    func testAFormFieldNamedFlagsCannotInjectItselfIntoTheBucket() throws {
        // Reading the DATA map instead of the CTA config would let this field write into the bucket
        // the host makes routing decisions on.
        let s = try step(withBlocks: """
        [{"id":"cta","type":"button","text":"Continue","action":"next"}]
        """)
        let out = OnboardingCTAFlag.applyTo(
            responses: [:],
            step: s,
            stepData: ["flags": ["upsell_choice": "attacker"]]
        )
        XCTAssertNil(out[OnboardingCTAFlag.responsesKey])
    }

    func testAStepWithNoFlagCTAAddsNoBucket() throws {
        let s = try step(withBlocks: """
        [{"id":"cta","type":"button","text":"Continue","action":"next"}]
        """)
        XCTAssertTrue(OnboardingCTAFlag.applyTo(responses: [:], step: s, stepData: ["a": "1"]).isEmpty)
    }

    // MARK: - the derived stat key (#595)

    func testAuthoredStatFieldIdWins() {
        XCTAssertEqual(summaryStatFieldId(blockId: "block_5", index: 2, stat: ["field_id": "group_size"]),
                       "group_size")
    }

    func testStatWithNoFieldIdDerivesOneFromItsPosition() {
        // The renderer and RequiredFieldGate MUST derive this identically; if they drift, the gate
        // blocks on a key nothing writes and the step cannot be advanced at all.
        XCTAssertEqual(summaryStatFieldId(blockId: "block_5", index: 2, stat: ["input": "stepper"]),
                       "block_5_stat_2")
        XCTAssertEqual(summaryStatFieldId(blockId: "block_5", index: 0, stat: ["field_id": ""]),
                       "block_5_stat_0")
    }
}
