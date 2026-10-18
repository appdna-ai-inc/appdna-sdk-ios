// StorePeriodDisplayTests.swift — #933 slice 2
//
// The STORE's billing period reaches the screen, and an authored one still wins.
//
// Both stores report a subscription's period structurally and the SDKs have captured it since #923
// while rendering none of it: the period beside a price was whatever an author typed, and **0 of 81
// production plans typed anything**. So a paywall showed the store's real price with no cadence
// beside it.
//
// 🔴 ADDITIVE ON PURPOSE. An authored `period` wins, so no published paywall changes appearance —
// an author who typed "mo" keeps "mo". Only a plan that authored nothing gains the store's value.
// The alternative (store wins) would silently rewrite authored marketing copy, which is a bigger
// behavioural change than this issue asked for.
//
// Every expectation here matches `StorePeriodDisplayTest.kt` exactly, because the thing most likely
// to go wrong is not either platform alone but the two DRIFTING — which is what #959 was.
import XCTest
@testable import AppDNASDK

final class StorePeriodDisplayTests: XCTestCase {

    private func plan(authored: String?, storeIso: String?) throws -> PaywallPlan {
        var doc: [String: Any] = [
            "id": "p",
            "product_id": "app.premium.monthly",
            "name": "Monthly",
        ]
        if let authored { doc["period"] = authored }
        let data = try JSONSerialization.data(withJSONObject: doc)
        var p = try JSONDecoder().decode(PaywallPlan.self, from: data)
        p.resolvedStorePeriod = storeIso
        return p
    }

    func testAnAuthoredPeriodWinsVerbatim() throws {
        // The behaviour that must NOT change for any existing paywall.
        XCTAssertEqual(try plan(authored: "mo", storeIso: "P1M").displayPeriod, "mo")
        XCTAssertEqual(try plan(authored: "per month", storeIso: "P1Y").displayPeriod, "per month")
    }

    func testAnUnauthoredPeriodReadsTheStorePhrased() throws {
        XCTAssertEqual(try plan(authored: nil, storeIso: "P1M").displayPeriod, "/month")
        XCTAssertEqual(try plan(authored: nil, storeIso: "P1Y").displayPeriod, "/year")
        XCTAssertEqual(try plan(authored: nil, storeIso: "P1W").displayPeriod, "/week")
        XCTAssertEqual(try plan(authored: nil, storeIso: "P3M").displayPeriod, "/3 months")
    }

    func testABlankAuthoredPeriodIsTreatedAsUnauthored() throws {
        // The console writes "" for a cleared field, and "" must not beat a real store value.
        XCTAssertEqual(try plan(authored: "", storeIso: "P1M").displayPeriod, "/month")
        XCTAssertEqual(try plan(authored: "   ", storeIso: "P1M").displayPeriod, "/month")
    }

    func testNothingAuthoredAndNothingFromTheStoreDrawsNothing() throws {
        // 🔴 Nil, not a default. A plan with no cadence anywhere must render no period rather than
        // inventing "/month" — a wrong cadence beside a real price is worse than none.
        XCTAssertNil(try plan(authored: nil, storeIso: nil).displayPeriod)
        XCTAssertNil(try plan(authored: "", storeIso: nil).displayPeriod)
        // A one-time product has no billing period, which is correct rather than missing.
        XCTAssertNil(try plan(authored: nil, storeIso: "").displayPeriod)
    }

    func testAStorePeriodWeCannotParseDrawsNothingRatherThanAGuess() throws {
        XCTAssertNil(try plan(authored: nil, storeIso: "MONTHLY").displayPeriod)
        XCTAssertNil(try plan(authored: nil, storeIso: "PT1H").displayPeriod)
    }

    // MARK: - The substitution walks every place plans live

    func testApplyingStorePeriodsReachesTheSectionsPlansNotOnlyTheRootArray() throws {
        /*
         🔴 THE #923 BUG, NOT REPEATED. The first version of the store-PRICE substitution mapped
         only the root `plans` array, while every real paywall carries its plans in
         `layout.sections[].config.plans` — so the feature passed its fixture, passed its
         live-StoreKit test, and reached nothing on screen.
        */
        let doc: [String: Any] = [
            "id": "pw_1",
            "name": "Periods",
            "plans": [["id": "root_plan", "product_id": "app.premium.annual", "name": "Annual"]],
            "layout": [
                "type": "stack",
                "sections": [[
                    "id": "sec_plans",
                    "type": "plans",
                    "config": [
                        "plans": [["id": "sec_plan", "product_id": "app.premium.monthly", "name": "Monthly"]],
                    ],
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        let config = try JSONDecoder().decode(PaywallConfig.self, from: data)
        let applied = config.applyingStorePeriods([
            "app.premium.annual": "P1Y",
            "app.premium.monthly": "P1M",
        ])

        XCTAssertEqual(applied.plans?.first?.displayPeriod, "/year")
        let sectionPlan = applied.layout?.sections?.first(where: { $0.type == "plans" })?.data?.plans?.first
        XCTAssertEqual(sectionPlan?.displayPeriod, "/month")
    }

    func testAnEmptyPeriodMapIsANoOp() throws {
        // The control: a store that answered nothing must leave the config untouched rather than
        // clearing what was already there.
        let doc: [String: Any] = [
            "id": "pw_2",
            "name": "Untouched",
            "plans": [["id": "p", "product_id": "x", "name": "P", "period": "mo"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        let config = try JSONDecoder().decode(PaywallConfig.self, from: data)
        XCTAssertEqual(config.applyingStorePeriods([:]).plans?.first?.displayPeriod, "mo")
    }

    // MARK: - #933 slice 3 — the STORE's free trial, and the promise rule

    private func trialPlan(label: String?, duration: String?, storeTrial: String?) throws -> PaywallPlan {
        var doc: [String: Any] = ["id": "p", "product_id": "app.premium.monthly", "name": "Monthly"]
        if let label { doc["trial"] = ["label": label] }
        if let duration { doc["trial_duration"] = duration }
        let data = try JSONSerialization.data(withJSONObject: doc)
        var p = try JSONDecoder().decode(PaywallPlan.self, from: data)
        p.resolvedStoreTrial = storeTrial
        return p
    }

    func testAnAuthoredTrialLabelWinsOverTheStore() throws {
        // The behaviour that must NOT change for any published paywall.
        XCTAssertEqual(try trialPlan(label: "Free week", duration: nil, storeTrial: "P1M").trialLabel, "Free week")
        XCTAssertEqual(try trialPlan(label: nil, duration: "7-day", storeTrial: "P1M").trialLabel, "7-day free trial")
    }

    func testAnUnauthoredTrialReadsTheStorePhrased() throws {
        XCTAssertEqual(try trialPlan(label: nil, duration: nil, storeTrial: "P7D").trialLabel, "7 days free trial")
        XCTAssertEqual(try trialPlan(label: nil, duration: nil, storeTrial: "P1W").trialLabel, "1 week free trial")
        XCTAssertEqual(try trialPlan(label: nil, duration: nil, storeTrial: "P1M").trialLabel, "1 month free trial")
    }

    func testNoStoreTrialMeansNoSentenceNeverAnInventedOne() throws {
        /*
         🔴 THE PROMISE RULE. `resolvedStoreTrial` is nil when `isEligibleForIntroOffer` answered
         false — this user has already taken the trial on this Apple ID. Rendering "7 days free"
         there would promise a trial the purchase sheet refuses, which is worse than silence.
        */
        XCTAssertNil(try trialPlan(label: nil, duration: nil, storeTrial: nil).trialLabel)
    }

    func testAStoreTrialWeCannotParseDrawsNothing() throws {
        XCTAssertNil(try trialPlan(label: nil, duration: nil, storeTrial: "WEEKLY").trialLabel)
        XCTAssertNil(try trialPlan(label: nil, duration: nil, storeTrial: "PT1H").trialLabel)
    }
}
