// SharedFixtureDrivers+LocationResolve.swift
//
// iOS drivers for the location state-holder kinds. Dispatched from
// `driveSpec497Maps`. Every value asserted is produced by REAL SDK code:
//
//   location_resolve_request  REAL: `LocationSuggestionSearch` — the ONE holder the form-step Location
//                             field and the `input_location` block bind to — with `LocationSearchSettings`
//                             resolving the authored settings, `LocationAnswer.decodeSuggestionItems`
//                             decoding the stubbed list, `resolveRequest(for:)` building the body and
//                             `LocationResolve.outcome` parsing the stubbed reply. Only the socket and
//                             the clock are replaced (`LocationSearchRig`).
//   location_field_text       REAL: the same holder, built with the stored answer or told about it
//                             after construction; its `text` is what both views show.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    // MARK: location_resolve_request

    func runLocationResolveRequest(_ f: Fixture, _ h: Harness) {
        guard let legs = f.action.raw["legs"]?.arrayValue, !legs.isEmpty else {
            return XCTFail("[\(f.id)] location_resolve_request needs action.legs")
        }
        let settings = Self.locationSettings(f.action.raw["settings"])
        var autocomplete: [String: [[String: Any]]] = [:]
        for (query, items) in f.action.raw["autocomplete"]?.objectValue ?? [:] {
            autocomplete[query] = (items.arrayValue ?? []).compactMap { $0.foundation as? [String: Any] }
        }
        let expected = f.expect.state_after?.objectValue?["checkpoints"]?.objectValue ?? [:]
        var actualCheckpoints: [String: Any] = [:]

        for legJSON in legs {
            guard let leg = legJSON.objectValue, let legName = leg["name"]?.stringValue,
                  let script = leg["script"]?.arrayValue else {
                XCTFail("[\(f.id)] a leg needs name + script"); continue
            }
            let initial: Any? = leg["stored_answer"].map { $0.foundation is NSNull ? nil : $0.foundation } ?? nil
            let rig = LocationSearchRig(settings: settings, storedAnswer: initial, autocomplete: autocomplete)

            for (i, opJSON) in script.enumerated() {
                guard let op = opJSON.objectValue, let name = op["op"]?.stringValue else {
                    XCTFail("[\(f.id)] \(legName) script[\(i)] has no op"); continue
                }
                switch name {
                case "type": rig.type(op["text"]?.stringValue ?? "")
                case "echo": rig.echo()
                case "advance_clock_ms": rig.advance(ms: Int(op["ms"]?.doubleValue ?? 0))
                case "tap": rig.tap(Int(op["index"]?.doubleValue ?? 0))
                case "resolve_reply":
                    if op["network_error"]?.boolValue == true {
                        rig.replyNetworkError()
                    } else {
                        rig.reply(status: Int(op["status"]?.doubleValue ?? 0), body: op["body"]?.foundation ?? NSNull())
                    }
                case "store_answer":
                    let v = op["value"]?.foundation
                    rig.storeFromOutside(v is NSNull ? nil : v)
                case "checkpoint":
                    let key = "\(legName)/\(op["name"]?.stringValue ?? "")"
                    guard let exp = expected[key]?.objectValue else {
                        XCTFail("[\(f.id)] checkpoint '\(key)' has no expectation"); continue
                    }
                    var actual: [String: Any] = [:]
                    for (k, e) in exp {
                        guard let value = Self.observeLocationRig(rig, k) else {
                            XCTFail("[\(f.id)] checkpoint '\(key)': unknown observable '\(k)'"); continue
                        }
                        actual[k] = value
                        let ec = Self.canonicalJSON(e), ac = Self.canonical(value)
                        if ec != ac { XCTFail("[\(f.id)] checkpoint '\(key)'.\(k): expected \(ec), got \(ac)") }
                    }
                    actualCheckpoints[key] = actual
                default:
                    XCTFail("[\(f.id)] unknown location_resolve_request op '\(name)'")
                }
            }
        }
        h.state["checkpoints"] = actualCheckpoints
    }

    /// The observables a checkpoint may name. nil = not an observable (a driver error).
    private static func observeLocationRig(_ rig: LocationSearchRig, _ key: String) -> Any? {
        let holder = rig.holder!
        switch key {
        case "field_text": return holder.text
        case "dropdown_open": return holder.isDropdownOpen
        case "suggestions": return holder.results.count
        case "resolving": return holder.isResolving
        case "stored_answer": return rig.stored ?? NSNull()
        case "autocomplete_queries": return rig.autocompleteQueries
        case "autocomplete_calls": return rig.autocompleteQueries.count
        case "resolve_bodies": return rig.resolveBodies
        default: return nil
        }
    }

    // MARK: location_field_text

    func runLocationFieldText(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue, !cases.isEmpty else {
            return XCTFail("[\(f.id)] location_field_text needs action.cases")
        }
        let settings = Self.locationSettings(nil)
        var results: [[String: Any]] = []
        for c in cases {
            guard let obj = c.objectValue, let name = obj["name"]?.stringValue, let answerJSON = obj["stored_answer"] else {
                return XCTFail("[\(f.id)] a case needs name + stored_answer")
            }
            let answer: Any? = answerJSON.foundation is NSNull ? nil : answerJSON.foundation
            let rig: LocationSearchRig
            switch obj["seed"]?.stringValue ?? "construction" {
            case "construction":
                rig = LocationSearchRig(settings: settings, storedAnswer: answer)
            case "after_construction":
                rig = LocationSearchRig(settings: settings, storedAnswer: nil)
                rig.storeFromOutside(answer)
            case let other:
                return XCTFail("[\(f.id)] unknown seed '\(other)'")
            }
            results.append(["name": name, "field_text": rig.holder.text])
        }
        h.state["results"] = results
    }

    // MARK: helpers

    /// A content block's location `field_config`, through the REAL resolver (block default: 3).
    private static func locationSettings(_ json: AnyJSON?) -> LocationSearchSettings {
        var config: [String: AnyCodable] = [:]
        for (k, v) in json?.objectValue ?? [:] { config[k] = AnyCodable(v.foundation) }
        return LocationSearchSettings.from(blockConfig: config, defaultMinChars: 3)
    }
}
