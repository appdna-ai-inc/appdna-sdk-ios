// SharedFixtureDrivers+ServedScreens.swift
//
//   load_served_screen  REAL: `ScreenManager.loadScreen` / `loadFlow`, reading console-shaped documents
//                       through an injected document reader in place of the Firestore one `RemoteConfigManager`
//                       sets. Each case starts from an empty cache.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    func runLoadServedScreen(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] load_served_screen needs action.cases")
            return
        }
        let sm = ScreenManager.shared
        let saved = sm.documentLoader
        defer {
            sm.reset()
            sm.documentLoader = saved
        }
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            let id = o["id"]?.stringValue ?? ""
            let kind = o["kind"]?.stringValue ?? "screen"
            var docs: [String: [String: Any]] = [:]
            if let d = o["document"]?.foundation as? [String: Any] {
                docs[(kind == "flow" ? "flows/" : "screens/") + id] = d
            }
            if let s = o["screens"]?.foundation as? [String: Any] {
                for (k, v) in s { if let m = v as? [String: Any] { docs["screens/\(k)"] = m } }
            }
            var requests: [String] = []
            sm.reset()
            sm.documentLoader = { k, docId, done in
                requests.append("\(k)/\(docId)")
                done(docs["\(k)/\(docId)"])
            }
            if kind == "flow" {
                var got: FlowConfig?
                sm.loadFlow(id) { got = $0 }
                guard let fl = got else { return ["found": false, "requests": requests] as [String: Any] }
                var cachedSections: [String: Any] = [:]
                for ref in fl.screens ?? [] {
                    guard let sid = ref.screen_id else { continue }
                    cachedSections[sid] = sm.getCachedScreen(sid)?.sections?.count ?? -1
                }
                return [
                    "found": true, "id": fl.id ?? NSNull(), "name": fl.name ?? NSNull(),
                    "start_screen_id": fl.start_screen_id ?? NSNull(),
                    "screens_cached": cachedSections, "requests": requests,
                ] as [String: Any]
            }
            var got: ScreenConfig?
            sm.loadScreen(id) { got = $0 }
            guard let s = got else {
                return ["found": false, "cached": sm.getCachedScreen(id) != nil, "requests": requests] as [String: Any]
            }
            return [
                "found": true, "id": s.id ?? NSNull(), "name": s.name ?? NSNull(), "version": s.version ?? NSNull(),
                "presentation": s.presentation ?? NSNull(), "sections": s.sections?.count ?? 0,
                "start_date": s.start_date ?? NSNull(), "cached": sm.getCachedScreen(id) != nil, "requests": requests,
            ] as [String: Any]
        }
    }
}
