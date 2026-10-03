// EmittedByMarkerTests.swift
//
// `emitted_by: "sdk"` marks the SDK's own billing events; the public
// `AppDNA.track` strips `emitted_by` and the server-only `_appdna_origin` FIRST, before the pre-init
// buffer decision, so a host can forge neither — also for an event buffered before `configure`.

import XCTest
@testable import AppDNASDK

final class EmittedByMarkerTests: XCTestCase {

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var previous: EventTracker?

    override func setUp() {
        super.setUp()
        events = []
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        previous = AppDNA.eventTrackerForTesting
    }

    override func tearDown() {
        AppDNA.installEventTrackerForTest(previous)
        super.tearDown()
    }

    private let forged: [String: Any] = [
        "product_id": "p1", "emitted_by": "sdk", "_appdna_origin": "integration:revenuecat",
    ]

    func testPublicTrackStripsTheReservedKeys() {
        AppDNA.installEventTrackerForTest(tracker)
        AppDNA.track(event: "purchase_completed", properties: forged)
        AppDNA.drainSDKQueueForTesting()
        let props = events.first(where: { $0.event_name == "purchase_completed" })?.properties
        XCTAssertEqual(props?["product_id"]?.value as? String, "p1")
        XCTAssertNil(props?["emitted_by"])
        XCTAssertNil(props?["_appdna_origin"])
    }

    func testAnEventBufferedBeforeConfigureIsStrippedToo() {
        AppDNA.installEventTrackerForTest(nil)                 // pre-configure: the facade buffers
        AppDNA.track(event: "purchase_completed", properties: forged)
        AppDNA.installEventTrackerForTest(tracker)
        AppDNA.drainPreInitBufferForTesting()
        let props = events.first(where: { $0.event_name == "purchase_completed" })?.properties
        XCTAssertNotNil(props, "the buffered event is delivered")
        XCTAssertNil(props?["emitted_by"])
        XCTAssertNil(props?["_appdna_origin"])
    }

    func testTheSdksOwnBillingEmitCarriesTheMarker() {
        PurchaseSuccessEvents.emit(tracker: tracker, paywallId: "pw", result: PurchaseResult(
            productId: "p1", transactionId: "1", price: 1, currency: "USD", provider: "storekit2",
            isSubscription: true, isConsumable: false, isTrial: false
        ))
        XCTAssertEqual(events.map(\.event_name), ["purchase_completed", "subscription_started"])
        for e in events { XCTAssertEqual(e.properties?["emitted_by"]?.value as? String, "sdk") }
    }
}
