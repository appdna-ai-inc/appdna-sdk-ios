// EventBacklogReconfigureTests.swift
//
// A device with a full event backlog (10,000 queued events) whose host calls `shutdown(); configure()` —
// sign-out → sign-in, a React Native reload. The new configure must reach ready promptly, and the main
// thread must never stall, whatever the backlog.
//
// Before the event store's index, the old queue's last flush decoded the whole file twice and the new
// queue's load (inside `configure()`) decoded it again behind it, on the one serial queue the file has:
// 15–23 s to ready on the Mac, more than 30 s on CI. This test prints the time to ready of the cold
// configure and of the reconfigure, and the longest main-thread gap, and bounds them generously. It uses
// only APIs the old store had, so the same file measures the tree before the fix.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class EventBacklogReconfigureTests: XCTestCase {

    private var savedDropped = 0
    private var server: LoopbackHTTPServer?

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        server = LoopbackHTTPServer { label in
            label.hasPrefix("GET /api/v1/sdk/bootstrap")
                ? BootstrapRecoveryTests.body("org_backlog")
                : .init(status: 200, headers: ["Content-Type": "application/json"], body: "{}")
        }
        if let server {
            APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
            APIBaseURL.gateForTesting = { true }
        }
    }

    override func tearDown() {
        AppDNA.resetInitStateForTesting()
        AppDNA.shutdown()
        let deadline = Date().addingTimeInterval(60)
        while AppDNA.subsystemsUp()["events"] != false && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        ShutdownUploadIsolation.restore(savedDropped, timeout: 60)
        EventStore().clearAll()
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    /// The longest gap between ticks of a 10 ms main-thread timer while it runs.
    final class MainThreadWatch {
        private var timer: Timer?
        private var last = Date()
        private(set) var maxGap: TimeInterval = 0
        func start() {
            last = Date()
            let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = Date()
                self.maxGap = max(self.maxGap, now.timeIntervalSince(self.last))
                self.last = now
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        func stop() { timer?.invalidate(); timer = nil }
    }

    private func readyTime(_ label: String) -> TimeInterval {
        let start = Date()
        let ready = expectation(description: label)
        AppDNA.onReady { ready.fulfill() }
        wait(for: [ready], timeout: 120)
        return Date().timeIntervalSince(start)
    }

    func testAReconfigureWithATenThousandEventBacklogIsPromptAndNeverStallsTheMainThread() throws {
        _ = try XCTUnwrap(server, "could not open a local socket")
        let events = (0..<10_000).map { i in
            EventEnvelopeBuilder.build(
                event: "backlog_\(i)", properties: ["k": "v", "n": i],
                identity: DeviceIdentity(anonId: "backlog-anon", userId: nil, traits: nil),
                sessionId: "backlog-session", analyticsConsent: true)
        }
        EventStore().save(events: events)

        let watch = MainThreadWatch()
        watch.start()
        defer { watch.stop() }

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        let cold = readyTime("cold configure ready")

        let reStart = Date()
        AppDNA.shutdown()
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        _ = readyTime("reconfigure ready")
        let reconfigure = Date().timeIntervalSince(reStart)
        let gap = watch.maxGap

        print(String(format: "[backlog] 10,000-event backlog: cold configure → ready %.2f s; shutdown(); configure() → ready %.2f s; longest main-thread gap %.3f s", cold, reconfigure, gap))
        XCTAssertEqual(AppDNA.subsystemsUp()["events"], true)
        // Generous bounds (the old store: 15–23 s on the Mac, > 30 s on CI); quiet runs are well under 1 s.
        XCTAssertLessThan(reconfigure, 15, "shutdown(); configure() took \(reconfigure) s to reach ready on a 10,000-event backlog")
        XCTAssertLessThan(gap, 5, "the main thread stalled \(gap) s")
    }
}
