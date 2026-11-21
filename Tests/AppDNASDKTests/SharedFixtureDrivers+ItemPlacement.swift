// Driver for `select_item_placement`: the REAL `ItemPlacementResolver`, fed configs through the REAL decoders.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    func runSelectItemPlacement(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            return XCTFail("[\(f.id)] select_item_placement needs action.cases")
        }
        h.state["selected"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            let placement = o["placement"]?.stringValue ?? ""
            let traits = (o["traits"]?.foundation as? [String: Any]) ?? [:]
            let items = (o["items"]?.foundation as? [[String: Any]]) ?? []
            if o["surface"]?.stringValue == "survey" {
                var surveys: [String: SurveyConfig] = [:]
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    let data = try! JSONSerialization.data(withJSONObject: item)
                    surveys[id] = try! JSONDecoder().decode(SurveyConfig.self, from: data)
                }
                return ItemPlacementResolver.pickSurveyId(from: surveys, placement: placement, traits: traits) ?? "none"
            }
            let flows = items.map { item -> OnboardingFlowConfig in
                let data = try! JSONSerialization.data(withJSONObject: item)
                return try! JSONDecoder().decode(OnboardingFlowConfig.self, from: data)
            }
            return ItemPlacementResolver.pickFlow(from: flows, placement: placement, traits: traits)?.id ?? "none"
        }
    }
}
