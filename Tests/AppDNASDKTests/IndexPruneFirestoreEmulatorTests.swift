// IndexPruneFirestoreEmulatorTests.swift
//
// The whole fetch path against a REAL Firestore (the local emulator): `fetchConfigs()` reads each index
// document and its per-item documents through the Firestore SDK, and a new manager reads the disk cache back.
// The shared fixture `index_prunes_removed_items` drives the same rule through test seams; this proves the
// real reads reach it. A successful read prunes, an empty index clears without reading the mega-doc, a failed
// read (network disabled) keeps everything, and an older server with no index reads the mega-doc.
//
// Opt-in: runs only when `APPDNA_FIRESTORE_EMULATOR` names a running emulator (`host:port`). Under
// `xcodebuild test` pass it as `TEST_RUNNER_APPDNA_FIRESTORE_EMULATOR`. All data is synthetic, under a
// throwaway project id.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
import FirebaseCore
import FirebaseFirestore
@testable import AppDNASDK

final class IndexPruneFirestoreEmulatorTests: XCTestCase {

    private let emulator = ProcessInfo.processInfo.environment["APPDNA_FIRESTORE_EMULATOR"] ?? ""
    private let project = "demo-sdk-index-prune"
    private let appPath = "orgs/o_index/apps/a_index"
    private var db: Firestore!
    private var savedDB: Firestore?
    private var cacheSuite = ""

    private struct Kind { let index: String; let key: String; let mega: String; let prefix: String; let fields: [String: Any] }
    private let kinds: [Kind] = [
        Kind(index: "paywall_index", key: "paywalls", mega: "paywalls", prefix: "pw_", fields: ["name": "Synthetic paywall"]),
        Kind(index: "onboarding_index", key: "flows", mega: "onboarding", prefix: "flow_",
             fields: ["name": "Synthetic flow", "version": 1, "steps": [Any]()]),
        Kind(index: "survey_index", key: "surveys", mega: "surveys", prefix: "survey_",
             fields: ["name": "Synthetic survey", "survey_type": "nps", "questions": [Any]()]),
    ]

    override func setUpWithError() throws {
        try XCTSkipIf(emulator.isEmpty, "APPDNA_FIRESTORE_EMULATOR is not set")
        let app: FirebaseApp
        if let existing = FirebaseApp.app(name: "index_prune") {
            app = existing
        } else {
            let options = FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1")
            options.projectID = project
            options.apiKey = "AIzaSyFakeKeyForTheEmulatorOnly-0000000"
            FirebaseApp.configure(name: "index_prune", options: options)
            app = try XCTUnwrap(FirebaseApp.app(name: "index_prune"))
            let settings = Firestore.firestore(app: app).settings
            settings.host = emulator
            settings.isSSLEnabled = false
            // Eager GC: a document no query is listening to is not kept, so with the network off a read FAILS
            // instead of being answered from the client cache (which would never reach the failed-read branch).
            settings.cacheSettings = MemoryCacheSettings(garbageCollectorSettings: MemoryEagerGCSetting())
            Firestore.firestore(app: app).settings = settings
        }
        db = Firestore.firestore(app: app)
        savedDB = AppDNA.firestoreDB
        AppDNA.firestoreDB = db
        try http("DELETE", "http://\(emulator)/emulator/v1/projects/\(project)/databases/(default)/documents", nil)
        cacheSuite = "ai.appdna.sdk.test.index-prune.\(UUID().uuidString)"
    }

    override func tearDown() {
        if !emulator.isEmpty { AppDNA.firestoreDB = savedDB }
        super.tearDown()
    }

    func testARemovedItemIsGoneFromMemoryAndFromTheDiskCacheAfterARestart() throws {
        try publish(["a", "b"])
        let first = try fetch(manager())
        assertHeld("after the first fetch", ["a", "b"], first)

        try publish(["a"])
        try fetch(first)
        assertHeld("after the fetch that no longer lists b", ["a"], first)
        assertHeld("a new manager over the same disk cache", ["a"], manager())

        // A restart, then removal: the item came from the disk cache, not from this process's fetches.
        let restarted = manager()
        try publish([], megaDocIds: ["mega"])
        try fetch(restarted)
        assertHeld("an empty index, with a mega-doc that lists another item", [], restarted)
        assertHeld("after the empty index, restarted", [], manager())
    }

    func testAFailedReadKeepsTheCache() throws {
        try publish(["a", "b"])
        let rcm = try fetch(manager())
        assertHeld("after the first fetch", ["a", "b"], rcm)

        try publish(["a"])
        let off = expectation(description: "network off")
        db.disableNetwork { _ in off.fulfill() }
        wait(for: [off], timeout: 10)
        // Control: with the network off, this harness's index read really fails. Without it, a read answered
        // from the client cache would let this test pass without ever taking the failed-read branch.
        let probe = expectation(description: "offline read")
        var probeFailed = false
        db.document("\(appPath)/config/paywall_index").getDocument { _, error in probeFailed = error != nil; probe.fulfill() }
        wait(for: [probe], timeout: 15)
        XCTAssertTrue(probeFailed, "control: an index read with the network off must fail")
        defer {
            let on = expectation(description: "network on")
            db.enableNetwork { _ in on.fulfill() }
            wait(for: [on], timeout: 10)
        }
        // A fully failed fetch posts no update: give its reads time to fail, then look.
        rcm.fetchConfigs()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        assertHeld("after a fetch with the network off", ["a", "b"], rcm)
        assertHeld("restarted after the failed fetch", ["a", "b"], manager())
    }

    func testNoIndexDocumentReadsTheMegaDoc() throws {
        for k in kinds { try writeMega(k, ["old_a", "old_b"]) }
        let rcm = try fetch(manager())
        assertHeld("an older server's mega-doc", ["old_a", "old_b"], rcm)
        assertHeld("restarted", ["old_a", "old_b"], manager())
    }

    // MARK: - Helpers

    /// A manager over this test's disk cache; a second one over the same suite is a restart.
    private func manager() -> RemoteConfigManager {
        RemoteConfigManager(firestorePath: appPath, configCache: ConfigCache(ttl: 3600, suiteName: cacheSuite), configTTL: 3600)
    }

    /// One real `fetchConfigs()`, waited on until its completion has posted `AppDNA.configUpdated`.
    @discardableResult
    private func fetch(_ rcm: RemoteConfigManager) throws -> RemoteConfigManager {
        let done = expectation(forNotification: AppDNA.configUpdated, object: nil)
        rcm.fetchConfigs()
        wait(for: [done], timeout: 30)
        _ = rcm.getAllPaywalls() // the manager's queue has drained
        return rcm
    }

    private func held(_ rcm: RemoteConfigManager) -> [[String]] {
        [rcm.getAllPaywalls().keys.sorted(), rcm.getAllOnboardingFlows().keys.sorted(), rcm.getSurveyConfigs().keys.sorted()]
    }

    private func assertHeld(_ label: String, _ ids: [String], _ rcm: RemoteConfigManager, line: UInt = #line) {
        let want = kinds.map { k in ids.map { k.prefix + $0 }.sorted() }
        let got = held(rcm)
        print("[index-prune-ios] \(label): \(got)")
        XCTAssertEqual(got, want, label, line: line)
    }

    /// The server's index-path shape: an index listing `ids`, their item documents, and a stale mega-doc.
    private func publish(_ ids: [String], megaDocIds: [String] = ["stale"]) throws {
        for k in kinds {
            var listed: [String: Any] = [:]
            for id in ids { listed[k.prefix + id] = ["name": id] }
            try write("\(appPath)/config/\(k.index)", [k.key: listed])
            for id in ids {
                var doc = k.fields; doc["id"] = k.prefix + id
                try write("\(appPath)/config/\(k.index)/\(k.key)/\(k.prefix + id)", doc)
            }
            try writeMega(k, megaDocIds)
        }
    }

    private func writeMega(_ k: Kind, _ ids: [String]) throws {
        var docs: [String: Any] = [:]
        for id in ids { var d = k.fields; d["id"] = k.prefix + id; docs[k.prefix + id] = d }
        try write("\(appPath)/config/\(k.mega)", [k.key: docs])
    }

    /// A document written through the emulator's REST API (as the owner), so the SDK's client cache is untouched.
    private func write(_ path: String, _ data: [String: Any]) throws {
        let doc: [String: Any] = ["name": "projects/\(project)/databases/(default)/documents/\(path)", "fields": fields(data)]
        let body = try JSONSerialization.data(withJSONObject: ["writes": [["update": doc]]])
        try http("POST", "http://\(emulator)/v1/projects/\(project)/databases/(default)/documents:commit", body)
    }

    private func fields(_ m: [String: Any]) -> [String: Any] { m.mapValues(value) }

    private func value(_ v: Any) -> [String: Any] {
        switch v {
        case let s as String: return ["stringValue": s]
        case let b as Bool: return ["booleanValue": b]
        case let i as Int: return ["integerValue": String(i)]
        case let d as Double: return ["doubleValue": d]
        case let m as [String: Any]: return ["mapValue": ["fields": fields(m)]]
        case let a as [Any]: return ["arrayValue": ["values": a.map(value)]]
        default: return ["nullValue": NSNull()]
        }
    }

    private func http(_ method: String, _ url: String, _ body: Data?) throws {
        var req = URLRequest(url: try XCTUnwrap(URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)))
        req.httpMethod = method
        req.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var text = ""
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if !(200...299).contains(status) { throw NSError(domain: "emulator", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(url) → \(status) \(text)"]) }
    }
}
