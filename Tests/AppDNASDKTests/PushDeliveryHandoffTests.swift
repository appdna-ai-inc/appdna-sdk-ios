// PushDeliveryHandoffTests.swift
//
// `push_delivered` for a push iOS drew while the app was not running. The host's Notification Service
// Extension confirms the delivery to the server itself (the receipt) and, through a shared App Group, hands it to the
// app's SDK, which tracks the analytics event once when it next runs.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UserNotifications
@testable import AppDNASDK
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

final class PushDeliveryHandoffTests: XCTestCase {
    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var manager: PushTokenManager!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        PushIdempotency.resetForTesting()
        let keychain = KeychainStore(service: "ai.appdna.sdk.handoff.\(UUID().uuidString)")
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        events = []
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        manager = PushTokenManager(keychainStore: keychain, eventTracker: tracker, apiClient: nil)
        AppDNA.pushModule.manager = manager
        suite = "ai.appdna.test.handoff.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let store = PushDeliveryHandoff(defaults: defaults)
        PushDeliveryHandoffDrain.storeProvider = { store }
        PushGate.shared.markConfigured()
    }

    override func tearDown() {
        PushDeliveryHandoffDrain.storeProvider = { PushDeliveryHandoff(bundle: .main) }
        AppDNA.pushModule.manager = nil
        PushIdempotency.resetForTesting()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func push(_ delivery: String) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "T", "body": "B"], "mutable-content": 1], "appdna": "1", "push_id": "p1", "delivery_id": delivery]
    }

    /// The extension, as iOS runs it for a push while the app is not running.
    private func extensionReceives(_ userInfo: [AnyHashable: Any]) {
        let service = NotificationService()
        let store = PushDeliveryHandoff(defaults: defaults)
        service.deliveryHandoff = { store }
        service.receiptSender = { _, done in done() }
        let back = expectation(description: "handed back")
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in back.fulfill() }
        wait(for: [back], timeout: 5)
    }

    func testABackgroundDeliveryIsTrackedOnceWhenTheAppNextRuns() {
        extensionReceives(push("d-bg"))
        XCTAssertEqual(PushDeliveryHandoff(defaults: defaults).count, 1, "the extension handed the delivery over")
        XCTAssertTrue(events.isEmpty, "nothing tracked until the app runs")

        XCTAssertEqual(PushDeliveryHandoffDrain.drain(), 1)
        XCTAssertEqual(events.map(\.event_name), ["push_delivered"])
        XCTAssertEqual(events.first?.properties?["delivery_id"]?.value as? String, "d-bg")
        XCTAssertEqual(PushDeliveryHandoff(defaults: defaults).count, 0)

        // A second activation finds nothing.
        XCTAssertEqual(PushDeliveryHandoffDrain.drain(), 0)
        XCTAssertEqual(events.count, 1)
    }

    /// Red control for double counting: a push that arrived in the FOREGROUND runs the extension too and is tracked by
    /// the app's own path; the hand-off must not track it again, even in a later process (idempotency keys are
    /// in-memory, so the store itself must forget it).
    func testAForegroundDeliveryIsNotTrackedAgainFromTheHandoff() {
        extensionReceives(push("d-fg"))
        AppDNA.pushModule.processDelivered(push("d-fg"), inForeground: true)
        XCTAssertEqual(events.map(\.event_name), ["push_delivered"])
        XCTAssertEqual(PushDeliveryHandoff(defaults: defaults).count, 0, "the foreground path removed it")

        PushIdempotency.resetForTesting() // a later process
        XCTAssertEqual(PushDeliveryHandoffDrain.drain(), 0)
        XCTAssertEqual(events.count, 1)
    }

    func testNothingIsDrainedBeforeTheConfiguredPoint() {
        extensionReceives(push("d-early"))
        PushGate.shared.markShutDown()
        XCTAssertEqual(PushDeliveryHandoffDrain.drain(), 0)
        XCTAssertEqual(PushDeliveryHandoff(defaults: defaults).count, 1, "kept for the next drain")
        PushGate.shared.markConfigured()
        XCTAssertEqual(PushDeliveryHandoffDrain.drain(), 1)
    }

    func testTheStoreIsBounded() {
        let store = PushDeliveryHandoff(defaults: defaults)
        for i in 0..<(PushDeliveryHandoff.capacity + 5) { store.record(pushId: "p", deliveryId: "d\(i)") }
        XCTAssertEqual(store.count, PushDeliveryHandoff.capacity)
        XCTAssertEqual(store.takeAll().first?.deliveryId, "d5", "the oldest are dropped")
    }
}
