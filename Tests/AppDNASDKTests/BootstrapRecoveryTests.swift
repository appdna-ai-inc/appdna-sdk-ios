// BootstrapRecoveryTests.swift
//
// A failed bootstrap no longer degrades the whole session (Android `BootstrapRecoveryTest`, same contract,
// and the shared fixture `resilience/bootstrap_recovery`).
//
// The SDK retries it — when the network comes back, on foreground, and after a bounded backoff — and applies
// the first answer exactly as a first-time success: bootstrap data, the Firestore path (and its config
// fetch). `onReady` fires once (at the failure), `lastInitError` holds the failure until it recovers and is
// nil after, and a retry whose configure has ended applies nothing.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 30):
//   - no `startBootstrapRecovery` call → the recovery tests fail (org id stays nil);
//   - the retry loop ignoring `isOnline()` → the offline test fails (attempts made offline);
//   - `shutdown()` not stopping the loop AND the epoch checks removed from the retry → the stale-retry test
//     fails (either guard alone holds).
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
@testable import AppDNASDK

final class BootstrapRecoveryTests: XCTestCase {

    /// What each bootstrap gets, by arrival index; default 401 (a failed bootstrap, not retried within the attempt).
    final class Plan: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int: () -> LoopbackHTTPServer.Answer] = [:]
        private var received = 0
        func set(_ i: Int, _ a: @escaping () -> LoopbackHTTPServer.Answer) { lock.lock(); answers[i] = a; lock.unlock() }
        func next() -> LoopbackHTTPServer.Answer {
            lock.lock(); let i = received; received += 1; let a = answers[i]; lock.unlock()
            return a?() ?? .init(status: 401, headers: [:], body: "{}")
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return received }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = true
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    }

    private var server: LoopbackHTTPServer?
    private let plan = Plan()
    private let online = Flag()
    private var savedDropped = 0

    static func body(_ org: String) -> LoopbackHTTPServer.Answer {
        .init(status: 200, headers: ["Content-Type": "application/json"],
              body: #"{"orgId":"\#(org)","appId":"app_recovery","firestorePath":"orgs/\#(org)/apps/app_recovery","#
                + #""settings":{"flushInterval":30,"batchSize":20,"configTTL":300}}"#)
    }

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        AppDNA.resetInitStateForTesting()
        let plan = self.plan
        server = LoopbackHTTPServer { label in
            label.hasPrefix("GET /api/v1/sdk/bootstrap") ? plan.next() : .init(status: 401, headers: [:], body: "{}")
        }
        if let server {
            APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
            APIBaseURL.gateForTesting = { true }
        }
        let online = self.online
        AppDNA.bootstrapRetryBackoffForTesting = { _ in 0.2 }
        AppDNA.bootstrapRetryOnlineForTesting = { online.value }
    }

    override func tearDown() {
        AppDNA.shutdown()
        waitUntil("torn down") { AppDNA.subsystemsUp()["events"] == false }
        AppDNA.drainSDKQueueForTesting()
        ShutdownUploadIsolation.restore(savedDropped)
        AppDNA.bootstrapRetryBackoffForTesting = nil
        AppDNA.bootstrapRetryOnlineForTesting = nil
        AppDNA.resetInitStateForTesting()
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ cond: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() >= deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func idle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private var lastErrorIsBootstrapFailure: Bool {
        if let e = AppDNA.lastInitError as? AppDNAInitError, case .bootstrapFailed = e { return true }
        return false
    }

    func testAFailedBootstrapIsRetriedAndAppliedLikeAFirstSuccess() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(1, { Self.body("org_recovered") })
        let recoveredBefore = AppDNA.bootstrapsRecoveredForTesting
        var ready = 0

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready += 1 }
        waitUntil("ready after the failed bootstrap") { ready == 1 }
        XCTAssertTrue(lastErrorIsBootstrapFailure || AppDNA.bootstrapOrgIdForTesting != nil,
                      "the failed bootstrap was not reported: \(String(describing: AppDNA.lastInitError))")

        waitUntil("the retry was applied") { AppDNA.bootstrapOrgIdForTesting == "org_recovered" }
        AppDNA.drainSDKQueueForTesting()
        idle(0.3)
        XCTAssertEqual(ready, 1, "onReady fired again on recovery")
        XCTAssertFalse(lastErrorIsBootstrapFailure, "lastInitError still holds the bootstrap failure after it recovered")
        XCTAssertEqual(AppDNA.bootstrapsRecoveredForTesting, recoveredBefore + 1)
        XCTAssertEqual(AppDNA.remoteConfig.manager?.firestorePathForTesting, "orgs/org_recovered/apps/app_recovery",
                       "the recovered bootstrap's Firestore path did not reach remote config")
        XCTAssertTrue(AppDNA.isReadyForTesting)
        let requests = plan.count
        idle(1.0)
        XCTAssertEqual(plan.count, requests, "the SDK kept retrying after it recovered")
    }

    func testOfflineTheSDKWaitsForTheNetworkInsteadOfUsingUpItsAttempts() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        online.value = false
        plan.set(1, { Self.body("org_back_online") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        idle(1.5)   // seven backoff periods
        XCTAssertEqual(plan.count, 1, "a retry was made while offline")
        XCTAssertEqual(AppDNA.bootstrapRecoveryForTesting?.attempts, 0)

        online.value = true
        AppDNA.bootstrapRecoveryForTesting?.trigger()   // NetworkMonitor's "network is back"
        waitUntil("the retry after the network came back was applied") { AppDNA.bootstrapOrgIdForTesting == "org_back_online" }
    }

    func testAForegroundTriggersARetryAtOnce() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        AppDNA.bootstrapRetryBackoffForTesting = { _ in 3600 }   // only a trigger can start an attempt
        plan.set(1, { Self.body("org_foreground") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the retry loop started") { AppDNA.bootstrapRecoveryForTesting != nil }
        idle(0.5)
        XCTAssertEqual(plan.count, 1)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        waitUntil("the foreground retry was applied") { AppDNA.bootstrapOrgIdForTesting == "org_foreground" }
    }

    func testRetriesAreBoundedWhenTheServerKeepsFailing() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        let max = BootstrapRecovery.defaultMaxAttempts
        waitUntil("every retry made", timeout: 60) { self.plan.count == 1 + max }
        idle(1.0)
        XCTAssertEqual(plan.count, 1 + max, "more retries than the bound")
        XCTAssertTrue(lastErrorIsBootstrapFailure)
    }

    func testARetryForAConfigureThatEndedIsDropped() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        let hold = DispatchSemaphore(value: 0)
        plan.set(1, { _ = hold.wait(timeout: .now() + 30); return Self.body("org_stale_retry") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the retry reached the server (held)") { self.plan.count == 2 }

        AppDNA.shutdown()
        plan.set(2, { Self.body("org_second_configure") })
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("the second configure applied its bootstrap") { AppDNA.bootstrapOrgIdForTesting == "org_second_configure" }

        hold.signal()
        idle(1.0)
        AppDNA.drainSDKQueueForTesting()
        XCTAssertEqual(AppDNA.bootstrapOrgIdForTesting, "org_second_configure",
                       "a retry of the ended configure overwrote the new one")
    }
}
