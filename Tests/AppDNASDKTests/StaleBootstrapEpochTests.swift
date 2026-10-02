// StaleBootstrapEpochTests.swift
//
// A bootstrap that finishes after its configure has ended must change nothing.
//
// `performBootstrap` awaits the network for up to 15 s. Before the configure epoch reached it, a
// `shutdown()` in that window was ignored: the late answer ran `initializeManagers`, set `isReady` and
// fired `onReady` on a shut-down SDK. Across `shutdown(); configure()` the first configure's late
// answer could also land AFTER the second's and overwrite it (bootstrap data, every manager).
//
// The bootstrap is held on a loopback server (the test-only base-URL override) and released on cue.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

/// Holds every `GET /api/v1/sdk/bootstrap` until the test answers it, by arrival index. Every other
/// request gets an immediate 401, so nothing else in the SDK can hang on this server.
private final class BootstrapGateServer {
    let port: UInt16
    private let fd: Int32
    private let condition = NSCondition()
    private var received = 0
    private var answers: [Int: (status: Int, body: String)] = [:]
    private var stopped = false

    init?() {
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
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, size) }
        }
        guard bound == 0, listen(s, 32) == 0 else { close(s); return nil }
        var out = sockaddr_in()
        var outSize = size
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &outSize) }
        }
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
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &buffer, buffer.count)
        let head = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
        var status = 401
        var body = ""
        if head.hasPrefix("GET /api/v1/sdk/bootstrap") {
            condition.lock()
            let index = received
            received += 1
            condition.broadcast()
            while answers[index] == nil && !stopped { condition.wait() }
            if let answer = answers[index] { status = answer.status; body = answer.body }
            condition.unlock()
        }
        let payload = Array(body.utf8)
        let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n" + body
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }

    /// How many bootstraps have reached the server (answered or not).
    var bootstrapsReceived: Int {
        condition.lock(); defer { condition.unlock() }
        return received
    }

    /// Answer the `index`-th bootstrap (0-based arrival order) with a 200 naming `orgId`.
    func answerBootstrap(_ index: Int, orgId: String) {
        let body = #"{"orgId":"\#(orgId)","appId":"app_epoch","firestorePath":"orgs/\#(orgId)/apps/app_epoch","#
            + #""settings":{"flushInterval":30,"batchSize":20,"configTTL":300}}"#
        condition.lock(); answers[index] = (200, body); condition.broadcast(); condition.unlock()
    }

    func stop() {
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
        close(fd)
    }
}

final class StaleBootstrapEpochTests: XCTestCase {

    private var server: BootstrapGateServer?

    /// The dropped-events counter as it was before this test (see `ShutdownUploadIsolation`).
    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        let server = BootstrapGateServer()
        self.server = server
        if let server {
            APIBaseURL.infoPlistReaderForTesting = {
                $0 == APIBaseURL.infoPlistKey ? "http://127.0.0.1:\(server.port)" : nil
            }
            APIBaseURL.gateForTesting = { true }
        }
    }

    override func tearDown() {
        AppDNA.shutdown()
        waitUntil("torn down") { AppDNA.subsystemsUp()["events"] == false }
        AppDNA.drainSDKQueueForTesting()
        ShutdownUploadIsolation.restore(savedDropped)
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 30, _ cond: @escaping () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() >= deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func settled() -> Int {
        let o = AppDNA.bootstrapOutcomesForTesting
        return o.applied + o.dropped
    }

    /// shutdown() while the bootstrap is in flight → the late answer is dropped: not ready, no managers,
    /// no onReady — and the SDK can still be configured again afterwards.
    func testABootstrapAnsweredAfterShutdownLeavesTheSDKShutDown() throws {
        let server = try XCTUnwrap(server, "could not open a local socket")
        let staleOrg = "org_stale_\(UUID().uuidString.prefix(8))"

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("bootstrap #0 reached the server") { server.bootstrapsReceived == 1 }
        XCTAssertFalse(AppDNA.isReadyForTesting, "the bootstrap is held — the SDK cannot be ready yet")

        AppDNA.shutdown()
        waitUntil("shutdown teardown landed") { AppDNA.subsystemsUp()["events"] == false }

        var readyFired = false
        AppDNA.onReady { readyFired = true }
        let before = settled()
        let appliedBefore = AppDNA.bootstrapOutcomesForTesting.applied

        server.answerBootstrap(0, orgId: staleOrg)
        waitUntil("the late bootstrap result was handled") { self.settled() > before }
        AppDNA.drainSDKQueueForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))   // let any main-queue onReady run

        XCTAssertEqual(AppDNA.bootstrapOutcomesForTesting.applied, appliedBefore,
                       "a bootstrap answered after shutdown() was applied to the shut-down SDK")
        XCTAssertFalse(AppDNA.isReadyForTesting, "shutdown() then a late bootstrap left the SDK ready")
        XCTAssertFalse(readyFired, "onReady fired for a bootstrap that finished after shutdown()")
        let up = AppDNA.subsystemsUp()
        for name in ["paywall", "onboarding", "in_app_messages", "surveys", "web_entitlements"] {
            XCTAssertEqual(up[name], false, "\(name) was rebuilt by a bootstrap that finished after shutdown()")
        }
        XCTAssertNotEqual(AppDNA.bootstrapOrgIdForTesting, staleOrg,
                          "the late bootstrap's data was stored on the shut-down SDK")

        // …and the SDK is still usable: a fresh configure comes up with ITS bootstrap.
        let freshOrg = "org_fresh_\(UUID().uuidString.prefix(8))"
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("bootstrap #1 reached the server") { server.bootstrapsReceived == 2 }
        server.answerBootstrap(1, orgId: freshOrg)
        waitUntil("the re-configure reached ready") { readyFired }
        XCTAssertTrue(AppDNA.isReadyForTesting)
        XCTAssertEqual(AppDNA.bootstrapOrgIdForTesting, freshOrg)
    }

    /// shutdown(); configure() while the first bootstrap is in flight, and the FIRST answer arrives
    /// LAST → only the second configure's bootstrap applies; the stale one overwrites nothing.
    func testAStaleBootstrapAnsweredAfterTheReconfigureDoesNotOverwriteIt() throws {
        let server = try XCTUnwrap(server, "could not open a local socket")
        let oldOrg = "org_old_\(UUID().uuidString.prefix(8))"
        let newOrg = "org_new_\(UUID().uuidString.prefix(8))"

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("bootstrap #0 reached the server") { server.bootstrapsReceived == 1 }

        AppDNA.shutdown()
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        waitUntil("bootstrap #1 reached the server") { server.bootstrapsReceived == 2 }

        let start = AppDNA.bootstrapOutcomesForTesting
        var readyCount = 0
        AppDNA.onReady { readyCount += 1 }

        server.answerBootstrap(1, orgId: newOrg)
        waitUntil("the re-configure reached ready") { readyCount == 1 }
        XCTAssertEqual(AppDNA.bootstrapOrgIdForTesting, newOrg)
        let appliedAfterNew = AppDNA.bootstrapOutcomesForTesting.applied
        XCTAssertEqual(appliedAfterNew, start.applied + 1)
        let paywallBefore = AppDNA.paywall.paywallManager.map(ObjectIdentifier.init)

        let before = settled()
        server.answerBootstrap(0, orgId: oldOrg)
        waitUntil("the stale bootstrap result was handled") { self.settled() > before }
        AppDNA.drainSDKQueueForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(AppDNA.bootstrapOutcomesForTesting.applied, appliedAfterNew,
                       "the first configure's late bootstrap was applied on top of the second's")
        XCTAssertEqual(AppDNA.bootstrapOrgIdForTesting, newOrg,
                       "the first configure's late bootstrap overwrote the second configure's data")
        XCTAssertEqual(AppDNA.paywall.paywallManager.map(ObjectIdentifier.init), paywallBefore,
                       "the managers were rebuilt by a stale bootstrap")
        XCTAssertEqual(readyCount, 1, "onReady fired again for a stale bootstrap")
        XCTAssertTrue(AppDNA.isReadyForTesting)
        XCTAssertEqual(AppDNA.subsystemsUp()["events"], true)
    }
}
