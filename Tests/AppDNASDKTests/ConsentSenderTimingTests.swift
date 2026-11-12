import XCTest
@testable import AppDNASDK

/// The consent sender's real thread interleavings, driven through the real `AppDNA` singleton.
///
/// The enumeration (`ConsentSyncTableEnumerationTests`) walks every short sequence against the pure table, and the
/// shared fixtures settle after every op, so neither ever lets two things happen at once. These cases do: a completion
/// is held at a test latch (`io_return`, after the request returned; `check_act`, after its completion was decided)
/// for 2 s of real time, against the runner's 10 s settle timeout, while another call lands; or the stub holds a
/// request while the SDK's epoch ends. Each runs through `ConsentFixtureCase` (the fixture runner), with the
/// timing ops it has for these tests only.
///
/// Each case states the defect that turns it red. The red controls were run against those exact mutants of the SDK.
@MainActor
final class ConsentSenderTimingTests: XCTestCase {

    private let epoch: Int64 = 946_684_800_000
    private let anon = "anon-device-a"
    private let user = "user-one"

    private func triple(_ analytics: Bool, user u: Any? = nil) -> [String: Any] {
        ["anon_id": anon, "user_id": u ?? user, "analytics": analytics]
    }

    /// A request entry: the body, its `ts_ms` as an offset from the epoch (a range), and an optional gap.
    private func request(_ analytics: Bool, ts: ClosedRange<Int64> = 0...60_000, sincePrev: ClosedRange<Int64>? = nil) -> [String: Any] {
        var body = triple(analytics)
        body["ts_ms"] = ["gte": epoch + ts.lowerBound, "lte": epoch + ts.upperBound]
        var r: [String: Any] = ["method": "POST", "path": ConsentSignalSender.path, "body": body]
        if let s = sincePrev { r["since_prev_ms"] = ["gte": s.lowerBound, "lte": s.upperBound] }
        return r
    }

    private func setup(ack: [String: Any]?, replies: [[String: Any]]) -> [String: Any] {
        var s: [String: Any] = ["clock_epoch_ms": epoch, "anon_id": anon, "persisted_user_id": user, "request_replies": replies]
        if let ack { s["ack_state"] = ack }
        return s
    }

    @discardableResult
    private func run(_ name: String, setup: [String: Any], script: [[String: Any]], expect: [[String: Any]]) async
        -> ConsentFixtureCase.Outcome {
        await ConsentFixtureCase(fixtureId: "consent_sender_timing", json: [
            "name": name, "setup": setup, "script": script, "expect": ["requests": expect],
        ]).run()
    }

    private let configure: [String: Any] = ["kind": "configure"]
    private func setConsent(_ v: Bool, settle: Any? = nil) -> [String: Any] {
        var o: [String: Any] = ["kind": "set_consent", "analytics": v]
        if let settle { o["settle"] = settle }
        return o
    }
    private func arm(_ point: String) -> [String: Any] { ["kind": "arm_latch", "point": point, "hold_ms": 2000] }
    private let awaitLatch: [String: Any] = ["kind": "await_latch"]

    /// Case 1. A completion held at `io_return` while a newer decision arrives: the newer one is kept and sent after
    /// the held one lands, even though it equals the ack the device had before the first send.
    /// Red (a superseded completion clears the newer slot instead of evaluating it): 1 request.
    func testHeldCompletionKeepsTheNewerDecision() async {
        await run("held_completion_at_io_return",
                  setup: setup(ack: triple(true), replies: [["status": 202]]),
                  script: [configure, arm("io_return"), setConsent(false, settle: "pump"), awaitLatch, setConsent(true),
                           ["kind": "assert_ack", "ack": triple(true)]],
                  expect: [request(false), request(true)])
    }

    /// The cross-epoch tie. A dead sender's `false` is held by the server for 2 s and applied last, after the new
    /// epoch's `true`, with the injected clock never advanced. The later decision's `ts_ms` is strictly greater, so
    /// the server's latest row stays `true`.
    /// Red (`ts_ms` taken from the clock alone, no strictly increasing rule): equal `ts_ms`, and the model row ends `false`.
    func testCrossEpochTieKeepsTheLaterDecision() async {
        let out = await run("cross_epoch_tie",
                            setup: setup(ack: triple(true), replies: [["status": 202, "delay_ms": 2000], ["status": 202]]),
                            script: [configure, setConsent(false, settle: "pump"), ["kind": "await_recorded", "count": 1],
                                     ["kind": "shutdown"], setConsent(true), configure, ["kind": "await_stale", "count": 1]],
                            expect: [request(false, ts: 0...0), request(true, ts: 1...1)])
        XCTAssertEqual(out.recorded.count, 2)
        if out.recorded.count == 2 {
            let ts0 = (out.recorded[0].body["ts_ms"] as? NSNumber)?.int64Value ?? 0
            let ts1 = (out.recorded[1].body["ts_ms"] as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(ts1, ts0, "the later decision must carry a strictly greater ts_ms")
        }
        XCTAssertEqual(out.modelAnalytics, true, "the server's latest row must be the later decision")
        XCTAssertGreaterThanOrEqual(out.staleArrivals, 1, "the dead false's completion never reached the fence")
    }

    /// The counter control. The settle must wait for a completion that is owed but not yet run (`completionsPending`),
    /// or a relaunch discards the sender before the ack is written and the next configure re-sends.
    /// Red (no `completionsPending`; `inFlight` decremented at the same site, before the latch): 2 requests.
    func testSettleWaitsForAnOwedCompletion() async {
        await run("counter_control",
                  setup: setup(ack: nil, replies: [["status": 202]]),
                  script: [configure, arm("io_return"), setConsent(true), ["kind": "relaunch"], configure],
                  expect: [request(true)])
    }

    /// The immediate `setConsent`: one made on the configure tick, before the sender exists, is a row-0 call. It
    /// clears the dropped triple, so the configure sends while the ack is unknown. `dropped` = E and the ack unknown
    /// are built in-script by a 400 and a relaunch.
    /// Red (the row-0 flag keyed on `isConfigured`, which `configure()` sets at once): 1 request.
    func testImmediateSetConsentIsARowZeroCall() async {
        await run("immediate_set_consent",
                  setup: setup(ack: triple(true, user: "user-two"), replies: [["status": 400], ["status": 202]]),
                  script: [configure, ["kind": "relaunch"], ["kind": "configure", "settle": false], setConsent(true)],
                  expect: [request(true), request(true)])
    }

    /// Identical bodies. Generation 1 is held at `io_return`; generations 2 and 3 replace it (3 has generation 1's
    /// decision). Every reply is 503. Generation 1's completion is superseded, so generation 3 is sent and retried
    /// on its own: 5 requests, the retries at about 1 s, 2 s and 4 s.
    /// Red (the completion matched to the slot by its decision, not its generation): generation 3 is never sent on its own.
    func testIdenticalBodiesAreToldApartByGeneration() async {
        await run("identical_body",
                  setup: setup(ack: triple(true), replies: [["status": 503]]),
                  script: [configure, arm("io_return"), setConsent(false, settle: "pump"), awaitLatch,
                           setConsent(true, settle: "pump"), setConsent(false, settle: "pump"), ["kind": "settle"],
                           ["kind": "advance_clock_ms", "ms": 30_000]],
                  expect: [request(false, ts: 0...0), request(false, ts: 2...2),
                           request(false, ts: 2...2, sincePrev: 750...1250),
                           request(false, ts: 2...2, sincePrev: 1500...2500),
                           request(false, ts: 2...2, sincePrev: 3000...5000)])
    }

    /// The barrier. A 503's completion is held at `check_act` (decided, not yet acted on) on the executor; a
    /// `setConsent(true)` from another thread lands meanwhile. It must queue behind the completion on the serial
    /// executor, so it cancels the retry the completion arms and is sent next.
    /// Red (the replacement runs on the calling thread, not posted to the executor): the completion's act overwrites
    /// the replacement and its retry re-sends `false`.
    func testAReplacementQueuesBehindAHeldCompletion() async {
        await run("check_act_barrier",
                  setup: setup(ack: triple(true), replies: [["status": 503], ["status": 202]]),
                  script: [configure, arm("check_act"),
                           ["kind": "spawn", "ops": [awaitLatch, ["kind": "set_consent", "analytics": true]]],
                           setConsent(false), ["kind": "join"],
                           ["kind": "advance_clock_ms", "ms": 2000],
                           ["kind": "assert_ack", "ack": triple(true), "dropped": NSNull()]],
                  expect: [request(false), request(true)])
    }
}
