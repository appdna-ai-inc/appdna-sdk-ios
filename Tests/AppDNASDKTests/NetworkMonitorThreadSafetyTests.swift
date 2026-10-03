// NetworkMonitorThreadSafetyTests.swift
//
// `NetworkMonitor`'s state is written on the NWPathMonitor queue and read from every queue the SDK runs on (the
// event queue's batch size, the background uploader, the bootstrap retry loop). It used to be two plain stored
// properties with no synchronisation, and "was none" (which decides the network-regained notification) was read and
// written in separate steps. It is now one lock around the state; `apply(type:expensive:)` decides "was none" under
// the same lock, so a regain is reported exactly once per none → connected transition.
//
// TSan is not on in CI, so besides surviving the hammering these tests assert the observable invariants: a batch
// size is always one of the four the mapping allows, the regain count never exceeds the none → connected
// transitions, and a sequential none → wifi → cellular → none → wifi run reports exactly two regains.
// NEGATIVE CONTROL: the previous monitor has no `apply` seam, and its handler read `wasNone` outside any lock — a
// concurrent pair of updates could both see "none" and report two regains for one transition (only TSan or a lucky
// interleaving shows it; the sequential count below is the deterministic part).

import XCTest
@testable import AppDNASDK

final class NetworkMonitorThreadSafetyTests: XCTestCase {
    private var savedType: NetworkMonitor.ConnectionType = .wifi
    private var savedExpensive = false
    private var savedOverride: Int?

    override func setUp() {
        super.setUp()
        let m = NetworkMonitor.shared
        savedOverride = NetworkMonitor.adaptiveBatchSizeOverrideForTesting
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = nil
        // Let the real path monitor deliver its first update before the test owns the state.
        Thread.sleep(forTimeInterval: 0.3)
        savedType = m.currentConnectionType
        savedExpensive = m.isExpensive
    }

    override func tearDown() {
        NetworkMonitor.shared.apply(type: savedType, expensive: savedExpensive)
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = savedOverride
        super.tearDown()
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testTheMappingIsTheAndroidOne() {
        XCTAssertEqual(NetworkMonitor.connectionType(satisfied: false, usesWifi: true, usesCellular: false), NetworkMonitor.ConnectionType.none)
        XCTAssertEqual(NetworkMonitor.connectionType(satisfied: true, usesWifi: true, usesCellular: true), .wifi)
        XCTAssertEqual(NetworkMonitor.connectionType(satisfied: true, usesWifi: false, usesCellular: true), .cellular)
        // A wired or any other connected interface (VPN, …) counts as Wi-Fi.
        XCTAssertEqual(NetworkMonitor.connectionType(satisfied: true, usesWifi: false, usesCellular: false), .wifi)
    }

    func testARegainIsReportedOncePerTransition() {
        let m = NetworkMonitor.shared
        let regains = Count()
        let id = m.addRegainedObserver { regains.bump() }
        defer { m.removeRegainedObserver(id) }

        m.apply(type: .none, expensive: false)
        let base = regains.value
        m.apply(type: .wifi, expensive: false)       // regain 1
        m.apply(type: .cellular, expensive: true)    // still connected: no regain
        XCTAssertEqual(m.adaptiveBatchSize, 20)
        m.apply(type: .none, expensive: false)
        XCTAssertEqual(m.adaptiveBatchSize, 0)
        XCTAssertFalse(m.isConnected)
        m.apply(type: .wifi, expensive: false)       // regain 2
        XCTAssertEqual(m.adaptiveBatchSize, 100)
        XCTAssertEqual(regains.value - base, 2)
    }

    func testConcurrentUpdatesAndReadsKeepTheInvariants() {
        let m = NetworkMonitor.shared
        let regains = Count()
        let noneApplies = Count()
        let badReads = Count()
        let id = m.addRegainedObserver { regains.bump() }
        defer { m.removeRegainedObserver(id) }
        m.apply(type: .wifi, expensive: false)
        let base = regains.value

        let types: [NetworkMonitor.ConnectionType] = [.none, .wifi, .cellular]
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<2_000 {
                if worker % 2 == 0 {
                    let t = types[(i + worker) % types.count]
                    if t == .none { noneApplies.bump() }
                    m.apply(type: t, expensive: i % 3 == 0)
                } else {
                    let size = m.adaptiveBatchSize
                    if ![0, 20, 50, 100].contains(size) { badReads.bump() }
                    _ = m.isConnected
                    _ = m.isExpensive
                }
            }
        }
        XCTAssertEqual(badReads.value, 0, "a read saw a batch size the mapping cannot produce")
        XCTAssertLessThanOrEqual(regains.value - base, noneApplies.value,
                                 "more regains than none → connected transitions")

        // After the storm the monitor still works, deterministically.
        m.apply(type: .none, expensive: false)
        let before = regains.value
        m.apply(type: .wifi, expensive: false)
        XCTAssertEqual(regains.value - before, 1)
    }
}
