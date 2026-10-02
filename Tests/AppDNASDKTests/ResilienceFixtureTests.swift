import XCTest
@testable import AppDNASDK

/**
 SPEC-070-B AC-35 — resilience behavioral fixtures (packages/sdk-shared-fixtures/resilience/).

 These are the upload/queue SURVIVAL contracts, and every one of them lives below the bridge: a
 wrapper cannot observe an HTTP status, a `Retry-After` header, or a prune decision. So — exactly like
 `events` — the category is native-only and iOS + Android assert the SAME fixture table.

 Each `contract` maps to a PURE seam, which is why this is a table test rather than an HTTP mock:
   - transient_status  → `APIClient.transientStatusCodes`  (Android: ApiClient.TRANSIENT_STATUS_CODES)
   - retry_after       → `APIClient.parseRetryAfter`       (Android: ApiClient.parseRetryAfter)
   - stale_horizon     → `EventStore.isStale`              (Android: EventDatabase.isStale)
   - permanent_failure → `APIClient.disposition(for:)` + `APIClient.applyEventUploadStatus`
                                                           (Android: ApiClient.dispositionFor)
   - backoff           → `EventQueue.jittered` / `.retryBaseDelays` / `.maxRetries`
                                                           (Android: EventQueue.jittered / RETRY_DELAYS_MS / MAX_RETRIES)
   - flush_cost_bounded → `EventStore.decodedLinesForTesting` over prune / `loadOldest` / `removeSent`
                                                           (Android: EventDatabase.jsonParsesForTest)

 `permanent_failure` is the one that matters most, and it is the one that did not exist. W1 was a LIVE
 iOS defect: a single 429 latched `eventUploadPermanentlyFailed` and halted every event upload until
 the app restarted. No test asserted the flag, because no test could — it only moved inside an async
 method doing a real URLSession round trip. Extracting `applyEventUploadStatus` makes the latch
 drivable without a network, and the fixture now pins it: after a 429, that flag reads FALSE.

 A fixture whose `contract` this runner does not know FAILS. It is never skipped — a silently skipped
 resilience fixture is the coverage theater AC-35 exists to remove.
 */
final class ResilienceFixtureTests: XCTestCase {

    /**
     `retry_after` needs three states per key, not two: KEY ABSENT (the fixture forgot to state an
     expectation — a bug), KEY PRESENT AS NULL (the header is absent / the delay is refused — a real
     case we must assert), and KEY PRESENT WITH A VALUE.

     A `String??` with synthesized Decodable cannot express that: Swift synthesizes `decodeIfPresent`,
     which maps a JSON `null` to `.none` — exactly the same as a missing key. So `.some(nil)` never
     occurs, the "expected refusal" rows collapse into "malformed fixture", and the suite fails.
     (Android's `JSONObject.isNull` distinguishes them for free, which is why only iOS hit this.)
     `contains` + `decodeNil` is the only way to tell the three apart.
     */
    private struct Case: Decodable {
        let status: Int?
        let transient: Bool?
        let headerPresent: Bool
        let header: String?
        let secondsPresent: Bool
        let seconds: Int?
        let age_ms: Int64?
        let stale: Bool?
        let disposition: String?
        // contract=flush_pause_gate
        let trigger: String?
        let clears_pause: Bool?
        // contract=bootstrap_recovery
        let attempt_index: Int?
        let backoff_ms: Int?
        let online: Bool?
        let triggered: Bool?
        let attempts_made: Int?
        let triggers: Int?
        let failure_status: Int?
        let retry_after_s: Int?
        let recovery: String?
        // contract=resolved_events_not_resent
        let mark: [String]?
        let query: String?
        let resolved: Bool?
        // contract=runtime_settings
        let setting: String?
        let explicit: Double?
        let bootstrap: Double?
        let adaptive: Int?
        let cap: Int?
        let expected: Double?

        private enum CodingKeys: String, CodingKey {
            case status, transient, header, seconds, age_ms, stale, disposition, trigger, clears_pause
            case attempt_index, backoff_ms, online, triggered, attempts_made, triggers, failure_status, retry_after_s, recovery
            case mark, query, resolved
            case setting, explicit, bootstrap, adaptive, cap, expected
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(Int.self, forKey: .status)
            transient = try c.decodeIfPresent(Bool.self, forKey: .transient)
            age_ms = try c.decodeIfPresent(Int64.self, forKey: .age_ms)
            stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
            disposition = try c.decodeIfPresent(String.self, forKey: .disposition)
            trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
            clears_pause = try c.decodeIfPresent(Bool.self, forKey: .clears_pause)
            attempt_index = try c.decodeIfPresent(Int.self, forKey: .attempt_index)
            backoff_ms = try c.decodeIfPresent(Int.self, forKey: .backoff_ms)
            online = try c.decodeIfPresent(Bool.self, forKey: .online)
            triggered = try c.decodeIfPresent(Bool.self, forKey: .triggered)
            attempts_made = try c.decodeIfPresent(Int.self, forKey: .attempts_made)
            triggers = try c.decodeIfPresent(Int.self, forKey: .triggers)
            failure_status = try c.decodeIfPresent(Int.self, forKey: .failure_status)
            retry_after_s = try c.decodeIfPresent(Int.self, forKey: .retry_after_s)
            recovery = try c.decodeIfPresent(String.self, forKey: .recovery)
            mark = try c.decodeIfPresent([String].self, forKey: .mark)
            query = try c.decodeIfPresent(String.self, forKey: .query)
            resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved)
            setting = try c.decodeIfPresent(String.self, forKey: .setting)
            explicit = try c.decodeIfPresent(Double.self, forKey: .explicit)
            bootstrap = try c.decodeIfPresent(Double.self, forKey: .bootstrap)
            adaptive = try c.decodeIfPresent(Int.self, forKey: .adaptive)
            cap = try c.decodeIfPresent(Int.self, forKey: .cap)
            expected = try c.decodeIfPresent(Double.self, forKey: .expected)

            // Plain statements, not a `&&` inside a ternary: `decodeNil` throws, and Swift will not
            // let a throwing call sit inside a short-circuit operand.
            headerPresent = c.contains(.header)
            let headerIsNull = headerPresent ? try c.decodeNil(forKey: .header) : true
            header = headerIsNull ? nil : try c.decode(String.self, forKey: .header)

            secondsPresent = c.contains(.seconds)
            let secondsIsNull = secondsPresent ? try c.decodeNil(forKey: .seconds) : true
            seconds = secondsIsNull ? nil : try c.decode(Int.self, forKey: .seconds)
        }
    }

    /// One step of the `permanent_failure` latch sequence. ORDER is the assertion.
    private struct LatchStep: Decodable {
        let status: Int
        let permanently_failed: Bool
    }

    private struct Resilience: Decodable {
        let contract: String
        let horizon_ms: Int64?
        /// Optional: `backoff` asserts a DISTRIBUTION and carries no case table.
        let cases: [Case]?
        // contract=backoff
        let max_retries: Int?
        let base_delays_ms: [Int]?
        let jitter_pct: Double?
        let samples: Int?
        let min_distinct_samples: Int?
        let max_total_backoff_ms: Int?
        // contract=permanent_failure
        let latch: [LatchStep]?
        // contract=bootstrap_recovery
        let max_attempts: Int?
        let trigger_delay_max_ms: Int?
        // contract=resolved_events_not_resent
        let max_resolved: Int?
        let queue: QueueRow?
        // contract=flush_pause_gate
        let os_upload: OSUpload?
        // contract=runtime_settings
        let defaults: RuntimeDefaults?
        // contract=flush_cost_bounded
        let cost: Cost?
    }

    private struct RuntimeDefaults: Decodable {
        let flush_interval: Double
        let batch_size: Int?
        let config_ttl: Double
    }

    private struct Cost: Decodable {
        let backlogs: [Int]
        let stale: Int
        let batch: Int
        let flushes: Int
        let extra_lines_decoded: Int
    }

    private struct QueueRow: Decodable {
        let loaded: [String]
        let resolved_elsewhere: [String]
        let sent: [String]
    }

    private struct OSUpload: Decodable {
        let background_schedules_when_paused: Bool
        let background_schedules_when_unpaused: Bool
        let worker_uploads_when_paused: Bool
        let worker_uploads_when_unpaused: Bool
    }

    private struct Fixture: Decodable {
        let id: String
        let category: String
        let platforms: [String]
        let resilience: Resilience
    }

    func testResilienceFixtures() throws {
        let fixtures = try loadResilienceFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No resilience fixtures found — the category must not silently vanish")

        var seenContracts = Set<String>()

        for f in fixtures {
            seenContracts.insert(f.resilience.contract)

            switch f.resilience.contract {
            case "transient_status":
                for c in try requireCases(f) {
                    guard let status = c.status, let expected = c.transient else {
                        return XCTFail("[\(f.id)] transient_status case needs `status` and `transient`")
                    }
                    XCTAssertEqual(
                        APIClient.transientStatusCodes.contains(status), expected,
                        "[\(f.id)] HTTP \(status) transient?"
                    )
                }

            case "retry_after":
                for c in try requireCases(f) {
                    guard c.headerPresent, c.secondsPresent else {
                        return XCTFail("[\(f.id)] retry_after case must state both `header` and `seconds` (null is a value, not an omission)")
                    }
                    let actual = APIClient.parseRetryAfter(c.header)
                    let label = "[\(f.id)] Retry-After \(c.header.map { "\"\($0)\"" } ?? "(absent)")"
                    if let expected = c.seconds {
                        XCTAssertEqual(actual, TimeInterval(expected), label)
                    } else {
                        XCTAssertNil(actual, "\(label) must be refused")
                    }
                }

            case "stale_horizon":
                guard let horizon = f.resilience.horizon_ms else {
                    return XCTFail("[\(f.id)] stale_horizon needs `horizon_ms`")
                }
                // A fixed `now` keeps the table exact: age is what varies, not the wall clock.
                let now: Int64 = 1_800_000_000_000
                for c in try requireCases(f) {
                    guard let ageMs = c.age_ms, let expected = c.stale else {
                        return XCTFail("[\(f.id)] stale_horizon case needs `age_ms` and `stale`")
                    }
                    XCTAssertEqual(
                        EventStore.isStale(tsMs: now - ageMs, nowMs: now, horizonMs: horizon), expected,
                        "[\(f.id)] age \(ageMs)ms stale?"
                    )
                }

            // AC-35 — the full three-way classification AND the real latch.
            //
            // 🔴 This is the fixture that would have caught the live defect. `eventUploadPermanentlyFailed`
            // is what a 429 used to set, and setting it halted EVERY event upload for the rest of the
            // process. Nothing asserted the flag — not because nobody thought to, but because nobody
            // COULD: it only ever moved inside `sendEvents`, an async method that performs a real
            // URLSession round trip. `applyEventUploadStatus` is that method's body, extracted; driving
            // it here drives the same flag the network path drives, with no network.
            case "permanent_failure":
                for c in try requireCases(f) {
                    guard let status = c.status, let want = c.disposition else {
                        return XCTFail("[\(f.id)] permanent_failure case needs `status` and `disposition`")
                    }
                    let actual: String
                    switch APIClient.disposition(for: status) {
                    case .success: actual = "success"
                    case .retryTransient: actual = "retry_transient"
                    case .dropPermanent: actual = "drop_permanent"
                    }
                    XCTAssertEqual(actual, want, "[\(f.id)] HTTP \(status) disposition")
                }

                guard let latch = f.resilience.latch else {
                    return XCTFail("[\(f.id)] permanent_failure must state a `latch` sequence — the 429 defect WAS the latch")
                }
                // ONE client across the whole sequence: the latch is stateful, and "a 429 does not
                // clear a latch a 401 set" is only sayable as a sequence.
                let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
                XCTAssertFalse(
                    client.eventUploadPermanentlyFailed,
                    "[\(f.id)] a fresh client must not start latched"
                )
                for step in latch {
                    client.applyEventUploadStatus(step.status, retryAfterHeader: nil)
                    XCTAssertEqual(
                        client.eventUploadPermanentlyFailed, step.permanently_failed,
                        "[\(f.id)] after HTTP \(step.status), eventUploadPermanentlyFailed"
                    )
                }

            // AC-35 — bounded AND jittered. Both halves, because each hides the other's failure: a
            // `return base` regression satisfies every bound, and an unbounded jitter is still
            // "jittered". Drives the real `EventQueue.jittered`, not a copy of its arithmetic.
            case "backoff":
                guard let maxRetries = f.resilience.max_retries,
                      let bases = f.resilience.base_delays_ms,
                      let jitterPct = f.resilience.jitter_pct,
                      let samples = f.resilience.samples,
                      let minDistinct = f.resilience.min_distinct_samples,
                      let maxTotal = f.resilience.max_total_backoff_ms
                else {
                    return XCTFail("[\(f.id)] backoff needs max_retries, base_delays_ms, jitter_pct, samples, min_distinct_samples, max_total_backoff_ms")
                }

                XCTAssertEqual(EventQueue.maxRetries, maxRetries, "[\(f.id)] retry count")
                XCTAssertEqual(EventQueue.jitterFraction, jitterPct, accuracy: 1e-9, "[\(f.id)] jitter fraction")
                // The fixture states the schedule in MILLIseconds; iOS holds it in seconds.
                XCTAssertEqual(
                    EventQueue.retryBaseDelays.map { Int(($0 * 1000).rounded()) }, bases,
                    "[\(f.id)] base backoff schedule"
                )

                for baseMs in bases {
                    let base = TimeInterval(baseMs) / 1000
                    let lo = base * (1 - jitterPct)
                    let hi = base * (1 + jitterPct)
                    var seen = Set<TimeInterval>()
                    for _ in 0..<samples {
                        let d = EventQueue.jittered(base)
                        XCTAssertTrue(
                            d >= lo && d <= hi,
                            "[\(f.id)] jittered(\(base)) = \(d) escaped [\(lo), \(hi)] — the backoff is not bounded"
                        )
                        XCTAssertTrue(d >= 0, "[\(f.id)] jittered(\(base)) = \(d) is negative")
                        seen.insert(d)
                    }
                    XCTAssertGreaterThanOrEqual(
                        seen.count, minDistinct,
                        "[\(f.id)] jittered(\(base)) produced only \(seen.count) distinct value(s) over \(samples) samples — the jitter is not being applied, and a throttled fleet will retry in lockstep"
                    )
                }

                // "Bounded" is a claim about the TOTAL, not about one delay: MAX_RETRIES retries, each
                // at its worst-case jittered ceiling.
                var worstCaseTotalMs = 0.0
                for attempt in 1...maxRetries {
                    let baseMs = Double(bases[min(attempt - 1, bases.count - 1)])
                    worstCaseTotalMs += baseMs * (1 + jitterPct)
                }
                XCTAssertLessThanOrEqual(
                    Int(worstCaseTotalMs), maxTotal,
                    "[\(f.id)] worst-case total backoff \(Int(worstCaseTotalMs))ms exceeds the \(maxTotal)ms bound"
                )

            // Which flush triggers clear the paused-after-N-failures gate. Drives the real
            // `EventQueue.FlushTrigger` every flush path goes through; the table must name every case.
            case "flush_pause_gate":
                var named = Set<EventQueue.FlushTrigger>()
                for c in try requireCases(f) {
                    guard let name = c.trigger, let want = c.clears_pause else {
                        return XCTFail("[\(f.id)] flush_pause_gate case needs `trigger` and `clears_pause`")
                    }
                    guard let trigger = EventQueue.FlushTrigger(rawValue: name) else {
                        return XCTFail("[\(f.id)] unknown flush trigger '\(name)'")
                    }
                    named.insert(trigger)
                    XCTAssertEqual(trigger.clearsPauseGate, want, "[\(f.id)] does a \(name) flush clear the pause?")
                }
                XCTAssertEqual(named, Set(EventQueue.FlushTrigger.allCases), "[\(f.id)] the table must name every FlushTrigger")

                // The pause holds for the OS background uploader: drives the real `enterBackground` of a real
                // queue (paused / not) and the gate `BackgroundUploader` reads before it uploads.
                guard let os = f.resilience.os_upload else {
                    return XCTFail("[\(f.id)] flush_pause_gate needs `os_upload`")
                }
                for paused in [true, false] {
                    let scheduled = Counter()
                    EventQueue.scheduleBackgroundUploadForTesting = { scheduled.bump() }
                    defer { EventQueue.scheduleBackgroundUploadForTesting = nil }
                    let store = EventStore(fileName: "pause-os-\(UUID().uuidString).json")
                    defer { store.clearAll() }
                    let tracker = EventTracker(identityManager: IdentityManager(
                        keychainStore: KeychainStore(service: "ai.appdna.sdk.test.pauseos.\(UUID().uuidString)")))
                    let q = EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                                       eventStore: store, eventTracker: tracker, batchSizeCap: nil, flushInterval: 3600)
                    if paused { q.pauseForTesting() }
                    q.enterBackground(holdBackgroundTask: false)
                    let deadline = Date().addingTimeInterval(1)
                    while Date() < deadline && scheduled.value == 0 { Thread.sleep(forTimeInterval: 0.02) }
                    XCTAssertEqual(scheduled.value > 0,
                                   paused ? os.background_schedules_when_paused : os.background_schedules_when_unpaused,
                                   "[\(f.id)] does backgrounding schedule the background upload (paused=\(paused))?")
                    // The real background run (`BackgroundUploader.runUpload`, the BGProcessingTask's body) with
                    // the gate production hands it, against a closed port: paused it stops at the gate; not
                    // paused it goes on and tries (the send fails — the event stays).
                    let uploadStore = EventStore(fileName: "pause-os-run-\(UUID().uuidString).json")
                    defer { uploadStore.clearAll() }
                    uploadStore.save(events: [EventEnvelopeBuilder.build(
                        event: "pause_os", properties: nil,
                        identity: DeviceIdentity(anonId: "pause-os-anon", userId: nil, traits: nil),
                        sessionId: "pause-os-session", analyticsConsent: true)])
                    APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? "http://127.0.0.1:9" : nil }
                    APIBaseURL.gateForTesting = { true }
                    let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
                    let uploader = BackgroundUploader(apiClient: client, eventStore: uploadStore)
                    let outcome = Self.runBlocking { await uploader.runUpload(paused: UploadPauseGate.isPaused, reschedule: {}) }
                    APIBaseURL.infoPlistReaderForTesting = nil
                    APIBaseURL.gateForTesting = nil
                    XCTAssertEqual(outcome != .skippedPaused,
                                   paused ? os.worker_uploads_when_paused : os.worker_uploads_when_unpaused,
                                   "[\(f.id)] does a background run upload (paused=\(paused))? outcome=\(String(describing: outcome))")
                    XCTAssertEqual(uploadStore.loadPending().count, 1, "[\(f.id)] the background run lost the event")
                    withExtendedLifetime((q, client)) {}
                }
                UploadPauseGate.setForTesting(false)

            // The retry loop of a failed bootstrap: its backoff schedule and bound, and — driving the real
            // `BootstrapRecovery` with a long backoff, so only a trigger can start an attempt — that an attempt
            // is made only for a trigger while online.
            case "bootstrap_recovery":
                XCTAssertEqual(BootstrapRecovery.defaultMaxAttempts, f.resilience.max_attempts, "[\(f.id)] max_attempts")
                XCTAssertEqual(BootstrapRecovery.jitterFraction, f.resilience.jitter_pct, "[\(f.id)] jitter_pct")
                XCTAssertEqual(Int(BootstrapRecovery.defaultTriggerDelayMax * 1000), f.resilience.trigger_delay_max_ms,
                               "[\(f.id)] trigger_delay_max_ms")
                if let pct = f.resilience.jitter_pct {
                    // The jitter spans exactly ±pct of the base, and is not a constant.
                    XCTAssertEqual(BootstrapRecovery.jittered(10, unit: 0), 10 * (1 - pct), accuracy: 1e-9, "[\(f.id)] lowest jitter")
                    XCTAssertEqual(BootstrapRecovery.jittered(10, unit: 0.5), 10, accuracy: 1e-9, "[\(f.id)] middle jitter")
                    XCTAssertLessThan(BootstrapRecovery.jittered(10, unit: 0.999_999), 10 * (1 + pct) + 1e-9, "[\(f.id)] highest jitter")
                }
                func outcome(_ status: Int, _ retryAfter: Int?) -> BootstrapRecovery.Outcome {
                    BootstrapRecovery.outcome(failureStatus: status == 0 ? nil : status, retryAfter: retryAfter.map(TimeInterval.init))
                }
                for c in try requireCases(f) {
                    if let index = c.attempt_index, let ms = c.backoff_ms {
                        XCTAssertEqual(Int(BootstrapRecovery.defaultBackoff(index) * 1000), ms, "[\(f.id)] backoff before attempt \(index + 1)")
                    } else if let online = c.online, let want = c.attempts_made {
                        let triggers = c.triggers ?? ((c.triggered ?? false) ? 1 : 0)
                        let answer: BootstrapRecovery.Outcome = c.failure_status.map { outcome($0, c.retry_after_s) } ?? .done
                        let recovery = BootstrapRecovery(isOnline: { online }, backoff: { _ in 3600 },
                                                         random: { 0 }, triggerDelayMax: 0)
                        let made = Counter()
                        recovery.start { made.bump(); return answer }
                        for t in 0..<triggers {
                            recovery.trigger()
                            let deadline = Date().addingTimeInterval(0.5)
                            while Date() < deadline && made.value <= t { Thread.sleep(forTimeInterval: 0.02) }
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                        recovery.stop()
                        XCTAssertEqual(made.value, want,
                                       "[\(f.id)] attempts with online=\(online) triggers=\(triggers) failure=\(String(describing: c.failure_status))")
                    } else if let status = c.failure_status, let want = c.recovery {
                        let got: String
                        switch outcome(status, c.retry_after_s) {
                        case .stop: got = "stop"
                        case .retry: got = "retry"
                        case .retryAfter(let s):
                            got = "retry_after"
                            XCTAssertEqual(Int(s), c.retry_after_s, "[\(f.id)] the Retry-After honoured after \(status)")
                        case .done: got = "done"
                        }
                        XCTAssertEqual(got, want, "[\(f.id)] what follows a failed attempt with \(status)")
                    } else {
                        XCTFail("[\(f.id)] bootstrap_recovery case needs attempt_index+backoff_ms, online+attempts_made, or failure_status+recovery")
                    }
                }

            // The process-wide registry every upload owner records its resolved event ids in (and a queue
            // consults before it uploads). Drives the real `EventUploadCoordinator`; cases run in order.
            case "resolved_events_not_resent":
                XCTAssertEqual(EventUploadCoordinator.maxResolved, f.resilience.max_resolved, "[\(f.id)] max_resolved")
                EventUploadCoordinator.clearResolvedForTesting()
                defer { EventUploadCoordinator.clearResolvedForTesting() }
                for c in try requireCases(f) {
                    guard let query = c.query, let want = c.resolved else {
                        return XCTFail("[\(f.id)] resolved_events_not_resent case needs `query` and `resolved`")
                    }
                    EventUploadCoordinator.markResolved(c.mark ?? [])
                    XCTAssertEqual(EventUploadCoordinator.wasResolved(query), want, "[\(f.id)] is '\(query)' resolved?")
                }
                // The bound: the oldest id leaves once max_resolved newer ones are recorded.
                if let max = f.resilience.max_resolved {
                    EventUploadCoordinator.clearResolvedForTesting()
                    EventUploadCoordinator.markResolved((0...max).map { "bound-\($0)" })
                    XCTAssertFalse(EventUploadCoordinator.wasResolved("bound-0"), "[\(f.id)] the registry is not bounded")
                    XCTAssertTrue(EventUploadCoordinator.wasResolved("bound-\(max)"))
                }
                // A real queue: it loaded these events from its store; another owner then resolved some of
                // them; its next upload sends only the rest.
                guard let row = f.resilience.queue else {
                    return XCTFail("[\(f.id)] resolved_events_not_resent needs the `queue` row")
                }
                try assertQueueDoesNotResend(row, id: f.id)

            // Host option > bootstrap value (positive only) > default, and the batch size in effect. Drives the
            // real `RuntimeSettings.resolveAll` (through `AppDNAOptions`, so the explicit / unset distinction
            // is the one a host makes) and `RuntimeSettings.effectiveBatchSize`, the seam the queue and the
            // background uploader both size batches with.
            case "runtime_settings":
                guard let d = f.resilience.defaults else { return XCTFail("[\(f.id)] runtime_settings needs `defaults`") }
                XCTAssertEqual(RuntimeSettings.defaultFlushInterval, d.flush_interval, "[\(f.id)] default flushInterval")
                XCTAssertEqual(RuntimeSettings.defaultConfigTTL, d.config_ttl, "[\(f.id)] default configTTL")
                XCTAssertEqual(RuntimeSettings.resolveAll(options: AppDNAOptions(), bootstrap: nil).batchSizeCap, d.batch_size,
                               "[\(f.id)] default batchSize cap")
                for c in try requireCases(f) {
                    guard let setting = c.setting else { return XCTFail("[\(f.id)] runtime_settings case needs `setting`") }
                    if setting == "effective_batch_size" {
                        guard let adaptive = c.adaptive, let want = c.expected else {
                            return XCTFail("[\(f.id)] effective_batch_size case needs `adaptive` and `expected`")
                        }
                        XCTAssertEqual(RuntimeSettings.effectiveBatchSize(adaptive: adaptive, cap: c.cap), Int(want),
                                       "[\(f.id)] effective batch size, adaptive=\(adaptive) cap=\(String(describing: c.cap))")
                        continue
                    }
                    let b = c.bootstrap.map(Int.init)
                    let options: AppDNAOptions
                    let boot: BootstrapSettings
                    switch setting {
                    case "flush_interval":
                        options = AppDNAOptions(flushInterval: c.explicit)
                        boot = Self.bootstrapSettings(flushInterval: b)
                    case "config_ttl":
                        options = AppDNAOptions(configTTL: c.explicit)
                        boot = Self.bootstrapSettings(configTTL: b)
                    case "batch_size":
                        options = AppDNAOptions(batchSize: c.explicit.map(Int.init))
                        boot = Self.bootstrapSettings(batchSize: b)
                    default:
                        return XCTFail("[\(f.id)] unknown runtime setting '\(setting)'")
                    }
                    let r = RuntimeSettings.resolveAll(options: options, bootstrap: boot)
                    let got: Double? = setting == "flush_interval" ? r.flushInterval
                        : setting == "config_ttl" ? r.configTTL : r.batchSizeCap.map(Double.init)
                    XCTAssertEqual(got, c.expected,
                                   "[\(f.id)] \(setting): explicit=\(String(describing: c.explicit)) bootstrap=\(String(describing: c.bootstrap))")
                }
            // A flush's store work decodes only the batch it returns, whatever the backlog (the store's index).
            case "flush_cost_bounded":
                guard let cost = f.resilience.cost else {
                    return XCTFail("[\(f.id)] flush_cost_bounded needs the `cost` row")
                }
                assertFlushCostBounded(cost, id: f.id)

            default:
                XCTFail("[\(f.id)] unknown resilience contract '\(f.resilience.contract)' — this runner must assert it, never skip it")
            }
        }

        // Every contract the schema defines must actually be exercised, or a fixture could be deleted
        // and this suite would still go green on the survivors.
        XCTAssertEqual(
            seenContracts,
            ["transient_status", "retry_after", "stale_horizon", "permanent_failure", "backoff", "flush_pause_gate",
             "bootstrap_recovery", "resolved_events_not_resent", "runtime_settings", "flush_cost_bounded"],
            "every resilience contract must be covered by a fixture"
        )
    }

    /// A decoded bootstrap `settings` object carrying only the given runtime values (what the server sends).
    static func bootstrapSettings(flushInterval: Int? = nil, batchSize: Int? = nil, configTTL: Int? = nil) -> BootstrapSettings {
        var o: [String: Any] = [:]
        if let flushInterval { o["flushInterval"] = flushInterval }
        if let batchSize { o["batchSize"] = batchSize }
        if let configTTL { o["configTTL"] = configTTL }
        let data = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(BootstrapSettings.self, from: data)
    }

    private func assertFlushCostBounded(_ cost: Cost, id: String) {
        let savedDropped = DroppedEventsCounter.getAndReset()
        defer {
            _ = DroppedEventsCounter.getAndReset()
            if savedDropped > 0 { DroppedEventsCounter.increment(savedDropped) }
        }
        func build(_ name: String, tsMs: Int64? = nil) -> SDKEvent {
            let e = EventEnvelopeBuilder.build(event: name, properties: ["k": "v"],
                                               identity: DeviceIdentity(anonId: "cost-anon", userId: nil, traits: nil),
                                               sessionId: "cost-session", analyticsConsent: true)
            guard let tsMs else { return e }
            return SDKEvent(schema_version: e.schema_version, event_id: e.event_id, event_name: e.event_name, ts_ms: tsMs,
                            user: e.user, device: e.device, context: e.context, properties: e.properties, privacy: e.privacy)
        }
        let old = Int64(Date().timeIntervalSince1970 * 1000) - EventStore.redeliveryHorizonMs - 60_000
        for backlog in cost.backlogs {
            _ = DroppedEventsCounter.getAndReset()
            let store = EventStore(fileName: "flush-cost-\(UUID().uuidString).json")
            defer { store.clearAll() }
            store.save(events: (0..<cost.stale).map { build("stale_\($0)", tsMs: old) } + (0..<backlog).map { build("e_\($0)") })
            XCTAssertEqual(store.pendingCount, cost.stale + backlog, "[\(id)] seeded")
            let before = store.decodedLinesForTesting
            var returned = 0, pruned = 0
            for _ in 0..<cost.flushes {
                pruned += store.pruneStale()
                let batch = store.loadOldest(cost.batch)
                returned += batch.count
                store.removeSent(eventIds: Set(batch.map(\.event_id)))
            }
            let extra = store.decodedLinesForTesting - before - returned
            XCTAssertEqual(extra, cost.extra_lines_decoded, "[\(id)] backlog \(backlog): \(extra) lines decoded beyond the batches")
            XCTAssertEqual(pruned, cost.stale, "[\(id)] backlog \(backlog): stale events pruned")
            XCTAssertEqual(DroppedEventsCounter.peek(), cost.stale, "[\(id)] backlog \(backlog): the prune is counted")
            XCTAssertEqual(returned, cost.batch * cost.flushes, "[\(id)] backlog \(backlog): batches taken")
            XCTAssertEqual(store.pendingCount, backlog - cost.batch * cost.flushes, "[\(id)] backlog \(backlog): events left")
        }
    }

    private func assertQueueDoesNotResend(_ row: QueueRow, id: String) throws {
        EventUploadCoordinator.clearResolvedForTesting()
        defer { EventUploadCoordinator.clearResolvedForTesting() }
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in .init(status: 200, headers: [:], body: "{}") },
                                   "could not open a local socket")
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        defer {
            server.stop()
            APIBaseURL.infoPlistReaderForTesting = nil
            APIBaseURL.gateForTesting = nil
        }
        let store = EventStore(fileName: "resolved-queue-\(UUID().uuidString).json")
        defer { store.clearAll() }
        // The SDK assigns event ids: the fixture's names map to the ids the builder gave.
        var idOf: [String: String] = [:]
        var events: [SDKEvent] = []
        for name in row.loaded {
            let e = EventEnvelopeBuilder.build(event: "resolved_queue", properties: nil,
                                               identity: DeviceIdentity(anonId: "resolved-anon", userId: nil, traits: nil),
                                               sessionId: "resolved-session", analyticsConsent: true)
            idOf[name] = e.event_id
            events.append(e)
        }
        store.save(events: events)
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.resolvedqueue.\(UUID().uuidString)")))
        let q = EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                           eventStore: store, eventTracker: tracker, batchSizeCap: nil, flushInterval: 3600)
        EventUploadCoordinator.markResolved(row.resolved_elsewhere.compactMap { idOf[$0] })
        q.flushClearingPause()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !server.requests.contains(where: { $0.contains("/ingest/events") }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        var sent: [String] = []
        for (label, body) in server.bodies where label.contains("/ingest/events") {
            let raw = (try? (body as NSData).decompressed(using: .zlib) as Data) ?? body
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            for e in (json["batch"] as? [[String: Any]]) ?? [] { if let i = e["event_id"] as? String { sent.append(i) } }
        }
        let nameOf = Dictionary(uniqueKeysWithValues: idOf.map { ($1, $0) })
        XCTAssertEqual(sent.map { nameOf[$0] ?? $0 }.sorted(), row.sent.sorted(),
                       "[\(id)] the queue sent events another owner had already resolved")
        withExtendedLifetime(q) {}
    }

    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    /// Runs `body` to completion on a detached task and waits for it (the runner is synchronous).
    static func runBlocking<T>(timeout: TimeInterval = 30, _ body: @escaping @Sendable () async -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await body(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
        return box.value
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// The three table contracts require a case table; `backoff` does not carry one. A fixture that
    /// omits it is malformed, never skipped.
    private func requireCases(_ f: Fixture) throws -> [Case] {
        guard let cases = f.resilience.cases, !cases.isEmpty else {
            XCTFail("[\(f.id)] contract '\(f.resilience.contract)' requires a non-empty `cases` table")
            return []
        }
        return cases
    }

    private func loadResilienceFixtures() throws -> [Fixture] {
        guard let root = SharedFixtureTests.fixturesRootURL()?.appendingPathComponent("resilience") else {
            XCTFail("Could not locate packages/sdk-shared-fixtures/resilience")
            return []
        }
        let urls = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".fixture.json") }
            .sorted { $0.path < $1.path }

        let decoder = JSONDecoder()
        return try urls.compactMap { url in
            let f = try decoder.decode(Fixture.self, from: Data(contentsOf: url))
            guard f.category == "resilience", f.platforms.contains("ios") else { return nil }
            return f
        }
    }
}
