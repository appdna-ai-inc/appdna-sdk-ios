// GzipResponseDecodingTests.swift
//
// #857 — does a gzip-encoded answer reach the JSON parser DECODED on iOS?
//
// The Android SDK set `Accept-Encoding: gzip, deflate` by hand, which is exactly what stops OkHttp
// decompressing: its transparent path runs ONLY when OkHttp added the header itself. Every gzip
// answer arrived as raw bytes and threw `JSONException: Value <0x1f>…`, and init degraded to cached
// config silently.
//
// `APIClient.swift:350` sets the SAME header by hand. URLSession is widely believed to decompress
// `Content-Encoding: gzip` regardless of who set the header — but "widely believed" is what #857
// was about on the other platform, so this measures it instead against a real loopback server
// serving real gzip bytes.
//
// The `deflate` half is the other question: URLSession does not advertise raw deflate on its own,
// and a server taking us at our word would send an encoding we cannot read.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import Compression
@testable import AppDNASDK

final class GzipResponseDecodingTests: XCTestCase {
    private var server: LoopbackHTTPServer?

    override func tearDown() {
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    private func pointTheSDKAt(_ server: LoopbackHTTPServer) {
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
    }

    /// A real gzip member: the 10-byte header, a raw-deflate payload, then CRC32 + ISIZE.
    private func gzip(_ input: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        let bytes = [UInt8](input)
        let cap = max(64, bytes.count * 2 + 64)
        var deflated = [UInt8](repeating: 0, count: cap)
        let n = bytes.withUnsafeBufferPointer { src in
            compression_encode_buffer(&deflated, cap, src.baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(n, 0, "could not deflate the fixture body")
        out.append(contentsOf: deflated[0..<n])
        var crc = crc32(bytes).littleEndian
        var size = UInt32(truncatingIfNeeded: bytes.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// 🔴 The question #857 leaves open for iOS: a `Content-Encoding: gzip` answer must PARSE.
    func testAGzipAnswerIsDecoded() async throws {
        let json = #"{"orgId":"o","appId":"a","n":7}"#
        let body = gzip(Data(json.utf8))
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in
            .init(status: 200,
                  headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
                  body: "", bodyData: body)
        }, "could not open a local socket")
        self.server = server
        pointTheSDKAt(server)

        let data = try await APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
            .requestData(.bootstrap)

        // If URLSession handed back the raw member, the first byte is 0x1f and this is not JSON.
        XCTAssertNotEqual(data.first, 0x1f,
                          "the raw gzip member reached the caller — the same defect #857 found on Android")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                "a gzip answer must parse, not arrive as bytes")
        XCTAssertEqual(obj["orgId"] as? String, "o")
        XCTAssertEqual(obj["n"] as? Int, 7)
    }

    /// An uncompressed answer is unaffected — so a green above is about gzip, not about the harness.
    func testAnUncompressedAnswerStillParses() async throws {
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in
            .init(status: 200, headers: ["Content-Type": "application/json"], body: #"{"orgId":"o","plain":1}"#)
        }, "could not open a local socket")
        self.server = server
        pointTheSDKAt(server)

        let data = try await APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
            .requestData(.bootstrap)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["plain"] as? Int, 1)
    }

    /// 🔴 What the SDK ADVERTISES. `deflate` is the half that is wrong on both platforms: nothing in
    /// URLSession decodes a raw deflate body, so offering it invites an encoding we cannot read.
    func testWhatTheClientAdvertises() async throws {
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in
            .init(status: 200, headers: ["Content-Type": "application/json"], body: "{}")
        }, "could not open a local socket")
        self.server = server
        pointTheSDKAt(server)

        _ = try await APIClient(apiKey: "adn_test_placeholder", environment: .sandbox).requestData(.bootstrap)

        let head = try XCTUnwrap(server.heads.first, "the request never reached the server")
        let accept = head
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("accept-encoding:") }
            .map { String($0.dropFirst("accept-encoding:".count)).trimmingCharacters(in: .whitespaces) }
        XCTAssertNotNil(accept, "no Accept-Encoding was sent at all")
        XCTAssertFalse(accept!.lowercased().contains("deflate"),
                       "the SDK offers raw deflate, which nothing here can decode: \(accept!)")
    }
}
