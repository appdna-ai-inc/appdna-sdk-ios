import XCTest
@testable import AppDNASDK

/// Every event envelope carries the device's IANA zone at `device.timezone`, so the server schedules
/// time-zone-aware pushes, quiet hours and journey waits in the user's own zone without a host trait.
final class DeviceTimezoneEnvelopeTests: XCTestCase {

    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
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
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Chatham"))
        XCTAssertEqual(try encodedDevice()["timezone"] as? String, "Pacific/Chatham")
    }

    func testTheZoneIsReadPerEventNotCapturedOnce() throws {
        // A traveller moves: the next event must report the zone the device is in now.
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Chatham"))
        _ = try encodedDevice()
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
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
}
