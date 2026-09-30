// PushModuleForwardingTests.swift
//
// SPEC-497 B1 / B2 (§8.2, §9.2, §9.8) — the iOS push forwarding API: the marker gate, delivered /
// tapped tracking with `delivery_id`, idempotency, never presenting, the body-tap action sentinel, and
// the push configured point (a tap before it is buffered and tracked exactly once after it).
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UserNotifications
@testable import AppDNASDK

final class PushModuleForwardingTests: XCTestCase {

    private final class Recorder: AppDNAPushDelegate {
        var received: [(String, Bool)] = []
        var tapped: [(String, String?)] = []
        func onPushReceived(notification: PushPayload, inForeground: Bool) {
            received.append((notification.pushId, inForeground))
        }
        func onPushTapped(notification: PushPayload, actionId: String?) {
            tapped.append((notification.pushId, actionId))
        }
    }

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var manager: PushTokenManager!
    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        let keychain = KeychainStore(service: "ai.appdna.sdk.pushfwd.\(UUID().uuidString)")
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        events = []
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        manager = PushTokenManager(keychainStore: keychain, eventTracker: tracker, apiClient: nil)
        AppDNA.pushModule.manager = manager
        recorder = Recorder()
        AppDNA.pushDelegate = recorder
    }

    override func tearDown() {
        AppDNA.pushModule.manager = nil
        AppDNA.pushDelegate = nil
        PushTapRouter.routeSink = nil
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        super.tearDown()
    }

    private func settle(_ seconds: Double = 0.3) {
        let exp = expectation(description: "main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    private let marked: [AnyHashable: Any] = ["appdna": "1", "push_id": "p1", "delivery_id": "d1"]

    // MARK: - Marker

    func testIsAppDNAMessageNeedsTheMarker() {
        XCTAssertTrue(AppDNA.pushModule.isAppDNAMessage(["appdna": "1"]))
        XCTAssertFalse(AppDNA.pushModule.isAppDNAMessage(["push_id": "p1"]), "a bare push_id is a host key")
        XCTAssertFalse(AppDNA.pushModule.isAppDNAMessage(["appdna": "0", "push_id": "p1"]))
        XCTAssertFalse(AppDNA.pushModule.isAppDNAMessage([:]))
    }

    // MARK: - handleMessageData

    func testHandleMessageDataTracksDeliveryIdAndDelegatesAndNeverPresents() {
        PushGate.shared.markConfigured()
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.injectedSlot = slot
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(marked, inForeground: true, requestId: nil))
        XCTAssertEqual(events.map(\.event_name), ["push_delivered"])
        XCTAssertEqual(events.first?.properties?["push_id"]?.value as? String, "p1")
        XCTAssertEqual(events.first?.properties?["delivery_id"]?.value as? String, "d1")
        XCTAssertEqual(recorder.received.map(\.0), ["p1"])
        XCTAssertNil(slot.delegate, "handleMessageData never touches presentation")
    }

    func testHandleMessageDataIgnoresNonAppDNAPushes() {
        PushGate.shared.markConfigured()
        XCTAssertFalse(AppDNA.pushModule.handleMessageData(["push_id": "host"]))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(recorder.received.isEmpty)
    }

    func testHandleMessageDataIsIdempotentPerDeliveryId() {
        PushGate.shared.markConfigured()
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(marked, inForeground: true, requestId: nil))
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(marked, inForeground: false, requestId: nil))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(recorder.received.count, 1)
    }

    func testNestedValuesPassThroughUntouched() {
        PushGate.shared.markConfigured()
        var sink: (String, String)?
        PushTapRouter.routeSink = { sink = ($0, $1) }
        let nested: [AnyHashable: Any] = [
            "appdna": "1", "push_id": "p", "action": ["type": "deep_link", "value": "x://y"],
            "list": [1, 2],
        ]
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(nested))
        settle(0.8)
        XCTAssertEqual(sink?.0, "deep_link")
        XCTAssertEqual(sink?.1, "x://y")
    }

    // MARK: - handleNotificationTap

    func testBodyTapTracksTheDefaultActionSentinelButDelegatesNil() {
        PushGate.shared.markConfigured()
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked))
        XCTAssertEqual(events.map(\.event_name), ["push_tapped"])
        XCTAssertEqual(events.first?.properties?["action"]?.value as? String, UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(events.first?.properties?["delivery_id"]?.value as? String, "d1")
        XCTAssertEqual(recorder.tapped.count, 1)
        XCTAssertNil(recorder.tapped.first?.1, "a body tap keeps a nil action id for the host")
    }

    func testButtonTapTracksAndDelegatesTheButtonId() {
        PushGate.shared.markConfigured()
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked, actionIdentifier: "view"))
        XCTAssertEqual(events.first?.properties?["action"]?.value as? String, "view")
        XCTAssertEqual(recorder.tapped.first?.1, "view")
    }

    func testTapIsTrackedOnceAcrossProxyAndHostForwarding() {
        PushGate.shared.markConfigured()
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked, actionIdentifier: nil, requestId: "r1"))
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked))
        XCTAssertEqual(events.filter { $0.event_name == "push_tapped" }.count, 1)
        XCTAssertEqual(recorder.tapped.count, 1)
    }

    func testTapWithoutMarkerIsIgnored() {
        PushGate.shared.markConfigured()
        XCTAssertFalse(AppDNA.pushModule.handleNotificationTap(["push_id": "p1", "action": ["type": "deep_link", "value": "x://y"]]))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(recorder.tapped.isEmpty)
    }

    // MARK: - The configured point (R72)

    /// A tap after `configure()` returns but before the push manager is wired → exactly one
    /// `push_tapped`, after wiring.
    func testTapBeforeTheConfiguredPointIsTrackedOnceAfterIt() {
        AppDNA.pushModule.manager = nil
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked))
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked), "a duplicate is deduped in the buffer")
        XCTAssertEqual(PushGate.shared.bufferCount, 1)
        XCTAssertTrue(events.isEmpty)

        AppDNA.pushModule.manager = manager
        PushGate.shared.markConfigured()
        settle()
        XCTAssertEqual(events.filter { $0.event_name == "push_tapped" }.count, 1)
        XCTAssertEqual(recorder.tapped.count, 1)
        XCTAssertEqual(PushGate.shared.bufferCount, 0)

        // A later host forward of the same tap is deduped by the B2 idempotency set.
        AppDNA.pushModule.handleNotificationTap(marked)
        XCTAssertEqual(events.filter { $0.event_name == "push_tapped" }.count, 1)
    }

    func testBufferDrainsInArrivalOrderAndKeepsDeliveredAndTappedForOnePush() {
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(marked, inForeground: true, requestId: "r1"))
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(marked, actionIdentifier: nil, requestId: "r1"))
        XCTAssertEqual(PushGate.shared.bufferCount, 2)
        PushGate.shared.markConfigured()
        settle()
        XCTAssertEqual(events.map(\.event_name), ["push_delivered", "push_tapped"])
    }

    func testBufferIsCappedAtEight() {
        for i in 0..<12 {
            AppDNA.pushModule.handleNotificationTap(["appdna": "1", "push_id": "p\(i)"])
        }
        XCTAssertEqual(PushGate.shared.bufferCount, PushGate.bufferCapacity)
    }

    func testDidReceiveEntryReplacesALaunchOptionsEntry() {
        PushGate.shared.bufferLaunchTap(marked)
        AppDNA.pushModule.handleNotificationTap(marked, actionIdentifier: "view", requestId: "r1")
        XCTAssertEqual(PushGate.shared.bufferCount, 1)
        PushGate.shared.markConfigured()
        settle()
        XCTAssertEqual(recorder.tapped.first?.1, "view", "the response's action id wins")
    }

    // MARK: - Impl audit round 2 (I4, I6)

    /// I4: a buffered delivery keeps the foreground state it arrived with. NEGATIVE CONTROL: the drain
    /// used to pass `inForeground: true` for every buffered delivery — this reported `true`.
    func testABufferedDeliveryKeepsItsForegroundState() {
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(marked, inForeground: false, requestId: nil))
        let other: [AnyHashable: Any] = ["appdna": "1", "push_id": "p2", "delivery_id": "d2"]
        XCTAssertTrue(AppDNA.pushModule.handleMessageData(other, inForeground: true, requestId: nil))
        XCTAssertEqual(PushGate.shared.bufferCount, 2)
        PushGate.shared.markConfigured()
        settle()
        XCTAssertEqual(recorder.received.map(\.0), ["p1", "p2"])
        XCTAssertEqual(recorder.received.map(\.1), [false, true])
    }

    /// I6: `shutdown()` clears the launch buffer — a tap buffered before it is not tracked, delivered or
    /// routed after the next `configure()`. NEGATIVE CONTROL: without the clear, the next configure's
    /// drain tracked it (one `push_tapped`).
    func testABufferedTapFollowedByShutdownIsNotTrackedAfterTheNextConfigure() {
        var routed: (String, String)?
        PushTapRouter.routeSink = { routed = ($0, $1) }
        let tap: [AnyHashable: Any] = ["appdna": "1", "push_id": "p1", "delivery_id": "d1", "deep_link": "x://y"]
        XCTAssertTrue(AppDNA.pushModule.handleNotificationTap(tap))
        XCTAssertEqual(PushGate.shared.bufferCount, 1)
        PushGate.shared.markShutDown(epoch: 1)          // what `AppDNA.shutdown()` calls
        XCTAssertEqual(PushGate.shared.bufferCount, 0)
        PushGate.shared.markConfigured(epoch: 2)        // the next `configure()`
        settle(1.5)                                     // past any launch-tap grace
        XCTAssertTrue(events.isEmpty, "\(events.map(\.event_name))")
        XCTAssertTrue(recorder.tapped.isEmpty)
        XCTAssertNil(routed)
    }

    // MARK: - Idempotency

    func testIdempotencyIsPerKindAndCapped() {
        XCTAssertTrue(PushIdempotency.claim(.delivered, key: "k"))
        XCTAssertTrue(PushIdempotency.claim(.tapped, key: "k"))
        XCTAssertFalse(PushIdempotency.claim(.delivered, key: "k"))
        for i in 0..<PushIdempotency.capacity { _ = PushIdempotency.claim(.delivered, key: "fill\(i)") }
        XCTAssertTrue(PushIdempotency.claim(.delivered, key: "k"), "the oldest key was evicted")
    }

    // MARK: - PushTokenManager (B1)

    func testTrackDeliveredAndTappedCarryDeliveryId() {
        manager.trackDelivered(pushId: "p", deliveryId: "d")
        manager.trackTapped(pushId: "p", action: "a", deliveryId: "d")
        manager.trackTapped(pushId: "p2")
        XCTAssertEqual(events.map { $0.properties?["delivery_id"]?.value as? String }, ["d", "d", nil])
        XCTAssertEqual(events[1].properties?["action"]?.value as? String, "a")
    }
}
