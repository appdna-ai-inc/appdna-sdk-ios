// SDKHTTPCacheAndShutdownFlushTests.swift
//
// Two network behaviours, each against the REAL `APIClient` / `EventQueue` and a loopback server:
//
//   HTTP cache      the bootstrap is answered `Cache-Control: private, max-age=86400`. The SDK's session
//                   used `URLCache.shared` with the protocol cache policy, so for 24 hours every later
//                   bootstrap was answered from the cache without reaching the server — online or offline.
//                   NEGATIVE CONTROL: with the default session configuration back, the second request
//                   never reaches the server (1, not 2) and the unreachable server "answers" 200.
//   Shutdown flush  `AppDNA.shutdown()` asked the queue to flush and released it on the next line; the
//                   flush captured the queue weakly, so it either never ran or ran without its queue and
//                   left the process-wide upload claim held. NEGATIVE CONTROL: with the weak captures
//                   back, nothing reaches the server.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

/// A loopback HTTP/1.1 server: one request per connection (`Connection: close`), every request recorded
/// as "METHOD path", every answer from `respond`.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Answer {
        var status: Int
        var headers: [String: String]
        var body: String
    }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _bodies: [(label: String, body: Data)] = []
    private let respond: @Sendable (String) -> Answer

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    func count(_ prefix: String) -> Int { requests.filter { $0.hasPrefix(prefix) }.count }
    /// Every request's body as sent, with its "METHOD path" label.
    var bodies: [(label: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return _bodies }

    init?(respond: @escaping @Sendable (String) -> Answer) {
        self.respond = respond
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

    var baseURL: String { "http://127.0.0.1:\(port)" }

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
            if headerEnd == nil, let range = Self.find([13, 10, 13, 10], in: data) {
                headerEnd = range
                let head = String(decoding: data[0..<range], as: UTF8.self)
                for line in head.split(separator: "\r\n") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let end = headerEnd, data.count >= end + 4 + contentLength { break }
        }
        let head = String(decoding: data[0..<(headerEnd ?? 0)], as: UTF8.self)
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let label = parts.count >= 2 ? "\(parts[0]) \(parts[1])" : requestLine
        let bodyStart = (headerEnd ?? 0) + 4
        let body = data.count >= bodyStart ? Data(data[bodyStart..<min(data.count, bodyStart + contentLength)]) : Data()
        lock.lock(); _requests.append(label); _bodies.append((label, body)); lock.unlock()
        let answer = respond(label)
        let payload = Array(answer.body.utf8)
        var reply = "HTTP/1.1 \(answer.status) X\r\n"
        for (k, v) in answer.headers { reply += "\(k): \(v)\r\n" }
        reply += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        let bytes = Array(reply.utf8) + payload
        _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// Stop listening: later requests get "connection refused" — an unreachable server.
    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

/// For tests that configure the real SDK with a placeholder key. `shutdown()` uploads the queued events,
/// and the 401 such a key gets drops them into the persisted dropped-events counter — after which every
/// later test's tracker reports an `_sdk_events_dropped` event first (the counter lives in
/// `UserDefaults.standard`, so it even survived into the next run on the same simulator). Save the counter in
/// `setUp`; after the shutdown, wait for its upload to resolve, then put the counter back.
enum ShutdownUploadIsolation {
    static func save() -> Int { DroppedEventsCounter.peek() }

    /// Blocks (polls) — call it from a synchronous tearDown or a detached task.
    static func restore(_ saved: Int, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while EventQueue.uploadsInFlightForTesting > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        _ = DroppedEventsCounter.getAndReset()
        if saved > 0 { DroppedEventsCounter.increment(saved) }
    }
}

final class SDKHTTPCacheAndShutdownFlushTests: XCTestCase {

    private var server: LoopbackHTTPServer?

    private func pointTheSDKAt(_ server: LoopbackHTTPServer) {
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
    }

    override func tearDown() {
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    private func poll(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - HTTP cache

    /// The bootstrap answer carries `Cache-Control: private, max-age=86400`; the second bootstrap still
    /// reaches the server, and with the server gone the bootstrap fails instead of returning a cached 200.
    func testTheBootstrapIsNeverAnsweredFromTheHTTPCache() async throws {
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in
            .init(status: 200, headers: ["Content-Type": "application/json",
                                         "Cache-Control": "private, max-age=86400"],
                  body: #"{"orgId":"o","appId":"a"}"#)
        }, "could not open a local socket")
        self.server = server
        pointTheSDKAt(server)
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)

        _ = try await client.requestData(.bootstrap)
        _ = try await client.requestData(.bootstrap)
        XCTAssertEqual(server.count("GET /api/v1/sdk/bootstrap"), 2,
                       "the second bootstrap was answered from the HTTP cache: \(server.requests)")

        server.stop()
        do {
            _ = try await client.requestData(.bootstrap)
            XCTFail("an unreachable server answered with a cached bootstrap")
        } catch {
            // Expected: a network error, the same as on Android.
        }
    }

    /// The same session serves every SDK request: no cache at all, so no other endpoint can be stale either.
    func testTheSDKSessionHasNoHTTPCache() {
        let config = APIClient.sessionConfiguration()
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    // MARK: - Shutdown flush

    /// `AppDNA.shutdown()`'s order: ask for the final flush, then let go of the queue at once. The queued
    /// event still reaches the server, and the process-wide upload claim is released afterwards.
    func testTheShutdownFlushRunsAfterTheQueueIsReleased() async throws {
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in .init(status: 200, headers: [:], body: "{}") },
                                   "could not open a local socket")
        self.server = server
        pointTheSDKAt(server)
        let networkUp = await poll { NetworkMonitor.shared.adaptiveBatchSize > 0 }
        XCTAssertTrue(networkUp, "the simulator reports no network")

        let store = EventStore(fileName: "shutdown-flush-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.shutdownflush.\(UUID().uuidString)")))
        var queue: EventQueue? = EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                                            eventStore: store, eventTracker: tracker,
                                            batchSizeCap: nil, flushInterval: 3600)
        tracker.setEventQueue(queue!)
        tracker.track(event: "shutdown_flush_probe", properties: nil)   // below the batch size: not sent
        let persisted = await poll { store.loadPending().contains { $0.event_name == "shutdown_flush_probe" } }
        XCTAssertTrue(persisted)
        XCTAssertEqual(server.count("POST /api/v1/ingest/events"), 0)

        queue?.flushForShutdown()
        queue = nil

        let sent = await poll { server.count("POST /api/v1/ingest/events") >= 1 }
        XCTAssertTrue(sent, "the final flush never reached the server: \(server.requests)")
        let released = await poll {
            guard EventUploadCoordinator.tryAcquire() else { return false }
            EventUploadCoordinator.release()
            return true
        }
        XCTAssertTrue(released, "the upload claim stayed held after the final flush")
        let removed = await poll { !store.loadPending().contains { $0.event_name == "shutdown_flush_probe" } }
        XCTAssertTrue(removed, "the uploaded event stayed on disk")
    }
}
