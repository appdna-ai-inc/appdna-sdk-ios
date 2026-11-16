// SharedFixtureDrivers+RemoteValidation.swift
//
// Live validation — live validation of a text input through the host (`onValidateInput`).
//
//   remote_validation_script   REAL: `RemoteValidationCoordinator` (the object the step router owns), its config read
//                              through the REAL `ContentBlock` decode + `RemoteValidationConfig.of`, on a scripted clock
//                              (the coordinator's own `Schedule` seam) against a scripted host (its `StartCall` seam).
//   decode_validation_result   REAL: `InputValidationResult.decodeWire`, the decode `decodeBridgeReply` runs for every
//                              wrapper bridge, and the not-implemented signal through the task-local probe.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// A virtual clock: work scheduled at `now + ms` runs when `advance` passes it, in time order, ties in order.
    final class VirtualClock {
        private(set) var nowMs = 0
        private var seq = 0
        private var items: [(at: Int, seq: Int, fire: () -> Void)] = []

        func schedule(_ ms: Int, _ fire: @escaping () -> Void) -> () -> Void {
            seq += 1
            let id = seq
            items.append((nowMs + ms, id, fire))
            return { [weak self] in self?.items.removeAll { $0.seq == id } }
        }

        func advance(_ ms: Int) {
            let end = nowMs + ms
            while let next = items.filter({ $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
                items.removeAll { $0.seq == next.seq }
                nowMs = next.at
                next.fire()
            }
            nowMs = end
        }
    }

    @MainActor
    func runRemoteValidationScript(_ f: Fixture, _ h: Harness) {
        guard let fieldsJSON = f.setup.config?.objectValue?["fields"]?.objectValue,
              let script = f.action.raw["script"]?.arrayValue else {
            XCTFail("[\(f.id)] remote_validation_script needs setup.config.fields and action.script")
            return
        }
        let host = f.setup.session_data?.objectValue?["host"]?.objectValue ?? [:]
        let implements = host["mode"]?.stringValue != "none"
        let replies = host["replies"]?.objectValue ?? [:]

        // Each field's config through the REAL block decode.
        var configs: [String: RemoteValidationConfig] = [:]
        for (id, cfg) in fieldsJSON {
            let raw: [String: Any] = ["id": id, "type": "input_text", "field_id": id,
                                      "field_config": ["remote_validation": cfg.foundation]]
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let block = try? JSONDecoder().decode(ContentBlock.self, from: data),
                  let config = RemoteValidationConfig.of(block) else {
                XCTFail("[\(f.id)] field \(id) did not decode to a remote_validation config")
                return
            }
            configs[id] = config
        }
        let order = configs.keys.sorted()

        let clock = VirtualClock()
        var online = true
        var calls: [[String]] = []
        var events: [[String: Any]] = []
        var warnings = 0
        var values: [String: String] = [:]
        var outcomes: [[String: Any]] = []

        let coordinator = RemoteValidationCoordinator(
            schedule: { seconds, fire in clock.schedule(Int((seconds * 1000).rounded()), fire) },
            hasHost: { implements },
            startCall: { fieldId, value, _, complete in
                calls.append([fieldId, value])
                guard let reply = replies[value]?.objectValue else {
                    XCTFail("[\(f.id)] the scripted host has no reply for \"\(value)\"")
                    return {}
                }
                if case .bool(true)? = reply["never"] { return {} }
                let after = Int(reply["after_ms"]?.foundation as? Int ?? 0)
                return clock.schedule(after) {
                    // iOS has no throwing delegate: a throw is answered as nil, which ends the same way.
                    if case .bool(true)? = reply["throws"] { complete(.answered(nil)); return }
                    var result: Any? = nil
                    if let r = reply["result"], case .object = r { result = r.foundation }
                    complete(.answered(InputValidationResult.decodeBridgeReply(result)))
                }
            },
            isOnline: { online },
            now: { TimeInterval(clock.nowMs) / 1000 },
            track: { props in
                events.append(["field_id": props["field_id"] ?? NSNull(), "status": props["status"] ?? NSNull(),
                               "reason": props["reason"] ?? NSNull()])
            },
            warn: { _ in warnings += 1 }
        )
        let entries: () -> [RemoteValidationCoordinator.Entry] = {
            order.map { .init(id: $0, value: values[$0] ?? "", config: configs[$0]!) }
        }

        func observe() -> [String: Any] {
            var fields: [String: Any] = [:]
            for id in order {
                let s = coordinator.state(id)
                fields[id] = ["state": s?.phase.rawValue ?? "idle", "message": s?.message ?? NSNull(),
                              "reason": s?.reason ?? NSNull()]
            }
            return ["fields": fields, "call_count": calls.count, "cta_waiting": coordinator.ctaWaiting,
                    "cta_outcomes": outcomes, "warnings": warnings]
        }

        var checkpoints: [String: Any] = [:]
        let expected = f.expect.state_after?.objectValue?["checkpoints"]?.objectValue ?? [:]
        for op in script {
            guard let o = op.objectValue, let kind = o["op"]?.stringValue else { XCTFail("[\(f.id)] bad op"); return }
            switch kind {
            case "type":
                let id = o["field"]?.stringValue ?? "", value = o["value"]?.stringValue ?? ""
                values[id] = value
                coordinator.valueChanged(id, value, config: configs[id]!)
            case "advance_clock_ms":
                clock.advance(Int(o["ms"]?.foundation as? Int ?? 0))
            case "confirm":
                coordinator.confirm(o["field"]?.stringValue ?? "")
            case "set_online":
                var next = false
                if case .bool(true)? = o["online"] { next = true }
                let regained = next && !online
                online = next
                if regained { coordinator.connectivityRegained() }
            case "tap_cta":
                coordinator.tap(fields: entries) { decision in
                    switch decision {
                    case .block(let m): outcomes.append(["outcome": "blocked", "message": m])
                    default: outcomes.append(["outcome": "advanced", "message": NSNull()])
                    }
                }
            case "checkpoint":
                let name = o["name"]?.stringValue ?? ""
                // Only the keys the fixture lists are asserted for this checkpoint.
                let full = observe()
                let keys = expected[name]?.objectValue?.keys.map { $0 } ?? Array(full.keys)
                checkpoints[name] = full.filter { keys.contains($0.key) }
            default:
                XCTFail("[\(f.id)] unknown op \(kind)")
            }
        }
        h.state["checkpoints"] = checkpoints
        h.state["calls"] = calls
        h.state["events"] = events
        h.state["warnings"] = warnings
    }

    func runDecodeValidationResult(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] decode_validation_result needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            var raw: Any? = nil
            if let reply = c.objectValue?["reply"] {
                if case .null = reply { raw = nil } else { raw = reply.foundation }
            }
            switch InputValidationResult.decodeWire(raw) {
            case .result(.valid(let m))?: return ["status": "valid", "message": m ?? NSNull()] as [String: Any]
            case .result(.invalid(let m))?: return ["status": "invalid", "message": m ?? NSNull()] as [String: Any]
            case .notImplemented?:
                // The bridge entry point must also tell the step the host does not implement the hook.
                let box = RemoteValidationProbe.Box()
                RemoteValidationProbe.$box.withValue(box) { _ = InputValidationResult.decodeBridgeReply(raw) }
                XCTAssertTrue(box.notImplemented, "[\(f.id)] not_implemented did not reach the step's probe")
                return ["status": "not_implemented", "message": NSNull()] as [String: Any]
            case nil: return NSNull()
            }
        }
    }
}
