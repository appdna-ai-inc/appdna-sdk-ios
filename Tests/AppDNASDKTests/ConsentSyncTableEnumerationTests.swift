import XCTest
@testable import AppDNASDK

/// The consent state table, enumerated exhaustively (breadth-first over distinct states). The iOS twin of Android's
/// `ConsentSyncTableEnumerationTest`: every sequence of up to `depth` events from 18 start states drives the
/// PRODUCTION `ConsentSyncTable.next` inside a model of one device, its sender epochs and a server that applies each
/// request to one row per (anon, user) by `(ts_ms, seq)` with `>=`. Each event takes zero or one tick.
///
/// Invariant 1: whenever nothing is outstanding, the server's latest row equals the device's last decision unless it
/// was dropped (no row counts as granted). Invariant 2: relaunch + configure with every later request answered 2xx
/// leaves the server's latest row equal to E, unless the dropped triple equals E.
///
/// Red controls, each of which must FAIL: TIE (`ts_ms` without `last_body_ts`), NO_FENCE (a dead sender's 2xx writes
/// the ack and clears an equal slot), NO_WRITE_AHEAD (a SEND leaves the ack as it was).
final class ConsentSyncTableEnumerationTests: XCTestCase {
    typealias T = ConsentSyncTable

    enum Variant { case production, tie, noFence, noWriteAhead }

    struct Row: Hashable { let analytics: Bool; let ts: Int64; let seq: Int }
    struct Req: Hashable { let triple: T.Triple; let ts: Int64; let generation: Int64 }

    struct World: Hashable {
        var table: T.State
        var decision: Bool?
        var user: String?
        var configured: Bool
        var rowZero: Bool
        var clock: Int64
        var dead: [Req]
        var server: [String: Row]
        var seq: Int
        var lastDecision: T.Triple?
        var e: T.Triple { T.Triple(anonId: "A", userId: user, analytics: decision ?? true) }
    }

    static let depth = 5

    struct Sim {
        let variant: Variant

        func step(_ w: World, _ ev: T.Event) -> World {
            let prev = w.table
            var input = prev
            if variant == .tie { input.lastBodyTs = nil }
            var (t, fx) = T.next(input, ev)
            if variant == .noWriteAhead, fx.contains(where: { if case .send = $0 { return true }; return false }) { t.ack = prev.ack }
            var out = w
            out.table = t
            if t.lastGeneration > prev.lastGeneration {
                switch ev {
                case let .setConsent(e, _), let .userChanged(e, _), let .configure(e, _, _): out.lastDecision = e
                default: break
                }
            }
            return out
        }

        func apply(_ w: World, _ r: Req) -> World {
            var out = w
            let key = r.triple.userId ?? ""
            out.seq += 1
            if let row = w.server[key], r.ts < row.ts { return out }
            out.server[key] = Row(analytics: r.triple.analytics, ts: r.ts, seq: out.seq)
            return out
        }

        func req(_ s: T.Slot) -> Req { Req(triple: s.triple, ts: s.tsMs, generation: s.generation) }

        func configure(_ w: World) -> World {
            var c = w
            c.configured = true
            c.rowZero = false
            return step(c, .configure(effective: c.e, rowZeroCall: w.rowZero, nowMs: w.clock))
        }

        func end(_ w: World) -> World {
            var o = w
            if let f = w.table.inFlight { o.dead.append(req(f)) }
            o.table.inFlight = nil
            o.table.timer = nil
            o.configured = false
            o.rowZero = false
            return o
        }

        func deadArrives(_ w: World, _ i: Int, _ r: Req) -> World {
            var o = w
            o.dead.remove(at: i)
            guard variant == .noFence, o.configured else { return o }
            o.table.ack = .known(r.triple)
            o.table.dropped = nil
            if o.table.inFlight == nil, o.table.timer == nil, o.table.slot?.triple == r.triple { o.table.slot = nil }
            return o
        }

        func successors(_ w: World) -> [(String, World)] {
            var out: [(String, World)] = []
            func add(_ label: String, _ f: (World) -> World?) {
                for tick: Int64 in [0, 1] {
                    var s = w
                    s.clock += tick
                    if let n = f(s) { out.append(("\(label)\(tick == 1 ? "+1" : "")", n)) }
                }
            }
            for v in [true, false] {
                add("setConsent(\(v))") { s in
                    var d = s; d.decision = v
                    if s.configured { return step(d, .setConsent(effective: d.e, nowMs: s.clock)) }
                    d.rowZero = true; return d
                }
            }
            if w.configured && w.user != "U2" { add("identify(U2)") { s in var d = s; d.user = "U2"; return step(d, .userChanged(effective: d.e, nowMs: s.clock)) } }
            if w.configured && w.user != nil { add("reset") { s in var d = s; d.user = nil; return step(d, .userChanged(effective: d.e, nowMs: s.clock)) } }
            if let f = w.table.inFlight {
                let r = req(f)
                add("2xx") { s in step(apply(s, r), .success(generation: f.generation)) }
                add("transient-applied") { s in step(apply(s, r), .transient(generation: f.generation, retryAfterSeconds: nil)) }
                add("503") { s in step(s, .transient(generation: f.generation, retryAfterSeconds: nil)) }
                add("400") { s in step(s, .drop(generation: f.generation)) }
            }
            if let g = w.table.timer { add("retry-fire") { s in step(s, .retryFire(generation: g)) } }
            if w.configured { add("shutdown") { s in end(s) } }
            for (i, r) in w.dead.enumerated() {
                add("dead[\(i)]-2xx") { s in deadArrives(apply(s, r), i, r) }
                add("dead[\(i)]-lost") { s in var o = s; o.dead.remove(at: i); return o }
            }
            if !w.configured { add("configure") { s in configure(s) } }
            for applied in [true, false] {
                for rowZero in [nil, true, false] as [Bool?] {
                    add("relaunch(applied=\(applied),\(String(describing: rowZero)))") { s in
                        var x = s
                        let all = s.dead + (s.table.inFlight.map { [req($0)] } ?? [])
                        if applied { for r in all { x = apply(x, r) } }
                        x.dead = []; x.table.inFlight = nil; x.table.timer = nil; x.configured = false; x.rowZero = false
                        if let v = rowZero { x.decision = v; x.rowZero = true }
                        return configure(x)
                    }
                }
            }
            return out
        }

        func latest(_ w: World) -> T.Triple? {
            guard let best = w.server.max(by: { ($0.value.ts, $0.value.seq) < ($1.value.ts, $1.value.seq) }) else { return nil }
            return T.Triple(anonId: "A", userId: best.key.isEmpty ? nil : best.key, analytics: best.value.analytics)
        }

        func matches(_ server: T.Triple?, _ expected: T.Triple) -> Bool { server.map { $0 == expected } ?? expected.analytics }

        func invariant1(_ w: World) -> String? {
            let t = w.table
            guard w.configured, t.inFlight == nil, t.timer == nil, t.slot == nil, w.dead.isEmpty, let last = w.lastDecision else { return nil }
            if t.dropped == last { return nil }
            return matches(latest(w), last) ? nil : "invariant 1: server \(String(describing: latest(w))) ≠ last decision \(last)"
        }

        func invariant2(_ w: World) -> String? {
            for applied in [true, false] {
                var x = w
                let all = w.dead + (w.table.inFlight.map { [req($0)] } ?? [])
                if applied { for r in all { x = apply(x, r) } }
                x.dead = []; x.table.inFlight = nil; x.table.timer = nil; x.configured = false
                x.clock += 1
                x = configure(x)
                for _ in 0..<20 {
                    if let f = x.table.inFlight { x = step(apply(x, req(f)), .success(generation: f.generation)) }
                    else if let g = x.table.timer { x = step(x, .retryFire(generation: g)) }
                    else { break }
                }
                if x.table.dropped == x.e { continue }
                if !matches(latest(x), x.e) { return "invariant 2 (applied=\(applied)): server \(String(describing: latest(x))) ≠ E \(x.e)" }
            }
            return nil
        }
    }

    func enumerate(_ variant: Variant) -> (states: Int, failure: String?, path: [String]) {
        let sim = Sim(variant: variant)
        var queue: [(World, Int, [String])] = []
        for ack in [T.Ack.none, .known(T.Triple(anonId: "A", userId: "U", analytics: true)), .known(T.Triple(anonId: "A", userId: "U", analytics: false))] {
            for decision in [nil, true, false] as [Bool?] {
                for configured in [false, true] {
                    var known: T.Triple?
                    if case .known(let t) = ack { known = t }
                    var w = World(table: T.State(ack: ack), decision: decision, user: "U", configured: false, rowZero: false,
                                  clock: 1, dead: [], server: known.map { ["U": Row(analytics: $0.analytics, ts: 0, seq: 0)] } ?? [:],
                                  seq: 0, lastDecision: known)
                    if configured { w = sim.configure(w) }
                    queue.append((w, 0, []))
                }
            }
        }
        var seen = Set<World>()
        var head = 0
        while head < queue.count {
            let (w, depth, path) = queue[head]; head += 1
            if !seen.insert(w).inserted { continue }
            if let f = sim.invariant1(w) ?? sim.invariant2(w) { return (seen.count, f, path) }
            if depth < Self.depth { for (label, n) in sim.successors(w) { queue.append((n, depth + 1, path + [label])) } }
        }
        return (seen.count, nil, [])
    }

    func testTheProductionTableHoldsBothInvariantsOverEveryShortSequence() {
        let r = enumerate(.production)
        print("[consent enumeration] production: \(r.states) distinct states, depth \(Self.depth)")
        XCTAssertNil(r.failure, "violation after \(r.path): \(r.failure ?? "")")
        XCTAssertGreaterThan(r.states, 1000)
    }

    func testEachRedControlFailsTheEnumeration() {
        for v in [Variant.tie, .noFence, .noWriteAhead] {
            let r = enumerate(v)
            print("[consent enumeration] red control \(v): \(r.failure ?? "NO VIOLATION") after \(r.path) (\(r.states) states)")
            XCTAssertNotNil(r.failure, "red control \(v) found no violation in \(r.states) states")
        }
    }
}
