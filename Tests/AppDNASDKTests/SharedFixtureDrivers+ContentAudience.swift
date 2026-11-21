// Driver for `evaluate_content_audience`: the `audience_rules` gate of in-app messages and surveys.
//
// `message`: the REAL `MessageManager` trigger path (`onEvent`) on a fresh manager, over a message the REAL
// `RemoteConfigManager` message parser decoded, with the case's traits as the manager's trait source and no foreground
// scene, so a message that passes every trigger filter is HELD — held = admitted. `survey`: the survey decoder the
// config manager uses and `SurveyManager.audienceAllows` (the step its `onEvent` runs). `survey_placement`: the REAL
// `ItemPlacementResolver.pickSurveyId`. Each case's `attribution` is the stored payload, reset after.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import UIKit
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    @MainActor
    func runEvaluateContentAudience(_ f: Fixture, _ h: Harness) async {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            return XCTFail("[\(f.id)] evaluate_content_audience needs action.cases")
        }
        var results: [Any] = []
        for (i, c) in cases.enumerated() {
            let o = c.objectValue ?? [:]
            let traits = (o["user_traits"]?.foundation as? [String: Any]) ?? [:]
            AttributionTargeting.payload = o["attribution"]?.objectValue?.mapValues { $0.foundation }
            defer { AttributionTargeting.payload = nil }
            switch o["surface"]?.stringValue {
            case "message":
                let id = "fx_audience_msg_\(i)"
                guard let item = o["item"]?.foundation as? [String: Any] else {
                    return XCTFail("[\(f.id)] case \(i) needs an item")
                }
                UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown")
                UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).count")
                let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.audience.\(UUID().uuidString)")
                let remoteConfig = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
                remoteConfig._parseMessageDocForTesting(id: id, data: item)
                guard let parsed = remoteConfig._getMessagesForTesting()[id], let event = parsed.trigger_rules?.event else {
                    return XCTFail("[\(f.id)] case \(i) message did not parse")
                }
                // `segment_membership`: the server's answer, for this user unless `for_current_user` is
                // false; `asked` defaults to the message's ids. Absent: no answer.
                let answer = Self.segmentAnswer(o["segment_membership"]?.foundation as? [String: Any], config: parsed)
                let manager = MessageManager(
                    remoteConfigManager: remoteConfig,
                    eventTracker: h.tracker,
                    surface: MessageSurface(
                        host: { nil },
                        show: { _, _, _ in },
                        close: { _, done in done() },
                        observeActivation: { _ in {} }
                    ),
                    userTraits: { traits },
                    segmentUserKey: { "u:fixture-user" },
                    segmentAnswer: { answer },
                    requestSegments: { _ in }
                )
                manager.onEvent(eventName: event, properties: nil)
                await Self.drainMainQueue()
                results.append(manager.heldMessageIds.contains(id))
            case "survey":
                guard let item = o["item"]?.foundation as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: item),
                      let config = try? JSONDecoder().decode(SurveyConfig.self, from: data) else {
                    return XCTFail("[\(f.id)] case \(i) survey did not decode")
                }
                results.append(SurveyManager.audienceAllows(config, traits: traits))
            case "survey_placement":
                let items = (o["items"]?.foundation as? [[String: Any]]) ?? []
                var surveys: [String: SurveyConfig] = [:]
                for item in items {
                    guard let sid = item["id"] as? String,
                          let data = try? JSONSerialization.data(withJSONObject: item),
                          let config = try? JSONDecoder().decode(SurveyConfig.self, from: data) else {
                        return XCTFail("[\(f.id)] case \(i) survey did not decode")
                    }
                    surveys[sid] = config
                }
                let placement = o["placement"]?.stringValue ?? ""
                results.append(ItemPlacementResolver.pickSurveyId(from: surveys, placement: placement, traits: traits) ?? "none")
            default:
                return XCTFail("[\(f.id)] case \(i): unknown surface")
            }
        }
        h.state["results"] = results
    }

    /// A fixture case's `segment_membership` as the membership answer the message gate reads.
    static func segmentAnswer(_ o: [String: Any]?, config: MessageConfig) -> SegmentMembership.Answer? {
        guard let o = o else { return nil }
        let set: (String) -> Set<String>? = { k in (o[k] as? [Any]).map { Set($0.compactMap { $0 as? String }) } }
        return SegmentMembership.Answer(
            userKey: (o["for_current_user"] as? Bool ?? true) ? "u:fixture-user" : "u:someone-else",
            asked: set("asked") ?? (config.audience?.ids ?? []),
            memberOf: set("member_of") ?? [],
            unresolved: set("unresolved") ?? [],
            fetchedAt: Date()
        )
    }
}
