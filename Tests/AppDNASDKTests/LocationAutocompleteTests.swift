// LocationAutocompleteTests.swift
//
// #963 — what the ONE location autocomplete call actually puts on the wire, and what it reads back.
//
// This is the assertion the gate cannot make. `check:location-config-reach` proves each surface
// hands its resolved settings to this function; only a request can prove the function SENDS them,
// with the key names the proxy's Zod schema accepts, and only a reply can prove the extra keys the
// content block gains (`state_code`, the proxy's time zone) survive the decode.
//
// The request is served by a stub `URLProtocol` on an injected session — the real `URLRequest`, the
// real body encoding and the real `JSONSerialization` decode, with the socket replaced. The proxy
// itself is not under test: the body below is byte-for-byte the one the form-step Location field has
// been sending to production since 1.0.82.
//
// NEGATIVE CONTROL: `testTheHarnessSeesTheBody` fails if the stub is bypassed or the body is not
// read, so "no `type` was sent" can never pass because nothing was captured.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

/// Captures every request and answers each one with `StubProxy.reply`.
private final class StubProxy: URLProtocol {
    /// Bodies seen, in order. `URLProtocol` strips `httpBody` from a streamed request, so the
    /// stream is read back here rather than trusted.
    static var bodies: [[String: Any]] = []
    static var headers: [[String: String]] = []
    static var methods: [String] = []
    static var urls: [String] = []
    static var reply = Data()

    static func reset() {
        bodies = []; headers = []; methods = []; urls = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "")
        Self.urls.append(request.url?.absoluteString ?? "")
        Self.headers.append(request.allHTTPHeaderFields ?? [:])
        let raw: Data? = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            return data
        }
        if let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            Self.bodies.append(obj)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LocationAutocompleteTests: XCTestCase {

    /// One suggestion carrying every key the proxy can supply, including the two the MapKit path
    /// could never produce: `state_code`, and a time zone for the PLACE rather than the device.
    private static let fullReply = """
    {"data":{"suggestions":[{
      "formatted_address":"Lisbon, Portugal","city":"Lisbon","state":"Lisbon","state_code":"11",
      "country":"Portugal","country_code":"PT","latitude":38.72225,"longitude":-9.13934,
      "timezone":"Europe/Lisbon","timezone_offset":60,"postal_code":"1100-148","raw_query":"lisb"
    }]}}
    """

    private var session: URLSession!
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubProxy.reset()
        StubProxy.reply = Data(Self.fullReply.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProxy.self]
        session = URLSession(configuration: config)
        client = APIClient(apiKey: "test-key", environment: .production)
    }

    override func tearDown() {
        session = nil
        client = nil
        StubProxy.reset()
        super.tearDown()
    }

    private func fetch(_ settings: LocationSearchSettings, query: String = "Lisb") async -> [LocationData] {
        await LocationAutocomplete.fetch(query: query, settings: settings, client: client, session: session)
    }

    /// Resolved through the REAL `LocationSearchSettings`, from a content block's `field_config` —
    /// so an unauthored setting is genuinely ABSENT from the config, as it is in a published
    /// document, rather than present-and-nil.
    private func settings(type: String? = nil, bias: String? = nil, language: String? = nil) -> LocationSearchSettings {
        var config: [String: AnyCodable] = [:]
        if let type { config["location_type"] = AnyCodable(type) }
        if let bias { config["location_bias_country"] = AnyCodable(bias) }
        if let language { config["location_language"] = AnyCodable(language) }
        return LocationSearchSettings.from(blockConfig: config, defaultMinChars: 3)
    }

    // MARK: - The negative control

    /// Everything below reads `StubProxy.bodies`. If the stub were bypassed, or the body never
    /// decoded, every "the key is absent" assertion would pass against an empty capture — the exact
    /// shape of failure that let #982 close with a feature that did not work.
    func testTheHarnessSeesTheBody() async {
        _ = await fetch(settings(type: "city", bias: "pt", language: "pt-PT"))
        XCTAssertEqual(StubProxy.bodies.count, 1, "the stub protocol served no request")
        XCTAssertEqual(StubProxy.bodies.first?["query"] as? String, "Lisb", "the body was not read")
        XCTAssertEqual(StubProxy.methods, ["POST"])
        XCTAssertEqual(
            StubProxy.urls.first, "https://api.appdna.ai/api/v1/sdk/geocode/autocomplete",
            "a different endpoint would make every other assertion meaningless"
        )
    }

    // MARK: - All four settings reach the proxy

    func testAnAuthoredTypeBiasAndLanguageAreAllSent() async throws {
        _ = await fetch(settings(type: "city", bias: "pt", language: "pt-PT"))
        let body = try XCTUnwrap(StubProxy.bodies.first)
        XCTAssertEqual(body["type"] as? String, "city")
        XCTAssertEqual(body["bias_country"] as? String, "pt")
        XCTAssertEqual(body["language"] as? String, "pt-PT")
        XCTAssertEqual(body["limit"] as? Int, 5)
    }

    /// #964 — an unauthored setting must be ABSENT rather than a substituted default: the proxy
    /// (`GeocodingService.autocomplete`) applies its own default for a missing key, which a value
    /// invented on the device would override. Both platforms, every surface.
    func testAnUnauthoredSettingIsAbsentRatherThanDefaulted() async throws {
        _ = await fetch(LocationSearchSettings.from(blockConfig: nil, defaultMinChars: 3))
        let body = try XCTUnwrap(StubProxy.bodies.first)
        XCTAssertNil(body["type"], "an unauthored Type must be left to the proxy's default")
        XCTAssertNil(body["bias_country"])
        XCTAssertNil(body["language"])
        XCTAssertEqual(Set(body.keys), ["query", "limit"])
    }

    /// A value outside the proxy's enum is treated as unset. Sending it would make the proxy answer
    /// with a ValidationError, which both SDKs read as "no suggestions" — turning autocomplete OFF
    /// instead of leaving it unfiltered. The Console's content-block select really did offer
    /// `coordinates`.
    func testATypeTheProxyWouldRejectIsNotForwarded() async throws {
        _ = await fetch(settings(type: "coordinates"))
        let body = try XCTUnwrap(StubProxy.bodies.first)
        XCTAssertNil(body["type"])
    }

    func testTheApiKeyAndPlatformHeadersAreSet() async throws {
        _ = await fetch(settings())
        let headers = try XCTUnwrap(StubProxy.headers.first)
        XCTAssertEqual(headers["x-api-key"], "test-key")
        XCTAssertEqual(headers["x-sdk-platform"], "ios")
        XCTAssertEqual(headers["x-sdk-version"], AppDNA.sdkVersion)
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    // MARK: - What comes back

    /// The two keys the content block GAINS by leaving Apple's place index: `state_code`, and a zone
    /// resolved for the place by the proxy instead of reverse-geocoded on the device.
    func testTheReplyDecodesIncludingStateCodeAndTheZone() async throws {
        let found = await fetch(settings(type: "city"))
        XCTAssertEqual(found.count, 1)
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.formatted_address, "Lisbon, Portugal")
        XCTAssertEqual(s.state_code, "11")
        XCTAssertEqual(s.timezone, "Europe/Lisbon")
        XCTAssertEqual(s.timezone_offset, 60)
        XCTAssertEqual(s.postal_code, "1100-148")

        // And the answer the block stores from it — the shape a host reads.
        let stored = LocationAnswer.selection(from: s, rawQuery: "Lisb")
        XCTAssertEqual(stored["state_code"] as? String, "11")
        XCTAssertEqual(stored["timezone"] as? String, "Europe/Lisbon")
        XCTAssertEqual(stored["raw_query"] as? String, "Lisb", "the typed text wins over the suggestion's own")
    }

    /// A non-200 or unparseable reply is an empty list, never a throw: the step stays usable.
    func testAFailedSearchIsAnEmptyListNotAnError() async {
        StubProxy.reply = Data("not json".utf8)
        let found = await fetch(settings())
        XCTAssertEqual(found, [])
    }

    /// A client-less call never reaches the network — the dropdown simply stays closed.
    func testWithoutAClientNoRequestIsMade() async {
        let found = await LocationAutocomplete.fetch(
            query: "Lisb",
            settings: LocationSearchSettings.from(blockConfig: nil, defaultMinChars: 3),
            client: nil,
            session: session
        )
        XCTAssertEqual(found, [])
        XCTAssertEqual(StubProxy.bodies.count, 0)
    }
}
