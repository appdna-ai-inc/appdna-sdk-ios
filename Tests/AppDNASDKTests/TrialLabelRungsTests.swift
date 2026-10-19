import XCTest
@testable import AppDNASDK

/**
 #989 — THE FOUR RUNGS OF A TRIAL SENTENCE, in order.

 `trial.duration_days` was required by the console schema, decoded by both SDKs, and read by NONE
 of the three rungs that existed — so a plan carrying the object with no `label` drew no trial text
 at all while carrying an authored trial length. 2 of 19 plans on dev are that shape.

 🔴 The ORDER is the assertion, not the formatting. A new rung placed above an authored one would
 silently reword every published paywall that already says something, which is the failure this
 pins against: each case sets the rungs it wants to lose as well as the one it expects to win.

 The Kotlin twin is `TrialLabelRungsTest.kt`; both drive the real `trialLabel` property.
 */
final class TrialLabelRungsTests: XCTestCase {

    private func plan(
        label: String? = nil,
        trialDuration: String? = nil,
        durationDays: Int? = nil,
        storeTrial: String? = nil
    ) throws -> PaywallPlan {
        var json: [String: Any] = ["id": "p1", "product_id": "app.premium.monthly"]
        if label != nil || durationDays != nil {
            var trial: [String: Any] = [:]
            if let label { trial["label"] = label }
            if let durationDays { trial["duration_days"] = durationDays }
            json["trial"] = trial
        }
        if let trialDuration { json["trial_duration"] = trialDuration }
        let data = try JSONSerialization.data(withJSONObject: json)
        var decoded = try JSONDecoder().decode(PaywallPlan.self, from: data)
        decoded.resolvedStoreTrial = storeTrial
        return decoded
    }

    func testRung1AnAuthoredLabelIsVerbatimAndBeatsEverythingBelowIt() throws {
        let p = try plan(label: "First week on us", trialDuration: "P7D", durationDays: 7, storeTrial: "P1M")
        XCTAssertEqual(p.trialLabel, "First week on us")
    }

    func testRung2TrialDurationIsPhrasedAndBeatsDurationDaysAndTheStore() throws {
        let p = try plan(trialDuration: "P7D", durationDays: 30, storeTrial: "P1M")
        XCTAssertEqual(p.trialLabel, "7 days free trial")
    }

    func testRung3DurationDaysIsPhrasedWhenNothingAboveItIsSet() throws {
        let p = try plan(durationDays: 7, storeTrial: "P1M")
        XCTAssertEqual(p.trialLabel, "7 days free trial")
    }

    func testRung4TheStoresTrialIsLast() throws {
        let p = try plan(storeTrial: "P1W")
        XCTAssertEqual(p.trialLabel, "1 week free trial")
    }

    /// The control: nothing authored and no store answer draws nothing, rather than "P0D".
    func testNothingAuthoredAndNoStoreTrialDrawsNothing() throws {
        XCTAssertNil(try plan().trialLabel)
    }

    /// A zero or negative duration is not a trial — it must not become "0 days free trial".
    func testANonPositiveDurationDaysIsIgnored() throws {
        XCTAssertNil(try plan(durationDays: 0).trialLabel)
    }
}
