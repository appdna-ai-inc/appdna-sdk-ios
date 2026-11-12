import XCTest
import Foundation
@testable import AppDNASDK

/// drives the consent-signal fixtures (`event_emission/consent_*`, `action.kind == "script"`) through
/// the REAL `AppDNA` singleton: install the clock seam, reset, seed the stores, then run each script op and settle.
///
/// Settling: drain the main queue and the SDK queue (iOS runs every consent trigger on queues that are not injected),
/// pop every due task off the manual scheduler (the consent sender's serial executor runs on this thread), then wait
/// on the sender's idle hook — repeated until nothing is due, nothing is in flight and no completion is pending.
/// `advance_clock_ms` advances deadline by deadline, settling at each, so a chained retry exists.
extension SharedFixtureTests {

    @MainActor
    func runConsentScript(_ fixture: Fixture, _ harness: Harness) async {
        guard let root = Self.fixturesRootURL(),
              let url = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "\(fixture.id).fixture.json" }),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = json["action"] as? [String: Any],
              let cases = action["cases"] as? [[String: Any]] else {
            XCTFail("[\(fixture.id)] could not load the consent cases")
            return
        }
        for c in cases {
            await ConsentFixtureCase(fixtureId: fixture.id, json: c).run()
        }
    }
}

/// An in-memory Keychain that, like the real one, survives a relaunch and a reinstall (the runner keeps it across
/// both) and is emptied only at the start of a case.
final class ConsentFixtureKeychain: KeychainStoring {
    static let shared = ConsentFixtureKeychain()
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var traits: [String: Any]?

    func wipe() { lock.lock(); values = [:]; traits = nil; lock.unlock() }
    private func get(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[k] }
    private func put(_ k: String, _ v: String?) { lock.lock(); values[k] = v; lock.unlock() }

    func getAnonId() -> String? { get("anon_id") }
    func setAnonId(_ id: String) { put("anon_id", id) }
    func getUserId() -> String? { get("user_id") }
    func setUserId(_ id: String) { put("user_id", id) }
    func clearUserId() { put("user_id", nil) }
    func getUserTraits() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return traits }
    func setUserTraits(_ t: [String: Any]) { lock.lock(); traits = t; lock.unlock() }
    func clearUserTraits() { lock.lock(); traits = nil; lock.unlock() }
    func getString(key: String) -> String? { get(key) }
    func setString(key: String, value: String) { put(key, value) }
}

/// The manual serial executor: every task runs on the thread that pops it.
final class ManualConsentScheduler: ConsentScheduler {
    final class Task_: ConsentScheduledToken {
        let due: Int64
        let seq: Int
        let work: () -> Void
        var cancelled = false
        let timed: Bool
        init(due: Int64, seq: Int, timed: Bool, work: @escaping () -> Void) { self.due = due; self.seq = seq; self.timed = timed; self.work = work }
        func cancel() { cancelled = true }
    }

    let epochMs: Int64
    private let lock = NSLock()
    private var current: Int64 = 0
    private var seq = 0
    private var tasks: [Task_] = []

    init(epochMs: Int64) { self.epochMs = epochMs }

    var elapsedMs: Int64 { lock.lock(); defer { lock.unlock() }; return current }
    var nowMs: Int64 { lock.lock(); defer { lock.unlock() }; return epochMs + current }

    func async(_ work: @escaping () -> Void) { _ = enqueue(due: nowMs, timed: false, work) }

    func schedule(atMs: Int64, _ work: @escaping () -> Void) -> ConsentScheduledToken { enqueue(due: atMs, timed: true, work) }

    private func enqueue(due: Int64, timed: Bool, _ work: @escaping () -> Void) -> Task_ {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        let t = Task_(due: due, seq: seq, timed: timed, work: work)
        tasks.append(t)
        return t
    }

    var nextDeadlineMs: Int64? {
        lock.lock(); defer { lock.unlock() }
        return tasks.filter { !$0.cancelled && $0.timed }.map(\.due).min()
    }

    func cancelAll() { lock.lock(); tasks.forEach { $0.cancelled = true }; tasks = []; lock.unlock() }

    var hasDue: Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks.contains { !$0.cancelled && $0.due <= epochMs + current }
    }

    /// Runs every task due now, in (due, seq) order, including ones those tasks enqueue.
    func popDue() {
        while true {
            lock.lock()
            tasks.removeAll { $0.cancelled }
            let now = epochMs + current
            let next = tasks.filter { $0.due <= now }.min { ($0.due, $0.seq) < ($1.due, $1.seq) }
            if let n = next { tasks.removeAll { $0 === n } }
            lock.unlock()
            guard let task = next else { return }
            task.work()
        }
    }

    func advance(toElapsed ms: Int64) { lock.lock(); if ms > current { current = ms }; lock.unlock() }
}

/// Loopback stub: consent POSTs are recorded (with `at_ms` on the injected clock) and answered from the case's
/// replies; bootstrap gets a valid answer; everything else 202 `{}`. A `network_failure` reply reads, then closes.
final class ConsentStubServer: @unchecked Sendable {
    struct Recorded { let atMs: Int64; let body: [String: Any] }
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var _recorded: [Recorded] = []
    private let replies: [[String: Any]]
    private let clock: () -> Int64

    var recorded: [Recorded] { lock.lock(); defer { lock.unlock() }; return _recorded }
    /// A one-row model of the server's `sdk_consent_signals`: each 2xx request is applied when it is answered, by
    /// `ts_ms` with `>=` (a later-answered request with an equal `ts_ms` wins), as the server does.
    private var _modelRow: (tsMs: Int64, analytics: Bool)?
    var modelAnalytics: Bool? { lock.lock(); defer { lock.unlock() }; return _modelRow?.analytics }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init?(replies: [[String: Any]], clock: @escaping () -> Int64) {
        self.replies = replies
        self.clock = clock
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, size) } }
        guard bound == 0, listen(s, 32) == 0 else { close(s); return nil }
        var out = sockaddr_in()
        var outSize = size
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &outSize) } }
        fd = s
        port = UInt16(bigEndian: out.sin_port)
        let listener = s
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Int?
        var contentLength = 0
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            data.append(contentsOf: buffer[0..<n])
            if headerEnd == nil, let r = Self.find([13, 10, 13, 10], in: data) {
                headerEnd = r
                for line in String(decoding: data[0..<r], as: UTF8.self).split(separator: "\r\n") {
                    let p = line.split(separator: ":", maxSplits: 1)
                    if p.count == 2, p[0].lowercased() == "content-length" { contentLength = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
                }
            }
            if let e = headerEnd, data.count >= e + 4 + contentLength { break }
        }
        let head = String(decoding: data[0..<(headerEnd ?? 0)], as: UTF8.self)
        let parts = (head.split(separator: "\r\n").first.map(String.init) ?? "").split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        let start = (headerEnd ?? 0) + 4
        let body = Data(data[start..<min(data.count, start + contentLength)])
        var status = 202
        var payload = "{}"
        var headers: [String: String] = [:]
        if method == "POST" && path == ConsentSignalSender.path {
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); let idx = _recorded.count; _recorded.append(Recorded(atMs: clock(), body: obj)); lock.unlock()
            if !replies.isEmpty {
                let r = replies[min(idx, replies.count - 1)]
                if (r["network_failure"] as? Bool) == true { return }
                status = (r["status"] as? Int) ?? 202
                headers = (r["headers"] as? [String: String]) ?? [:]
                // A per-request delay: the request is held for `delay_ms` of real time before it is applied and answered.
                if let d = (r["delay_ms"] as? NSNumber)?.doubleValue, d > 0 { Thread.sleep(forTimeInterval: d / 1000) }
            }
            if (200..<300).contains(status), let ts = (obj["ts_ms"] as? NSNumber)?.int64Value, let a = obj["analytics"] as? Bool {
                lock.lock()
                if _modelRow == nil || ts >= _modelRow!.tsMs { _modelRow = (ts, a) }
                lock.unlock()
            }
        } else if path.hasPrefix("/api/v1/sdk/bootstrap") {
            status = 200
            payload = #"{"orgId":"org_consent","appId":"app_consent","firestorePath":"orgs/org_consent/apps/app_consent","settings":{}}"#
        }
        let bytes = Array(payload.utf8)
        var reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
        for (k, v) in headers { reply += "\(k): \(v)\r\n" }
        reply += "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        let all = Array(reply.utf8) + bytes
        _ = all.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

/// One consent case.
@MainActor
struct ConsentFixtureCase {
    let fixtureId: String
    let json: [String: Any]
    private let settleTimeoutMs: Int64 = 10_000

    private var name: String { json["name"] as? String ?? "?" }

    /// What a case leaves behind for an SDK-target test to assert beyond `expect.requests`.
    final class Outcome {
        var recorded: [ConsentStubServer.Recorded] = []
        var modelAnalytics: Bool?
        var staleArrivals = 0
    }

    @discardableResult
    func run() async -> Outcome {
        let outcome = Outcome()
        await runInto(outcome)
        return outcome
    }

    private func runInto(_ outcome: Outcome) async {
        let setup = json["setup"] as? [String: Any] ?? [:]
        let script = json["script"] as? [[String: Any]] ?? []
        let expected = (json["expect"] as? [String: Any])?["requests"] as? [[String: Any]] ?? []
        guard let epoch = (setup["clock_epoch_ms"] as? NSNumber)?.int64Value else { return fail("no clock_epoch_ms") }
        guard validate(script) else { return }

        let scheduler = ManualConsentScheduler(epochMs: epoch)
        guard let server = ConsentStubServer(replies: setup["request_replies"] as? [[String: Any]] ?? [], clock: { scheduler.elapsedMs }) else {
            return fail("could not start the stub server")
        }
        defer {
            AppDNA.resetForTesting()
            // Leave nothing behind: a declined decision left in the store makes every later test's events vanish.
            ConsentFixtureKeychain.shared.wipe()
            wipeDefaults()
            ConsentStore.decision = nil
            AppDNA.installConsentClockForTesting(nil)
            AppDNA.keychainStoreFactoryForTesting = nil
            APIBaseURL.infoPlistReaderForTesting = nil
            APIBaseURL.gateForTesting = nil
            server.stop()
        }
        defer {
            outcome.recorded = server.recorded
            outcome.modelAnalytics = server.modelAnalytics
        }
        let spawned = DispatchGroup()
        // install, reset, seed, configure
        AppDNA.installConsentClockForTesting(scheduler)
        AppDNA.keychainStoreFactoryForTesting = { ConsentFixtureKeychain.shared }
        AppDNA.resetForTesting()
        await drainQueues()
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        ConsentFixtureKeychain.shared.wipe()
        wipeDefaults()
        ConsentStore.decision = nil
        do {
            try AppDNA.seedConsentFixtureForTesting(setupJSON: JSONSerialization.data(withJSONObject: setup))
        } catch { return fail("seed failed: \(error)") }

        for (i, op) in script.enumerated() {
            let kind = op["kind"] as? String ?? ""
            switch kind {
            case "configure":
                let rc = op["require_consent"] as? Bool ?? false
                AppDNA.configure(apiKey: "adn_test_consent_fixture_key", environment: .sandbox, options: AppDNAOptions(requireConsent: rc))
            case "set_consent": AppDNA.setConsent(analytics: op["analytics"] as? Bool ?? false)
            case "identify": AppDNA.identify(userId: op["userId"] as? String ?? "")
            case "reset": AppDNA.reset()
            case "shutdown": AppDNA.shutdown()
            case "relaunch": AppDNA.resetForTesting()
            case "reinstall":
                AppDNA.resetForTesting()
                wipeDefaults()
                ConsentStore.decision = nil
            case "advance_clock_ms":
                let ms = (op["ms"] as? NSNumber)?.int64Value ?? 0
                let advanced = await advance(scheduler, by: ms)
                if !advanced { return fail("advance timed out at op \(i)") }
                continue
            // ── SDK-target timing ops (built in code by `ConsentSenderTimingTests`, never in a fixture file) ──
            case "arm_latch":
                AppDNA.setConsentLatchForTesting(point: op["point"] as? String ?? "", holdMs: (op["hold_ms"] as? NSNumber)?.int64Value ?? 0)
                continue
            case "await_latch":
                let engaged = await Task.detached { AppDNA.awaitConsentLatchEngagedForTesting(timeoutMs: 10_000) }.value
                if !engaged { return fail("the latch never engaged at op \(i)") }
                continue
            case "spawn":
                // The ops run in order on another thread, without settling, while this thread goes on.
                let ops = op["ops"] as? [[String: Any]] ?? []
                spawned.enter()
                Thread.detachNewThread {
                    for o in ops { Self.runOffMain(o) }
                    spawned.leave()
                }
                continue
            case "join":
                let joined = await Task.detached { spawned.wait(timeout: .now() + 10) == .success }.value
                if !joined { return fail("a spawned thread did not finish at op \(i)") }
            case "settle": break
            case "await_recorded":
                let n = op["count"] as? Int ?? 1
                let end = Date().addingTimeInterval(Double(settleTimeoutMs) / 1000)
                while server.recorded.count < n {
                    if Date() > end { return fail("the stub never received \(n) request(s) at op \(i)") }
                    await pump(scheduler)
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                continue
            case "await_stale":
                let n = op["count"] as? Int ?? 1
                let end = Date().addingTimeInterval(Double(settleTimeoutMs) / 1000)
                while AppDNA.staleConsentArrivalsForTesting() < n {
                    if Date() > end { return fail("\(n) stale arrival(s) never reached the fence at op \(i)") }
                    await pump(scheduler)
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                outcome.staleArrivals = AppDNA.staleConsentArrivalsForTesting()
            case "assert_ack":
                // The ack record as it is persisted right now, compared exactly (`ack`, and `dropped` when given).
                let raw = ConsentFixtureKeychain.shared.getString(key: ConsentSignalPersistence.ackKey) ?? "{}"
                let rec = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                let want = op["ack"]
                let gotAck = ConsentSignalPersistence.ack(from: rec["ack"])
                let wantAck = (want as? [String: Any]).map { ConsentSignalPersistence.ack(from: $0) } ?? ConsentSignalPersistence.ack(from: want)
                if gotAck != wantAck { fail("op \(i): ack \(gotAck) ≠ \(wantAck)") }
                if op.keys.contains("dropped") {
                    let gotDropped = (rec["dropped"] as? [String: Any]).flatMap(ConsentSignalPersistence.triple(from:))
                    let wantDropped = (op["dropped"] as? [String: Any]).flatMap(ConsentSignalPersistence.triple(from:))
                    if gotDropped != wantDropped { fail("op \(i): dropped \(String(describing: gotDropped)) ≠ \(String(describing: wantDropped))") }
                }
                continue
            default:
                return fail("NO DRIVER for script op '\(kind)' on ios")
            }
            // `settle: false`: the next op follows at once, on the same tick (a call made before configure finished).
            if (op["settle"] as? Bool) == false { continue }
            // `settle: "pump"`: run what is due now (the queues, then the executor) without waiting for the wire, so a
            // request can be held in flight while the next op runs.
            if (op["settle"] as? String) == "pump" { await pump(scheduler); continue }
            let settled = await settle(scheduler)
            if !settled {
                return fail("settle timed out after op \(i) (\(kind)); recorded so far: \(server.recorded.map { $0.body })")
            }
        }
        assertRequests(expected, server.recorded, epoch: epoch)
    }

    private func fail(_ msg: String) { XCTFail("[\(fixtureId) / \(name)] \(msg)") }

    private func validate(_ script: [[String: Any]]) -> Bool {
        var configured = false
        for (i, op) in script.enumerated() {
            let k = op["kind"] as? String ?? ""
            switch k {
            case "configure":
                if configured { fail("configure while configured at op \(i)"); return false }
                configured = true
            case "relaunch", "reinstall": configured = false
            case "shutdown":
                if !configured { fail("shutdown while unconfigured at op \(i)"); return false }
                configured = false
            case "set_consent", "advance_clock_ms", "arm_latch", "await_latch", "spawn", "join", "settle",
                 "await_recorded", "await_stale", "assert_ack": break
            default:
                if !configured { fail("SDK call '\(k)' while unconfigured at op \(i)"); return false }
            }
        }
        return true
    }

    /// Every key the SDK keeps in the standard defaults (the decision, the slot, the last body time …).
    private func wipeDefaults() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("ai.appdna") { d.removeObject(forKey: key) }
        UserDefaults(suiteName: "ai.appdna.sdk.config")?.removePersistentDomain(forName: "ai.appdna.sdk.config")
    }

    private func drainQueues() async {
        // The main queue: post a sentinel behind everything already on it and SUSPEND until it has run. This case runs
        // on the main actor, whose job is itself the main queue's current item, so spinning the run loop here cannot
        // service the main queue: the spin used to sit out its whole 5 s cap on every drain, and two drains used up the
        // 10 s settle before a configure-time send's completion was popped. Suspending yields the main queue.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        await Task.detached { AppDNA.drainSDKQueueForTesting() }.value
    }

    /// Runs what is due now without waiting on the wire: the queues, then every task due on the executor.
    private func pump(_ scheduler: ManualConsentScheduler) async {
        await drainQueues()
        scheduler.popDue()
    }

    /// One op on a spawned thread: an SDK call, or a wait for the latch. Never settles.
    nonisolated private static func runOffMain(_ op: [String: Any]) {
        switch op["kind"] as? String ?? "" {
        case "await_latch":
            if !AppDNA.awaitConsentLatchEngagedForTesting(timeoutMs: 10_000) { XCTFail("spawned: the latch never engaged") }
        case "set_consent": AppDNA.setConsent(analytics: op["analytics"] as? Bool ?? false)
        case "identify": AppDNA.identify(userId: op["userId"] as? String ?? "")
        case "reset": AppDNA.reset()
        case "shutdown": AppDNA.shutdown()
        case "configure":
            AppDNA.configure(apiKey: "adn_test_consent_fixture_key", environment: .sandbox,
                             options: AppDNAOptions(requireConsent: op["require_consent"] as? Bool ?? false))
        case let k: XCTFail("spawned: NO DRIVER for '\(k)' on ios")
        }
    }

    private func settle(_ scheduler: ManualConsentScheduler) async -> Bool {
        let end = Date().addingTimeInterval(Double(settleTimeoutMs) / 1000)
        while Date() < end {
            await drainQueues()
            scheduler.popDue()
            guard let pending = await AppDNA.awaitConsentSenderIdleForTesting(timeoutMs: settleTimeoutMs) else { return false }
            if pending == 0 {
                await drainQueues()
                scheduler.popDue()
                if !scheduler.hasDue, await AppDNA.awaitConsentSenderIdleForTesting(timeoutMs: settleTimeoutMs) == 0, !scheduler.hasDue {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    private func advance(_ scheduler: ManualConsentScheduler, by ms: Int64) async -> Bool {
        let target = scheduler.elapsedMs + ms
        while let d = AppDNA.nextConsentDeadlineForTesting(), d - scheduler.epochMs <= target {
            scheduler.advance(toElapsed: d - scheduler.epochMs)
            let settled = await settle(scheduler)
            if !settled { return false }
        }
        scheduler.advance(toElapsed: target)
        return await settle(scheduler)
    }

    private func assertRequests(_ expected: [[String: Any]], _ actual: [ConsentStubServer.Recorded], epoch: Int64) {
        let got = actual.map { "at \($0.atMs): \($0.body)" }.joined(separator: "\n    ")
        guard expected.count == actual.count else {
            return fail("expected \(expected.count) requests, recorded \(actual.count):\n    \(got)")
        }
        for (i, e) in expected.enumerated() {
            let a = actual[i]
            let where_ = "requests[\(i)] (recorded:\n    \(got))"
            guard let eb = e["body"] as? [String: Any] else { return fail("\(where_): no expected body") }
            if Set(eb.keys) != Set(a.body.keys) { fail("\(where_) keys \(a.body.keys.sorted()) ≠ \(eb.keys.sorted())") }
            if (eb["anon_id"] as? String) != (a.body["anon_id"] as? String) { fail("\(where_) anon_id") }
            if (eb["user_id"] as? String) != (a.body["user_id"] as? String) || ((eb["user_id"] is NSNull) != (a.body["user_id"] is NSNull)) {
                fail("\(where_) user_id \(String(describing: a.body["user_id"]))")
            }
            if (eb["analytics"] as? Bool) != (a.body["analytics"] as? Bool) { fail("\(where_) analytics") }
            inRange("\(where_) body.ts_ms", (a.body["ts_ms"] as? NSNumber)?.int64Value ?? -1, eb["ts_ms"])
            if let m = e["at_ms"] { inRange("\(where_) at_ms", a.atMs, m) }
            if let m = e["since_prev_ms"], i > 0 { inRange("\(where_) since_prev_ms", a.atMs - actual[i - 1].atMs, m) }
        }
    }

    private func inRange(_ what: String, _ v: Int64, _ m: Any?) {
        if let n = m as? NSNumber { if n.int64Value != v { fail("\(what) = \(v) ≠ \(n)") }; return }
        guard let o = m as? [String: Any] else { return }
        if let lo = (o["gte"] as? NSNumber)?.int64Value, v < lo { fail("\(what) = \(v) < \(lo)") }
        if let hi = (o["lte"] as? NSNumber)?.int64Value, v > hi { fail("\(what) = \(v) > \(hi)") }
    }
}
