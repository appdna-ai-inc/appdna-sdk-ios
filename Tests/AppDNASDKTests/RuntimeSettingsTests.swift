// RuntimeSettingsTests.swift
//
// `flushInterval`, `batchSize` and `configTTL`: a host option > the bootstrap answer's `settings` value (if
// positive) > the built-in default, and `batchSize` as a cap on the adaptive batch size — in the queue (the
// flush threshold and the upload size), in the background uploader, and applied from a first bootstrap and
// from a recovered one. The precedence and cap tables themselves are the shared fixture
// `resilience/runtime_settings_precedence` (ResilienceFixtureTests); Android `RuntimeSettingsTest`, same
// contract.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 33): the queue ignoring its cap → the
// threshold / upload-size tests fail (no upload, 5 events left); `applyRuntimeSettings` not called → the
// bootstrap tests fail; the bootstrap value beating the host option → the explicit test fails; a
// non-positive bootstrap value accepted → the non-positive test fails.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
@testable import AppDNASDK

final class RuntimeSettingsTests: XCTestCase {

    final class Plan: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int: () -> LoopbackHTTPServer.Answer] = [:]
        private var received = 0
        func set(_ i: Int, _ a: @escaping () -> LoopbackHTTPServer.Answer) { lock.lock(); answers[i] = a; lock.unlock() }
        func next() -> LoopbackHTTPServer.Answer {
            lock.lock(); let i = received; received += 1; let a = answers[i]; lock.unlock()
            return a?() ?? .init(status: 401, headers: [:], body: "{}")
        }
    }

    private var server: LoopbackHTTPServer?
    private let plan = Plan()
    private var savedDropped = 0

    /// Each test answers with its own org id and waits for THAT one: `bootstrapData` outlives `shutdown()`, so
    /// a shared id would let a test read the previous test's bootstrap before its own configure ran.
    private let org = "org_rt_\(UUID().uuidString.prefix(8))"

    func bootstrap(_ settings: String) -> LoopbackHTTPServer.Answer {
        .init(status: 200, headers: ["Content-Type": "application/json"],
              body: #"{"orgId":"\#(org)","appId":"app_rt","firestorePath":"orgs/\#(org)/apps/app_rt","settings":"#
                + settings + "}")
    }

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        AppDNA.resetInitStateForTesting()
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = 100
        let plan = self.plan
        server = LoopbackHTTPServer { label in
            if label.hasPrefix("GET /api/v1/sdk/bootstrap") { return plan.next() }
            if label.hasPrefix("POST /api/v1/ingest/events") { return .init(status: 200, headers: [:], body: "{}") }
            return .init(status: 401, headers: [:], body: "{}")
        }
        if let server {
            APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
            APIBaseURL.gateForTesting = { true }
        }
        AppDNA.bootstrapRetryBackoffForTesting = { _ in 0.2 }
        AppDNA.bootstrapRetryOnlineForTesting = { true }
    }

    override func tearDown() {
        AppDNA.shutdown()
        waitUntil("torn down") { AppDNA.subsystemsUp()["events"] == false }
        AppDNA.drainSDKQueueForTesting()
        ShutdownUploadIsolation.restore(savedDropped)
        AppDNA.bootstrapRetryBackoffForTesting = nil
        AppDNA.bootstrapRetryOnlineForTesting = nil
        AppDNA.resetInitStateForTesting()
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = nil
        BatchSizeCapGate.set(nil)
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

    // MARK: - Options

    func testOptionsRecordWhatTheHostSet() {
        let unset = AppDNAOptions()
        XCTAssertNil(unset.requestedFlushInterval)
        XCTAssertNil(unset.requestedBatchSize)
        XCTAssertNil(unset.requestedConfigTTL)
        XCTAssertEqual(unset.flushInterval, 30)
        XCTAssertEqual(unset.batchSize, 100, "unset batchSize reads as the largest adaptive size (no cap)")
        XCTAssertEqual(unset.configTTL, 3600)

        let set = AppDNAOptions(flushInterval: 10, batchSize: 5, configTTL: 60)
        XCTAssertEqual(set.requestedFlushInterval, 10)
        XCTAssertEqual(set.requestedBatchSize, 5)
        XCTAssertEqual(set.requestedConfigTTL, 60)
        XCTAssertEqual(set.batchSize, 5)
    }

    /// A host value below 1 is ignored (as if not set): it can never make the cap 0 and stop uploads.
    func testAHostValueBelowOneIsIgnored() {
        let zero = AppDNAOptions(flushInterval: 0, batchSize: 0, configTTL: -1)
        XCTAssertEqual(zero.batchSize, 100)
        XCTAssertEqual(zero.flushInterval, 30)
        XCTAssertEqual(zero.configTTL, 3600)
        let resolved = RuntimeSettings.resolveAll(options: zero, bootstrap: nil)
        XCTAssertNil(resolved.batchSizeCap, "batchSize 0 must not become a cap of 0")
        XCTAssertEqual(resolved.flushInterval, 30)
        XCTAssertEqual(resolved.configTTL, 3600)
    }

    func testABootstrapAnswerWithoutRuntimeSettingsStillDecodes() throws {
        let data = #"{"orgId":"o","appId":"a","firestorePath":"orgs/o/apps/a","settings":{}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BootstrapData.self, from: data)
        XCTAssertNil(decoded.settings.flushInterval)
        XCTAssertNil(decoded.settings.batchSize)
        XCTAssertNil(decoded.settings.configTTL)
        XCTAssertEqual(RuntimeSettings.resolveAll(options: AppDNAOptions(), bootstrap: decoded.settings),
                       .init(flushInterval: 30, batchSizeCap: nil, configTTL: 3600))
    }

    // MARK: - Queue

    private func makeQueue(cap: Int?, store: EventStore) -> (EventQueue, EventTracker) {
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.runtime.\(UUID().uuidString)")))
        let q = EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                           eventStore: store, eventTracker: tracker, batchSizeCap: cap, flushInterval: 3600)
        tracker.setEventQueue(q)
        return (q, tracker)
    }

    /// The cap is the flush threshold AND the most one upload sends: 5 events with a cap of 3 → one threshold
    /// upload of 3, 2 left. With no cap (adaptive 100) nothing is sent.
    func testTheCapIsTheThresholdAndTheUploadSize() throws {
        let server = try XCTUnwrap(server, "could not open a local socket")
        let store = EventStore(fileName: "runtime-cap-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let (q, tracker) = makeQueue(cap: 3, store: store)
        XCTAssertEqual(q.effectiveBatchSizeForTesting, 3)
        XCTAssertEqual(BatchSizeCapGate.cap, 3, "the background uploader does not see the queue's cap")
        XCTAssertEqual(BackgroundUploader.uploadBatchSize(adaptive: 100), 3)
        for i in 0..<5 { tracker.track(event: "cap_probe_\(i)", properties: nil) }
        waitUntil("one threshold upload") { server.count("POST /api/v1/ingest/events") >= 1 }
        waitUntil("3 removed") { store.loadPending().filter { $0.event_name.hasPrefix("cap_probe_") }.count == 2 }
        idle(0.3)
        XCTAssertEqual(server.count("POST /api/v1/ingest/events"), 1)
        XCTAssertEqual(store.loadPending().filter { $0.event_name.hasPrefix("cap_probe_") }.count, 2,
                       "an upload sent more than the cap")
        withExtendedLifetime(q) {}
    }

    func testNoCapKeepsTheAdaptiveSize() throws {
        let server = try XCTUnwrap(server, "could not open a local socket")
        let store = EventStore(fileName: "runtime-nocap-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let (q, tracker) = makeQueue(cap: nil, store: store)
        XCTAssertEqual(q.effectiveBatchSizeForTesting, 100)
        XCTAssertNil(BatchSizeCapGate.cap)
        XCTAssertEqual(BackgroundUploader.uploadBatchSize(adaptive: 50), 50)
        for i in 0..<5 { tracker.track(event: "nocap_probe_\(i)", properties: nil) }
        waitUntil("persisted") { store.loadPending().filter { $0.event_name.hasPrefix("nocap_probe_") }.count == 5 }
        idle(0.5)
        XCTAssertEqual(server.count("POST /api/v1/ingest/events"), 0, "5 events crossed a threshold of 100")
        withExtendedLifetime(q) {}
    }

    /// The queue's internal cap seam at 0 holds every event (no option or answer can install it — see
    /// `testAHostValueBelowOneIsIgnored`): no threshold upload, and even an explicit flush sends nothing.
    func testACapOfZeroHoldsEveryEvent() throws {
        let server = try XCTUnwrap(server, "could not open a local socket")
        let store = EventStore(fileName: "runtime-zero-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let (q, tracker) = makeQueue(cap: 0, store: store)
        for i in 0..<3 { tracker.track(event: "zero_probe_\(i)", properties: nil) }
        waitUntil("persisted") { store.loadPending().filter { $0.event_name.hasPrefix("zero_probe_") }.count == 3 }
        q.flushClearingPause()
        idle(0.5)
        XCTAssertEqual(server.count("POST /api/v1/ingest/events"), 0)
        XCTAssertEqual(BackgroundUploader.uploadBatchSize(adaptive: 100), 0)
        withExtendedLifetime(q) {}
    }

    func testApplyingSettingsChangesTheCapAndReschedulesTheTimer() {
        let store = EventStore(fileName: "runtime-apply-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let (q, _) = makeQueue(cap: nil, store: store)
        waitUntil("timer") { q.flushTimerIntervalForTesting == 3600 }
        q.applyRuntimeSettings(batchSizeCap: 9, flushInterval: 42)
        waitUntil("rescheduled") { q.flushTimerIntervalForTesting == 42 }
        XCTAssertEqual(q.batchSizeCapForTesting, 9)
        XCTAssertEqual(BatchSizeCapGate.cap, 9)
        q.applyRuntimeSettings(batchSizeCap: nil, flushInterval: 42)
        XCTAssertNil(q.batchSizeCapForTesting)
        XCTAssertNil(BatchSizeCapGate.cap)
        withExtendedLifetime(q) {}
    }

    // MARK: - Bootstrap

    private func configureAndWait(_ options: AppDNAOptions = AppDNAOptions()) {
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox, options: options)
        let org = self.org
        waitUntil("bootstrap applied") { AppDNA.bootstrapOrgIdForTesting == org }
        AppDNA.drainSDKQueueForTesting()
    }

    private func assertApplied(flush: TimeInterval, cap: Int?, ttl: TimeInterval,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(AppDNA.runtimeSettingsForTesting, .init(flushInterval: flush, batchSizeCap: cap, configTTL: ttl),
                       file: file, line: line)
        guard let q = AppDNA.eventQueueForTesting else { return XCTFail("no queue", file: file, line: line) }
        waitUntil("the queue's timer", { q.flushTimerIntervalForTesting == flush }, file: file, line: line)
        XCTAssertEqual(q.batchSizeCapForTesting, cap, "queue cap", file: file, line: line)
        XCTAssertEqual(BatchSizeCapGate.cap, cap, "background uploader cap", file: file, line: line)
        XCTAssertEqual(AppDNA.remoteConfig.manager?.currentConfigTTL, ttl, "config TTL", file: file, line: line)
    }

    func testTheBootstrapSettingsApplyWhenTheHostSetNone() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(0, { [unowned self] in self.bootstrap(#"{"flushInterval":45,"batchSize":7,"configTTL":900}"#) })
        configureAndWait()
        assertApplied(flush: 45, cap: 7, ttl: 900)
    }

    func testAHostOptionBeatsTheBootstrapValue() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(0, { [unowned self] in self.bootstrap(#"{"flushInterval":45,"batchSize":7,"configTTL":900}"#) })
        configureAndWait(AppDNAOptions(flushInterval: 12, batchSize: 4, configTTL: 120))
        assertApplied(flush: 12, cap: 4, ttl: 120)
    }

    func testNonPositiveBootstrapValuesAreIgnored() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(0, { [unowned self] in self.bootstrap(#"{"flushInterval":0,"batchSize":0,"configTTL":-1}"#) })
        configureAndWait()
        assertApplied(flush: 30, cap: nil, ttl: 3600)
    }

    /// The bootstrap the server sends today (30 / 100 / 3600) changes nothing a device does.
    func testTheServersCurrentValuesAreTheDefaults() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(0, { [unowned self] in self.bootstrap(#"{"flushInterval":30,"batchSize":100,"configTTL":3600}"#) })
        configureAndWait()
        assertApplied(flush: 30, cap: 100, ttl: 3600)
        XCTAssertEqual(RuntimeSettings.effectiveBatchSize(adaptive: 100, cap: 100), 100)
        XCTAssertEqual(RuntimeSettings.effectiveBatchSize(adaptive: 20, cap: 100), 20)
    }

    func testARecoveredBootstrapAppliesItsSettings() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        plan.set(1, { [unowned self] in self.bootstrap(#"{"flushInterval":50,"batchSize":6,"configTTL":700}"#) })
        var ready = false
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.onReady { ready = true }
        waitUntil("ready after the failed bootstrap") { ready }
        let org = self.org
        waitUntil("recovered") { AppDNA.bootstrapOrgIdForTesting == org }
        AppDNA.drainSDKQueueForTesting()
        assertApplied(flush: 50, cap: 6, ttl: 700)
    }
}
