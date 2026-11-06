// SharedFixtureDrivers+ConfigIndex.swift
//
// iOS driver for `apply_config_index`. Dispatched from `SharedFixtureTests.drive`'s default branch.
//
//   apply_config_index   REAL: every index read goes through `RemoteConfigManager.applyIndexRead` (what a
//                        fetch does with an index document); the ids it returns are served as per-item
//                        documents through the section's own parser, and nil sends the read to the
//                        mega-doc parser, as `fetchViaIndex` does. The fetch completion's disk write
//                        (`cacheAllFetchedConfigs`) runs unless every read failed, as in production.
//                        `after_restart` is what a NEW manager loads from the same disk cache, so a
//                        removal that only reached memory fails it.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    @MainActor
    func driveConfigIndexFixtures(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "apply_config_index": runApplyConfigIndex(f, h)
        default: return false
        }
        return true
    }

    private func runApplyConfigIndex(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue,
              let fields = f.setup.config?.objectValue?["item_fields"]?.foundation as? [String: Any] else {
            XCTFail("[\(f.id)] apply_config_index needs action.cases and setup.config.item_fields")
            return
        }
        // index document → (item kind, the index's item-map key, the mega-doc's wrapper key)
        let sections: [(String, String, String, String)] = [
            ("paywall_index", "paywall", "paywalls", "paywalls"),
            ("onboarding_index", "flow", "flows", "flows"),
            ("survey_index", "survey", "surveys", "surveys"),
        ]
        func item(_ kind: String, _ id: String) -> [String: Any] {
            var doc = (fields[kind] as? [String: Any]) ?? [:]
            doc["id"] = id
            return doc
        }
        func held(_ rcm: RemoteConfigManager) -> [String: Any] {
            [
                "paywalls": rcm.getAllPaywalls().keys.sorted(),
                "flows": rcm.getAllOnboardingFlows().keys.sorted(),
                "surveys": rcm.getSurveyConfigs().keys.sorted(),
            ]
        }
        /// The fetch completion's disk write, then block until it has landed (it runs on the manager's queue,
        /// which `getAllPaywalls` also syncs on).
        func completeFetch(_ rcm: RemoteConfigManager) {
            rcm.cacheAllFetchedConfigs()
            _ = rcm.getAllPaywalls()
        }

        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.index.\(UUID().uuidString)")
            func manager() -> RemoteConfigManager {
                RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
            }
            var rcm = manager()
            for fetch in obj["fetches"]?.arrayValue ?? [] {
                let fo = fetch.objectValue ?? [:]
                if fo["restart"]?.boolValue == true { rcm = manager(); continue }
                var everyReadFailed = true
                for (indexPath, kind, indexKey, megaKey) in sections {
                    guard let read = fo[indexPath]?.objectValue, let how = read["read"]?.stringValue else {
                        XCTFail("[\(f.id)] \(indexPath) missing in a fetch")
                        continue
                    }
                    let ids = read["ids"]?.arrayValue?.compactMap(\.stringValue)
                    let indexData: [String: Any]?
                    switch how {
                    case "index":
                        var listed: [String: Any] = [:]
                        for id in ids ?? [] { listed[id] = ["name": id] }
                        indexData = [indexKey: listed]
                    case "index_without_list": indexData = ["version": 1]
                    case "no_index", "failed": indexData = nil
                    default:
                        XCTFail("[\(f.id)] unknown index read '\(how)'")
                        indexData = nil
                    }
                    let failed = how == "failed"
                    if !failed { everyReadFailed = false }
                    if let listed = rcm._applyIndexReadForTesting(indexPath: indexPath, indexData: indexData, failed: failed) {
                        let unreadable = Set(read["unreadable_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                        for id in listed where !unreadable.contains(id) {
                            rcm._applyIndexedItemForTesting(indexPath: indexPath, id: id, data: item(kind, id))
                        }
                    } else if !failed, let megaIds = read["mega_doc_ids"]?.arrayValue?.compactMap(\.stringValue) {
                        var docs: [String: Any] = [:]
                        for id in megaIds { docs[id] = item(kind, id) }
                        rcm._applyMegaDocForTesting(indexPath: indexPath, data: [megaKey: docs])
                    }
                }
                if !everyReadFailed { completeFetch(rcm) }
            }
            return ["memory": held(rcm), "after_restart": held(manager())] as [String: Any]
        }
    }
}
