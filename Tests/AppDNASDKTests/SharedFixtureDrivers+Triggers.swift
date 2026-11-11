// SharedFixtureDrivers+Triggers.swift
//
// iOS driver for `dispatch_triggers`: every tracked event — the SDK's own and the host's — reaches
// in-app message and survey trigger evaluation exactly once. Driven through the REAL
// `EventTracker.track` and the REAL `TriggerDispatcher`, wired the way `configure()` wires them (the
// tracker's `triggerSink` → `record`). `host_track` goes through the public `AppDNA.track` with the
// tracker installed, so a host event evaluated twice — once in the facade, once in the tracker — would
// show up as a duplicate result.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    func runDispatchTriggers(_ f: Fixture, _ h: Harness) {
        guard let script = f.action.raw["script"]?.arrayValue else {
            return XCTFail("[\(f.id)] dispatch_triggers needs action.script")
        }
        let reactions = (f.action.raw["reactions"]?.foundation as? [String: Any]) ?? [:]
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "fx.\(UUID())")))
        // Inline executor: the drain runs on the caller, so the order is the order of the script.
        let dispatcher = TriggerDispatcher(executor: { $0() })
        tracker.triggerSink = { event, properties in dispatcher.record(event: event, properties: properties) }

        var out: [String] = []
        var reacted: Set<String> = []
        let evaluator: TriggerDispatcher.Evaluator = { surface, event, _ in
            let key = "\(surface.rawValue):\(event)"
            out.append(key)
            // A presentation tracks its `*_shown` through the same tracker; once per key, like `once`.
            if let react = reactions[key] as? String, reacted.insert(key).inserted {
                tracker.track(event: react, properties: [:])
            }
        }

        AppDNA.installEventTrackerForTest(tracker)
        defer { AppDNA.installEventTrackerForTest(nil) }

        for step in script {
            let o = step.objectValue
            switch o?["op"]?.stringValue {
            case "track":
                let props = (o?["properties"]?.foundation as? [String: Any]) ?? [:]
                tracker.track(event: o?["event"]?.stringValue ?? "", properties: props)
            case "track_many":
                let prefix = o?["prefix"]?.stringValue ?? ""
                let count = Int(o?["count"]?.doubleValue ?? 0)
                for n in 0..<count { tracker.track(event: "\(prefix)\(n + 1)", properties: [:]) }
            case "host_track":
                AppDNA.track(event: o?["event"]?.stringValue ?? "", properties: [:])
                AppDNA.drainSDKQueueForTesting()
            case "attach":
                dispatcher.attach(evaluator)
            case "config_ready":
                dispatcher.markConfigReady()
            case "set_consent":
                tracker.setConsent(analytics: o?["analytics"]?.boolValue ?? true)
            case "expect_held":
                out.append("held=" + dispatcher.heldEventNames.joined(separator: ","))
            default:
                return XCTFail("[\(f.id)] dispatch_triggers: unknown op \(o?["op"]?.stringValue ?? "nil")")
            }
        }
        h.state["results"] = out
        h.state["dropped_while_held"] = dispatcher.droppedWhileHeld
    }
}
