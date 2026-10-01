import XCTest
@testable import AppDNASDK

/// Every event envelope carries the device's IANA zone at `device.timezone`, so the server schedules
/// time-zone-aware pushes, quiet hours and journey waits in the user's own zone without a host trait.
final class DeviceTimezoneEnvelopeTests: XCTestCase {

    private var savedProvider: (() -> TimeZone)!

    override func setUp() {
        super.setUp()
        savedProvider = EventEnvelopeBuilder.timeZoneProvider
    }

    override func tearDown() {
        EventEnvelopeBuilder.timeZoneProvider = savedProvider
        super.tearDown()
    }

    /// The device "is in" `id` — through the builder's zone seam (`NSTimeZone.default` does not reach
    /// `TimeZone.current` on the iOS 26.2 simulator).
    private func setZone(_ id: String) throws {
        let zone = try XCTUnwrap(TimeZone(identifier: id))
        EventEnvelopeBuilder.timeZoneProvider = { zone }
    }

    private func encodedDevice() throws -> [String: Any] {
        let event = EventEnvelopeBuilder.build(
            event: "evt",
            properties: nil,
            identity: DeviceIdentity(anonId: "anon", userId: nil, traits: nil),
            sessionId: "s1",
            analyticsConsent: true
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        return try XCTUnwrap(json?["device"] as? [String: Any])
    }

    func testTheEncodedEnvelopeCarriesTheCurrentZonesIanaId() throws {
        try setZone("Pacific/Chatham")
        XCTAssertEqual(try encodedDevice()["timezone"] as? String, "Pacific/Chatham")
    }

    func testTheZoneIsReadPerEventNotCapturedOnce() throws {
        // A traveller moves: the next event must report the zone the device is in now.
        try setZone("Pacific/Chatham")
        _ = try encodedDevice()
        try setZone("America/Sao_Paulo")
        XCTAssertEqual(try encodedDevice()["timezone"] as? String, "America/Sao_Paulo")
    }

    func testAnEventPersistedBeforeTheFieldExistedStillDecodes() throws {
        // The offline queue stores encoded envelopes; one written by an older SDK has no `timezone`.
        let old = """
        {"schema_version":1,"event_id":"e1","event_name":"evt","ts_ms":1,
         "user":{"anon_id":"a"},
         "device":{"platform":"ios","os":"17.0.0","app_version":"1.0","sdk_version":"1.0.0",
                   "locale":"en-US","country":"US","framework":"native"},
         "context":{"session_id":"s1"},
         "privacy":{"consent":{"analytics":true}}}
        """
        let event = try JSONDecoder().decode(SDKEvent.self, from: Data(old.utf8))
        XCTAssertNil(event.device.timezone)
    }

    /// Production reads `TimeZone.current` on every event (the seam's default).
    func testTheDefaultProviderIsTheCurrentZone() {
        EventEnvelopeBuilder.timeZoneProvider = savedProvider
        XCTAssertEqual(EventEnvelopeBuilder.deviceTimeZoneId(), TimeZone.current.identifier)
    }
}
