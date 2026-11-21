import XCTest
@testable import AppDNASDK

/// `audience_eval/set_attribution_*` and `attribution_wait_*`. REAL: the public `AppDNA.setAttribution`
/// (store + the `attribution_set` event through the harness tracker), `AttributionTargeting` over its own
/// `UserDefaults` suite (`relaunch` drops memory and keeps storage), the evaluator, and the wait with the driver's
/// clock (`elapse` fires every timer the SDK scheduled). Mirrors Android `runSetAttribution` / `runAttributionWait`.
extension SharedFixtureTests {
    @MainActor
    func driveAttributionFixtures(_ f: Fixture, _ h: Harness) -> Bool {
        switch f.action.kind {
        case "set_attribution": runSetAttribution(f, h); return true
        case "attribution_wait": runAttributionWait(f, h); return true
        case "set_attribution_bridge": runSetAttributionBridge(f, h); return true
        default: return false
        }
    }

    @MainActor
    private func cleanAttributionStore() {
        let suite = "ai.appdna.fixture.attribution"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        AttributionTargeting.defaults = defaults
        AttributionTargeting.resetForTesting()
    }

    @MainActor
    private func runSetAttribution(_ f: Fixture, _ h: Harness) {
        cleanAttributionStore()
        defer { AttributionTargeting.resetForTesting(); AttributionTargeting.defaults = .standard }
        let previous = AppDNA.eventTrackerForTesting
        AppDNA.installEventTrackerForTest(h.tracker)
        defer { AppDNA.installEventTrackerForTest(previous) }

        for call in f.action.raw["calls"]?.arrayValue ?? [] {
            switch call.objectValue?["call"]?.stringValue {
            case "set":
                let input = (call.objectValue?["attribution"]?.objectValue ?? [:]).mapValues { $0.foundation }
                AppDNA.setAttribution(input)
                AppDNA.drainSDKQueueForTesting()
            case "relaunch": AttributionTargeting.relaunchForTesting()
            case "reset":
                AppDNA.reset()
                AppDNA.drainSDKQueueForTesting()
            case let other: XCTFail("[\(f.id)] set_attribution call '\(other ?? "nil")'")
            }
        }
        h.state["stored_attribution"] = AttributionTargeting.payload
        if let cfg = f.action.raw["rules"]?.objectValue, let rulesJSON = cfg["rules"]?.arrayValue {
            let mode = cfg["match_mode"]?.stringValue ?? "all"
            let rules = AnyCodable(["conditions": AnyJSON.array(rulesJSON).foundation, "match_mode": mode] as [String: Any])
            h.state["audience_match"] = AudienceRuleEvaluator.evaluate(rules: rules, traits: [:])
        }
    }

    /// The host's calls a wrapper forwards: the public `setAttribution`, then each wait (null = 1500 ms).
    @MainActor
    private func runSetAttributionBridge(_ f: Fixture, _ h: Harness) {
        cleanAttributionStore()
        defer { AttributionTargeting.resetForTesting(); AttributionTargeting.defaults = .standard }
        let previous = AppDNA.eventTrackerForTesting
        AppDNA.installEventTrackerForTest(h.tracker)
        defer { AppDNA.installEventTrackerForTest(previous) }
        AppDNA.setAttribution((f.action.raw["attribution"]?.objectValue ?? [:]).mapValues { $0.foundation })
        AppDNA.drainSDKQueueForTesting()
        var results: [Bool] = []
        for w in f.action.raw["waits"]?.arrayValue ?? [] {
            let ms = w.doubleValue.map { Int($0) } ?? 1500
            AttributionTargeting.whenReady(timeoutMs: ms, schedule: { _, _ in XCTFail("[\(f.id)] a wait scheduled a timer with a payload stored") }) {
                results.append($0)
            }
        }
        h.state["wait_results"] = results
    }

    @MainActor
    private func runAttributionWait(_ f: Fixture, _ h: Harness) {
        cleanAttributionStore()
        defer { AttributionTargeting.resetForTesting(); AttributionTargeting.defaults = .standard }
        let timeout = f.action.raw["timeoutMs"]?.doubleValue.map { Int($0) } ?? 1500
        let input = (f.action.raw["attribution"]?.objectValue ?? [:]).mapValues { $0.foundation }
        var timers: [() -> Void] = []
        var scheduled = 0
        var results: [Bool] = []
        for call in f.action.raw["calls"]?.arrayValue?.compactMap({ $0.stringValue }) ?? [] {
            switch call {
            case "wait":
                AttributionTargeting.whenReady(timeoutMs: timeout, schedule: { _, fire in scheduled += 1; timers.append(fire) }) {
                    results.append($0)
                }
            case "elapse":
                let due = timers
                timers = []
                due.forEach { $0() }
            case "set": AttributionTargeting.store(input)
            case "relaunch":
                timers = []
                AttributionTargeting.relaunchForTesting()
            default: XCTFail("[\(f.id)] attribution_wait call '\(call)'")
            }
        }
        h.state["wait_results"] = results
        h.state["timers_scheduled"] = scheduled
    }
}
