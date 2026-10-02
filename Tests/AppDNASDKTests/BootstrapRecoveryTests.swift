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
// The loop waits on a continuation `trigger()` resumes, with the backoff as its timeout (it used to poll ten
// times a second); a `start()` after `stop()` starts nothing; the loop removes its observers however it ends;
// a 401 / 403 ends it (and a 401 at configure starts none); a 429's Retry-After holds the next attempt back;
// every wait is jittered and a trigger starts its attempt after a short random delay.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 30):
//   - no `startBootstrapRecovery` call → the recovery tests fail (org id stays nil);
//   - the retry loop ignoring `isOnline()` → the offline test fails (attempts made offline);
//   - `shutdown()` not stopping the loop AND the epoch checks removed from the retry → the stale-retry test
//     fails (either guard alone holds).
// Round 31:
//   - the wait polling every 0.1 s again (the old `tick` loop) → the no-wakeup test fails;
//   - the `stopped` check removed from `start()` → the start-after-stop test fails (observers registered;
//     no attempt is made even then — the loop itself checks `stopped` before waiting: two guards);
//   - `removeObservers()` not run when the loop gives up → the gives-up test fails;
//   - `outcome(failureStatus:)` answering `.retry` for 401 → the 401 tests fail (retries continue);
//   - `.retryAfter` treated as `.retry` → the Retry-After test fails (the next attempt comes too early);
//   - the trigger delay removed → the trigger-delay test fails.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
@testable import AppDNASDK

final class BootstrapRecoveryTests: XCTestCase {

    /// What each bootstrap gets, by arrival index; default 500 (a failed bootstrap — retried within the attempt
    /// `perAttempt` times in all, with the client's delays shortened in `setUp`).
    final class Plan: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int: () -> LoopbackHTTPServer.Answer] = [:]
        private var received = 0
        func set(_ i: Int, _ a: @escaping () -> LoopbackHTTPServer.Answer) { lock.lock(); answers[i] = a; lock.unlock() }
        func next() -> LoopbackHTTPServer.Answer {
            lock.lock(); let i = received; received += 1; let a = answers[i]; lock.unlock()
            lock.lock(); arrivals.append(Date()); lock.unlock()
            return a?() ?? .init(status: 500, headers: [:], body: "{}")
        }
        private var arrivals: [Date] = []
        func arrival(_ i: Int) -> Date? { lock.lock(); defer { lock.unlock() }; return i < arrivals.count ? arrivals[i] : nil }
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
    /// Requests per failed bootstrap attempt: the client retries a 5xx 3 times (`APIClient.requestData`).
    private let perAttempt = 4

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
        APIClient.requestRetryDelaysForTesting = [0.01]
    }

    override func tearDown() {
        AppDNA.shutdown()
        waitUntil("torn down") { AppDNA.subsystemsUp()["events"] == false }
        AppDNA.drainSDKQueueForTesting()
        ShutdownUploadIsolation.restore(savedDropped)
        AppDNA.bootstrapRetryBackoffForTesting = nil
        AppDNA.bootstrapRetryOnlineForTesting = nil
        APIClient.requestRetryDelaysForTesting = nil
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
        plan.set(perAttempt, { Self.body("org_recovered") })
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
        plan.set(perAttempt, { Self.body("org_back_online") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        idle(1.5)   // seven backoff periods
        XCTAssertEqual(plan.count, perAttempt, "a retry was made while offline")
        XCTAssertEqual(AppDNA.bootstrapRecoveryForTesting?.attempts, 0)

        online.value = true
        AppDNA.bootstrapRecoveryForTesting?.trigger()   // NetworkMonitor's "network is back"
        waitUntil("the retry after the network came back was applied") { AppDNA.bootstrapOrgIdForTesting == "org_back_online" }
    }

    func testAForegroundTriggersARetryAtOnce() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        AppDNA.bootstrapRetryBackoffForTesting = { _ in 3600 }   // only a trigger can start an attempt
        plan.set(perAttempt, { Self.body("org_foreground") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the retry loop started") { AppDNA.bootstrapRecoveryForTesting != nil }
        idle(0.5)
        XCTAssertEqual(plan.count, perAttempt)

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
        let all = perAttempt * (1 + max)
        waitUntil("every retry made", timeout: 60) { self.plan.count == all }
        idle(1.0)
        XCTAssertEqual(plan.count, all, "more retries than the bound")
        XCTAssertTrue(lastErrorIsBootstrapFailure)
    }

    func testARetryForAConfigureThatEndedIsDropped() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        let hold = DispatchSemaphore(value: 0)
        plan.set(perAttempt, { _ = hold.wait(timeout: .now() + 30); return Self.body("org_stale_retry") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the retry reached the server (held)") { self.plan.count == self.perAttempt + 1 }

        AppDNA.shutdown()
        plan.set(perAttempt + 1, { Self.body("org_second_configure") })
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("the second configure applied its bootstrap") { AppDNA.bootstrapOrgIdForTesting == "org_second_configure" }

        hold.signal()
        idle(1.0)
        AppDNA.drainSDKQueueForTesting()
        XCTAssertEqual(AppDNA.bootstrapOrgIdForTesting, "org_second_configure",
                       "a retry of the ended configure overwrote the new one")
    }

    // MARK: - Round 31

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testAnOfflineLoopDoesNotWakeWithoutATrigger() {
        let recovery = BootstrapRecovery(isOnline: { false }, backoff: { _ in 3600 })
        recovery.start { .done }
        idle(1.0)
        XCTAssertEqual(recovery.wakeups, 0, "the wait woke without a trigger (it polled)")
        recovery.trigger()
        waitUntil("the trigger woke the wait") { recovery.wakeups == 1 }
        idle(0.3)
        XCTAssertEqual(recovery.wakeups, 1)
        XCTAssertEqual(recovery.attempts, 0, "an attempt offline")
        recovery.stop()
    }

    func testAStartAfterStopStartsNothingAndRegistersNoObservers() {
        let made = Counter()
        let recovery = BootstrapRecovery(isOnline: { true }, backoff: { _ in 0.05 }, triggerDelayMax: 0)
        recovery.stop()   // shutdown() between storing the loop and starting it
        recovery.start { made.bump(); return .retry }
        // Counted, not sampled: a loop that ran would remove its observers when it ends, at once.
        XCTAssertEqual(recovery.observerRegistrations, 0, "start() after stop() registered observers")
        recovery.trigger()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        idle(0.5)
        XCTAssertEqual(made.value, 0, "a loop started after stop()")
        XCTAssertFalse(recovery.isObserving, "observers registered by a loop that never runs")
    }

    func testTheLoopRemovesItsObserversWhenItGivesUpOrIsRefused() {
        let gaveUp = BootstrapRecovery(isOnline: { true }, backoff: { _ in 0.05 }, maxAttempts: 2, triggerDelayMax: 0)
        gaveUp.start { .retry }
        waitUntil("both attempts made") { gaveUp.attempts == 2 }
        waitUntil("the observers were removed after the last attempt", timeout: 5) { !gaveUp.isObserving }

        let made = Counter()
        let refused = BootstrapRecovery(isOnline: { true }, backoff: { _ in 0.05 }, triggerDelayMax: 0)
        refused.start { made.bump(); return BootstrapRecovery.outcome(failureStatus: 401, retryAfter: nil) }
        waitUntil("the refused attempt") { made.value == 1 }
        waitUntil("the observers were removed after the refusal", timeout: 5) { !refused.isObserving }
        idle(0.5)
        XCTAssertEqual(made.value, 1, "retries continued after a 401")
    }

    func testA401EndsTheRetries() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(perAttempt, { .init(status: 401, headers: [:], body: "{}") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the retry was refused") { self.plan.count == self.perAttempt + 1 }
        AppDNA.bootstrapRecoveryForTesting?.trigger()
        idle(1.5)   // seven backoff periods
        XCTAssertEqual(plan.count, perAttempt + 1, "the SDK kept retrying after the server refused the key")
        XCTAssertTrue(lastErrorIsBootstrapFailure)
    }

    func testA401AtConfigureStartsNoRetries() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(0, { .init(status: 401, headers: [:], body: "{}") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        AppDNA.drainSDKQueueForTesting()
        idle(1.0)
        XCTAssertEqual(plan.count, 1, "a refused key was retried")
        XCTAssertNil(AppDNA.bootstrapRecoveryForTesting, "a retry loop for a refused key")
    }

    func testARateLimitedRetryWaitsForTheRetryAfter() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(perAttempt, { .init(status: 429, headers: ["Retry-After": "2"], body: "{}") })
        plan.set(perAttempt + 1, { Self.body("org_after_retry_after") })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready") { ready }
        waitUntil("the rate-limited retry") { self.plan.count == self.perAttempt + 1 }
        AppDNA.bootstrapRecoveryForTesting?.trigger()   // a foreground does not shorten the server's wait
        waitUntil("the retry after the Retry-After was applied") { AppDNA.bootstrapOrgIdForTesting == "org_after_retry_after" }
        let limited = try XCTUnwrap(plan.arrival(perAttempt))
        let next = try XCTUnwrap(plan.arrival(perAttempt + 1))
        XCTAssertGreaterThanOrEqual(next.timeIntervalSince(limited), 1.9, "the next attempt did not wait for the Retry-After")
    }

    func testATriggeredAttemptWaitsAShortRandomDelay() {
        let started = Counter()
        let recovery = BootstrapRecovery(isOnline: { true }, backoff: { _ in 3600 },
                                         random: { 0.5 }, triggerDelayMax: 0.8)
        recovery.start { started.bump(); return .done }
        let t0 = Date()
        recovery.trigger()
        waitUntil("the triggered attempt") { started.value == 1 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.35, "a triggered attempt started without its delay")
        recovery.stop()
    }

    func testEveryWaitIsJittered() {
        XCTAssertEqual(BootstrapRecovery.jittered(100, unit: 0), 75, accuracy: 1e-9)
        XCTAssertEqual(BootstrapRecovery.jittered(100, unit: 0.5), 100, accuracy: 1e-9)
        XCTAssertLessThan(BootstrapRecovery.jittered(100, unit: 0.999_999), 125 + 1e-9)
        let samples = Set((0..<50).map { _ in BootstrapRecovery.jittered(100, unit: Double.random(in: 0..<1)) })
        XCTAssertGreaterThan(samples.count, 10, "the jitter is not random")
    }
}
