// Spec497ImplAuditFixTests.swift
//
// SPEC-497 implementation audit round 1 (I4, native iOS) — the tests the audit found missing (M6) and the
// regression tests for the minors fixed with them:
//   M6  purchase right after `configure` while the bootstrap is in flight; Q5 through the observer;
//       same-product `beginPurchase` / `waitForPurchaseToEnd`; R40 paywall `purchase_restore_failed`.
//   11  a deferred emit survives a nil tracker;  12  activate/deactivate cannot reorder across shutdown;
//   13  identity re-checked at delivery;  15  the late path omits an unknown price;  16  the real
//   `configure` / `identify` drain triggers;  19  a cold-start action-button tap keeps its action id;
//   20  pass-through uses the default presentation;  21  the install-time `willPresent` rule through
//   `install()`;  22  `markConfigured` after `shutdown`;  23  strict arrival order;  24  0.0 / 1.0
//   coordinates;  25  `APIClient.post` uses the override host;  30  no `main.sync` from a background
//   thread. (29, ATT through a fake, is in PermissionRuntimeTests; 26 in StepAdvanceResultFloorTests.)
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
import UserNotifications
@testable import AppDNASDK

// MARK: - Shared helpers

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class DeliveryRecorder: AppDNABillingDelegate {
    private let lock = NSLock()
    private var ids: [String] = []
    var delivered: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
        lock.lock(); ids.append(transaction.transactionId); lock.unlock()
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SDKEvent] = []
    func append(_ e: SDKEvent) { lock.lock(); stored.append(e); lock.unlock() }
    var events: [SDKEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    var names: [String] { events.map(\.event_name) }
}

private func makeTracker(_ log: EventLog) -> EventTracker {
    let t = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.fixr1.\(UUID().uuidString)")))
    t.eventSink = { log.append($0) }
    return t
}

private func poll(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// A local HTTP server that holds the SDK's BOOTSTRAP request — and only that one — unanswered until
/// `release()`, then answers it `401` (a 4xx is not retried, so the bootstrap fails at once). Every other
/// request (the entitlement read, the event upload, …) is answered `401` at once.
///
/// It used to hold EVERY request. A configure that loaded an identified user (the keychain kept the user
/// a previous test identified — whether a simulator test host's keychain write sticks varies run to
/// run) sent the purchase's entitlement refresh here, and `purchase()` hung on it for minutes, until
/// the bootstrap's own 15 s timeout fired and the test failed. Then, at `release()`, the server wrote
/// its answers to sockets URLSession had already closed on timeout: SIGPIPE killed the test process
/// ("Test crashed with signal pipe"). Accepted sockets now set `SO_NOSIGPIPE`, so a write to a closed
/// peer fails with EPIPE instead of killing the process.
private final class HoldingHTTPServer {
    let port: UInt16
    private let fd: Int32
    private let condition = NSCondition()
    private var released = false
    private var bootstrapsReceived = 0
    private var bootstrapsAnswered = 0

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
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        let count = read(client, &buffer, capacity)
        let head = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
        let isBootstrap = head.hasPrefix("GET /api/v1/sdk/bootstrap")
        if isBootstrap {
            condition.lock()
            bootstrapsReceived += 1
            while !released { condition.wait() }
            bootstrapsAnswered += 1
            condition.unlock()
        }
        let reply = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }

    /// The bootstrap reached the server (whether or not it has been answered).
    var bootstrapReceived: Bool {
        condition.lock(); defer { condition.unlock() }
        return bootstrapsReceived > 0
    }

    /// The bootstrap reached the server and has not been answered: it is in flight.
    var bootstrapHeld: Bool {
        condition.lock(); defer { condition.unlock() }
        return bootstrapsReceived > 0 && bootstrapsAnswered == 0
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }

    func stop() { release(); close(fd) }
}

/// What the real `configure` / `identify` in these tests persist outside the SDK object, saved and put
/// back: the keychain identity (user id + traits — `IdentityManager` reads it at the next `configure`) and
/// the first-identified anchor, which `identify` sets once per device and nothing clears. Left behind,
/// a test's `identify` made every later `configure` in the process start as that user.
private struct PersistedIdentity {
    let userId: String?
    let traits: [String: Any]?

    static func save() -> PersistedIdentity {
        let keychain = KeychainStore()
        return PersistedIdentity(userId: keychain.getUserId(), traits: keychain.getUserTraits())
    }

    /// Start from an anonymous device: no persisted user id.
    static func clear() {
        let keychain = KeychainStore()
        keychain.clearUserId()
        keychain.clearUserTraits()
    }

    func restore() {
        let keychain = KeychainStore()
        if let userId { keychain.setUserId(userId) } else { keychain.clearUserId() }
        if let traits { keychain.setUserTraits(traits) } else { keychain.clearUserTraits() }
    }
}

/// Wait for every block already on the SDK's serial queue — off the cooperative pool, since it blocks.
private func drainSDKQueue() async {
    await Task.detached { AppDNA.drainSDKQueueForTesting() }.value
}

// MARK: - Billing

final class Spec497BillingFixTests: XCTestCase {

    /// A hostless test cannot complete a StoreKit purchase (`Product.purchase` → unknown error), so once
    /// the test has proved that `configure` wired the REAL `StoreKit2Bridge`, the purchase call itself is
    /// answered by this `storekit2` stand-in — everything around it (facade, policy, tracker, emit) is real.
    private final class StoreKit2StandIn: BillingBridgeProtocol, @unchecked Sendable {
        private(set) var purchases = 0
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            purchases += 1
            return PurchaseResult(productId: productId, transactionId: "2000000000000777", price: 4.99,
                                  currency: "USD", provider: "storekit2", isSubscription: false,
                                  isConsumable: false, isTrial: false)
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { [] }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    private var server: HoldingHTTPServer?
    private var sdkConfigured = false
    private var savedIdentity: PersistedIdentity?
    /// The dropped-events counter as it was before this test (see `ShutdownUploadIsolation`).
    private var savedDropped = 0

    /// Each test starts from an anonymous device and its own first-identified anchor, whatever an earlier
    /// test in the process left in the keychain or in `UserDefaults.standard`.
    override func setUp() async throws {
        try await super.setUp()
        savedIdentity = PersistedIdentity.save()
        savedDropped = ShutdownUploadIsolation.save()
        PersistedIdentity.clear()
        AppAccountTokenResolver.setDefaultsForTesting(
            UserDefaults(suiteName: "ai.appdna.sdk.fixr1.anchor.\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        if sdkConfigured {
            server?.release()
            let ready = Box(false)
            AppDNA.onReady { ready.value = true }
            let settled = await poll(timeout: 30) { ready.value }
            XCTAssertTrue(settled, "tearDown: the SDK never became ready after the bootstrap was answered")
            AppDNA.eventTrackerForTesting?.eventSink = nil
            AppDNA.shutdown()
            let down = await poll(timeout: 30) { AppDNA.subsystemsUp()["events"] == false }
            XCTAssertTrue(down, "tearDown: shutdown() never landed")
            await drainSDKQueue()
            await Task.detached { [savedDropped] in ShutdownUploadIsolation.restore(savedDropped) }.value
        }
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        await PurchaseDeliveryQueue.shared.setEnvironmentForTesting(.production)
        savedIdentity?.restore()
        savedIdentity = nil
        AppAccountTokenResolver.resetDefaultsForTesting()
        try await super.tearDown()
    }

    // M6 (§3.2 rule 3, R67) — billing is ready from the first call, not after the bootstrap.
    func testPurchaseRightAfterConfigureWhileTheBootstrapIsInFlightUsesStoreKit2AndEmitsOnce() async throws {
        let server = try XCTUnwrap(HoldingHTTPServer(), "could not open a local socket")
        self.server = server
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? "http://127.0.0.1:\(server.port)" : nil }
        APIBaseURL.gateForTesting = { true }

        let ready = Box(false)
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)   // default provider: storeKit2
        sdkConfigured = true
        AppDNA.onReady { ready.value = true }

        // Only as long as `configure`'s own build takes to wire billing — no bootstrap. (30 s: on a starved
        // runner the build itself, on the SDK queue, took longer than 10 s in a reproduction under load.)
        let wired = await poll(timeout: 30) { AppDNA.billing.configured }
        XCTAssertTrue(wired, "configure never wired billing")
        XCTAssertTrue(AppDNA.billing.bridge is StoreKit2Bridge, "the default provider must wire the StoreKit 2 bridge")
        XCTAssertTrue(AppDNA.billing.ownershipPolicy.sdkCanPurchase)
        XCTAssertTrue(AppDNA.billing.ownershipPolicy.ownsTransactions)
        XCTAssertFalse(ready.value, "the bootstrap must still be in flight (the server has not answered)")
        // `configure` starts the bootstrap on a task of its own: wait until the request has actually
        // reached the server before purchasing, or "held" below asks about a request still on its way
        // (CI, on a loaded runner: "the bootstrap must still be in flight when the purchase completes").
        let arrived = await poll { server.bootstrapReceived }
        XCTAssertTrue(arrived, "the bootstrap never reached the local server")
        XCTAssertTrue(server.bootstrapHeld, "the server answered the bootstrap before it was released")

        let standIn = StoreKit2StandIn()
        AppDNA.billing.bridge = standIn
        let log = EventLog()
        AppDNA.eventTrackerForTesting?.eventSink = { log.append($0) }

        let info = try await AppDNA.billing.purchase("lifetime_unlock")
        XCTAssertEqual(info.transactionId, "2000000000000777")
        // The tracker's sink fires synchronously inside `track`, so both events are in the log by now.
        XCTAssertTrue(log.names.contains("purchase_completed"), "got \(log.names)")
        // Bootstrap still unanswered — asserted on the server, not only through the SDK's ready flag.
        XCTAssertTrue(server.bootstrapHeld, "the bootstrap must still be in flight when the purchase completes")
        XCTAssertFalse(ready.value, "the purchase completed while the bootstrap was still in flight")
        // A second emit could only come from an asynchronous path; watch for one (returns early if it appears).
        let duplicated = await poll(timeout: 0.5) { log.names.filter { $0 == "purchase_completed" }.count > 1 }
        XCTAssertFalse(duplicated, "got \(log.names)")
        XCTAssertEqual(standIn.purchases, 1)
        XCTAssertEqual(log.names.filter { $0 == "purchase_completed" }.count, 1, "got \(log.names)")
        XCTAssertEqual(log.names.filter { $0 == "purchase_started" }.count, 1, "got \(log.names)")
    }

    // Minor 16 — the REAL configure trigger (iv) and identify trigger (iii) drain the shared queue.
    func testConfigureAndIdentifyTriggerTheDrain() async throws {
        let shared = PurchaseDeliveryQueue.shared
        let recorder = DeliveryRecorder()
        let suite = UserDefaults(suiteName: "ai.appdna.sdk.fixr1.triggers.\(UUID().uuidString)")!
        let anonymous = Box(true)
        await shared.deactivate()
        await shared.setEnvironmentForTesting(PurchaseDeliveryQueue.Environment(
            defaults: suite,
            now: Date.init,
            // Anonymous until the test switches to the SDK's own identity.
            currentToken: { anonymous.value ? nil : AppAccountTokenResolver.tokenForCurrentUser() },
            firstIdentifiedToken: { AppAccountTokenResolver.firstIdentifiedToken() },
            deliveringDelegate: { recorder },
            tracker: { AppDNA.billing.eventTracker }
        ))
        await shared.recordReport(PendingDelivery(
            transactionId: "cfg1", productId: "p", purchaseTime: 1_000, ownerToken: nil,
            emitPending: false, properties: nil, isSubscription: false
        ))
        _ = await shared.drain()
        XCTAssertEqual(recorder.delivered, [], "no drain before configure activates the queue")

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        sdkConfigured = true
        let viaConfigure = await poll { recorder.delivered == ["cfg1"] }
        XCTAssertTrue(viaConfigure, "configure's trigger (iv) did not deliver; got \(recorder.delivered)")

        let ready = Box(false)
        AppDNA.onReady { ready.value = true }
        let isReady = await poll(timeout: 30) { ready.value }
        XCTAssertTrue(isReady, "configure never became ready")

        // Trigger (iii): an entry tagged for a user who is not signed in waits for that user's identify.
        let userId = "fixr1_\(UUID().uuidString.prefix(8))"
        let owner = try XCTUnwrap(AppAccountTokenResolver.token(forUserId: userId))
        anonymous.value = false
        await shared.recordReport(PendingDelivery(
            transactionId: "idf1", productId: "p", purchaseTime: 1_000, ownerToken: owner.uuidString.lowercased(),
            emitPending: false, properties: nil, isSubscription: false
        ))
        _ = await shared.drain()
        XCTAssertEqual(recorder.delivered, ["cfg1"], "not delivered to another identity")
        AppDNA.identify(userId: userId)
        let viaIdentify = await poll { recorder.delivered == ["cfg1", "idf1"] }
        XCTAssertTrue(viaIdentify, "identify's trigger (iii) did not deliver; got \(recorder.delivered)")
    }
}

final class Spec497QueueFixTests: XCTestCase {

    private final class World {
        let suite = UserDefaults(suiteName: "ai.appdna.sdk.fixr1.queue.\(UUID().uuidString)")!
        let log = EventLog()
        lazy var tracker = makeTracker(log)
        let trackerOn = Box(true)
        let recorder = DeliveryRecorder()
        var currentToken: () -> UUID? = { nil }

        func env() -> PurchaseDeliveryQueue.Environment {
            PurchaseDeliveryQueue.Environment(
                defaults: suite,
                now: Date.init,
                currentToken: { [unowned self] in self.currentToken() },
                firstIdentifiedToken: { nil },
                deliveringDelegate: { [unowned self] in self.recorder },
                tracker: { [unowned self] in self.trackerOn.value ? self.tracker : nil }
            )
        }
    }

    private func entry(_ id: String, owner: UUID? = nil, emitPending: Bool = false,
                       properties: [String: AnyCodable]? = nil) -> PendingDelivery {
        PendingDelivery(transactionId: id, productId: "p_\(id)", purchaseTime: 1_000,
                        ownerToken: owner?.uuidString.lowercased(), emitPending: emitPending,
                        properties: properties, isSubscription: false)
    }

    // M6 — Q5 through the observer: a revoked update removes its queue entry, emits nothing, is finished.
    func testRevokedUpdateThroughTheObserverRemovesTheQueueEntry() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.recordReport(entry("rv1"))
        await q.recordDeferred(entry("rv2", owner: UUID(), emitPending: true))
        let observer = SubscriptionStatusObserver(
            eventTracker: w.tracker, defaults: w.suite, mode: .storeKitOwned,
            loadCurrent: { [:] }, updatesSource: { AsyncStream { $0.finish() } }, deliveryQueue: q
        )
        let finished = Box<[String]>([])
        await observer.handleOwnedUpdate(update("rv1", revoked: true, finished: finished))
        await observer.handleOwnedUpdate(update("rv2", revoked: true, finished: finished))
        let left = await q.queuedIds()
        XCTAssertEqual(left, [], "Q5: a revoked transaction leaves the queue (reported or deferred)")
        XCTAssertEqual(finished.value, ["rv1", "rv2"])
        XCTAssertTrue(w.log.names.isEmpty, "a revocation emits nothing; got \(w.log.names)")

        // …and under a provider that owns transactions the observer touches nothing.
        await q.recordReport(entry("rv3"))
        let providerOwned = SubscriptionStatusObserver(
            eventTracker: w.tracker, defaults: w.suite, mode: .providerOwned,
            loadCurrent: { [:] }, updatesSource: { AsyncStream { $0.finish() } }, deliveryQueue: q
        )
        await providerOwned.handleOwnedUpdate(update("rv3", revoked: true, finished: finished))
        let stillThere = await q.queuedIds()
        XCTAssertEqual(stillThere, ["rv3"])
        XCTAssertEqual(finished.value, ["rv1", "rv2"], "never finished under .providerOwned")
    }

    // M6 — same-product `beginPurchase` / `waitForPurchaseToEnd`, at the queue and through the observer.
    func testSameProductPurchaseInFlightHoldsTheObserverUntilTheLastOneEnds() async throws {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        await q.beginPurchase(productId: "A")
        await q.beginPurchase(productId: "A")
        await q.waitForPurchaseToEnd(productId: "B")          // another product: returns at once

        let observer = SubscriptionStatusObserver(
            eventTracker: w.tracker, defaults: w.suite, mode: .storeKitOwned,
            loadCurrent: { [:] }, updatesSource: { AsyncStream { $0.finish() } }, deliveryQueue: q
        )
        let finished = Box<[String]>([])
        let handling = Task { await observer.handleOwnedUpdate(self.update("t9", productId: "A", finished: finished)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(finished.value, [], "an update of a product with a purchase in flight is not finished")

        await q.endPurchase(productId: "A")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(finished.value, [], "one of the two purchases of A is still in flight")

        // The purchase path reports its transaction before ending — the observer then finishes silently.
        await q.markReported("t9")
        await q.endPurchase(productId: "A")
        await handling.value
        let inFlight = await q.isPurchaseInFlight(productId: "A")
        XCTAssertFalse(inFlight)
        XCTAssertEqual(finished.value, ["t9"])
        XCTAssertTrue(w.log.names.isEmpty, "already reported by the purchase path; got \(w.log.names)")
        XCTAssertEqual(w.recorder.delivered, [])
    }

    // Minor 11, branch 1 — no tracker: the entry is left untouched (emit pending, not delivered).
    func testDeferredEmitWithoutATrackerLeavesTheEntryUntouched() async throws {
        let w = World()
        let owner = UUID()
        w.currentToken = { owner }
        w.trackerOn.value = false
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        let props: [String: AnyCodable] = ["product_id": AnyCodable("p_d1"), "paywall_id": AnyCodable("")]
        await q.recordDeferred(entry("d1", owner: owner, emitPending: true, properties: props))
        let before = w.suite.data(forKey: PurchaseDeliveryQueue.storageKey)

        let delivered = await q.drain()
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(w.suite.data(forKey: PurchaseDeliveryQueue.storageKey), before, "nothing written")
        let stored = await q.entry(transactionId: "d1")
        XCTAssertEqual(stored?.emitPending, true, "no tracker: the emit stays pending")
        let reported = await q.isReported("d1")
        XCTAssertFalse(reported)
        XCTAssertEqual(w.recorder.delivered, [], "not delivered ahead of its emit")
        XCTAssertTrue(w.log.names.isEmpty)
    }

    // Minor 11, branch 2 — tracker present: `emitPending = false` (and the reported id) are PERSISTED
    // before the emit (R46 (2)); the sink reads the stored store at the moment the event is tracked.
    func testDeferredEmitPersistsBeforeEmittingAndEmitsOnce() async throws {
        let w = World()
        let owner = UUID()
        w.currentToken = { owner }
        let seenAtEmit = Box<DeliveryStore?>(nil)
        w.tracker.eventSink = { [suite = w.suite, log = w.log] event in
            if event.event_name == "purchase_completed",
               let data = suite.data(forKey: PurchaseDeliveryQueue.storageKey) {
                seenAtEmit.value = try? JSONDecoder().decode(DeliveryStore.self, from: data)
            }
            log.append(event)
        }
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        let props: [String: AnyCodable] = ["product_id": AnyCodable("p_d2"), "paywall_id": AnyCodable("")]
        await q.recordDeferred(entry("d2", owner: owner, emitPending: true, properties: props))

        _ = await q.drain()
        XCTAssertEqual(w.log.names, ["purchase_completed"])
        let atEmit = try XCTUnwrap(seenAtEmit.value, "nothing was persisted before the emit")
        XCTAssertTrue(atEmit.reported.contains("d2"), "the reported id is persisted before the emit")
        XCTAssertEqual(atEmit.entries.first { $0.transactionId == "d2" }?.emitPending, false,
                       "emitPending = false is persisted before the emit")
        XCTAssertEqual(w.recorder.delivered, ["d2"])
        _ = await q.drain()
        XCTAssertEqual(w.log.names, ["purchase_completed"], "emitted once")
    }

    // Minor 12 — activation of an epoch a shutdown already ended never takes effect, whatever the order.
    func testActivateCannotOutliveTheShutdownOfItsEpoch() async {
        let q = PurchaseDeliveryQueue(environment: World().env())
        await q.deactivate(session: 3)            // shutdown() of epoch 3 ran first…
        await q.activate(session: 3)              // …then configure(3)'s activation Task
        var active = await q.isActive
        XCTAssertFalse(active)
        await q.activate(session: 4)              // the next configure
        active = await q.isActive
        XCTAssertTrue(active)
        await q.deactivate(session: 3)            // a late deactivation of the older epoch
        active = await q.isActive
        XCTAssertTrue(active)
        await q.deactivate(session: 4)
        active = await q.isActive
        XCTAssertFalse(active)
    }

    // Minor 13 — the identity is re-checked on the main actor at delivery time.
    func testIdentityChangeBeforeDeliveryKeepsTheEntryQueued() async {
        let w = World()
        let owner = UUID()
        let reads = Box(0)
        // First read (the drain's check) is the owner; every later read (delivery) is someone else.
        w.currentToken = { reads.value += 1; return reads.value == 1 ? owner : UUID() }
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        await q.recordReport(entry("i1", owner: owner))
        let delivered = await q.drain()
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(w.recorder.delivered, [], "delivered to an identity that signed in mid-drain")
        let left = await q.queuedIds()
        XCTAssertEqual(left, ["i1"])
        XCTAssertGreaterThanOrEqual(reads.value, 2, "the identity was not re-read at delivery")
    }

    // Minor 15 — the late path omits a price it does not know (no fabricated 0 of revenue).
    func testLateEnvelopeOmitsAnUnknownPrice() {
        let facts = TransactionFacts(
            ownershipType: "purchased", revocationDate: nil, isUpgraded: false, reason: "purchase",
            productType: "nonConsumable", id: "5", originalID: "5", appAccountToken: nil, ownerUserId: nil,
            currentToken: nil, currentUserId: nil, alreadyReported: false, purchaseDate: Date(timeIntervalSince1970: 0)
        )
        let unknown = LateEnvelope.make(facts: facts, productId: "p", price: nil, currency: nil, isTrial: false)
            .properties(purchasedAtMs: 0)
        XCTAssertNil(unknown["price"])
        XCTAssertNil(unknown["currency"])
        XCTAssertEqual(unknown["product_id"] as? String, "p")

        let known = LateEnvelope.make(facts: facts, productId: "p", price: 4.99, currency: "EUR", isTrial: false)
            .properties(purchasedAtMs: 0)
        XCTAssertEqual(known["price"] as? Double, 4.99)
        XCTAssertEqual(known["currency"] as? String, "EUR")

        let trial = LateEnvelope.make(facts: facts, productId: "p", price: nil, currency: "EUR", isTrial: true)
            .properties(purchasedAtMs: 0)
        XCTAssertEqual(trial["price"] as? Double, 0, "a free trial is priced 0 by definition")
    }

    private func update(_ id: String, productId: String = "p", revoked: Bool = false,
                        finished: Box<[String]>) -> OwnedTransactionUpdate {
        OwnedTransactionUpdate(
            transactionId: id,
            productId: productId,
            isRevoked: revoked,
            appAccountToken: nil,
            facts: { owner, token, user, reported in
                TransactionFacts(
                    ownershipType: "purchased", revocationDate: revoked ? Date() : nil, isUpgraded: false,
                    reason: "purchase", productType: "nonConsumable", id: id, originalID: id,
                    appAccountToken: nil, ownerUserId: owner, currentToken: token, currentUserId: user,
                    alreadyReported: reported, purchaseDate: Date(timeIntervalSince1970: 0)
                )
            },
            envelope: { facts in
                LateEnvelope.make(facts: facts, productId: productId, price: 1, currency: "USD", isTrial: false)
            },
            finish: { finished.value.append(id) }
        )
    }
}

// MARK: - R40 paywall restore

final class Spec497PaywallRestoreFixTests: XCTestCase {

    private final class Spy: AppDNAPaywallDelegate {
        let failed = Box<[String]>([])
        func onPaywallPresented(paywallId: String) {}
        func onPaywallPurchaseStarted(paywallId: String, productId: String) {}
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {}
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {}
        func onPaywallDismissed(paywallId: String) {}
        let started = Box<Int>(0)
        let messages = Box<[String]>([])
        func onPaywallRestoreStarted(paywallId: String) { started.value += 1 }
        func onPaywallRestoreFailed(paywallId: String, error: Error) {
            failed.value.append(billingErrorType(error))
            messages.value.append(error.localizedDescription)
        }
    }

    /// A restore whose task is cancelled (I4 r7 m3).
    private final class CancelledRestoreBridge: BillingBridgeProtocol, @unchecked Sendable {
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult { throw StoreKit2Error.unknown }
        func restore(appAccountToken: UUID?) async throws -> [String] { throw CancellationError() }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    private final class FailingRestoreBridge: BillingBridgeProtocol, @unchecked Sendable {
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult { throw StoreKit2Error.unknown }
        func restore(appAccountToken: UUID?) async throws -> [String] { throw URLError(.notConnectedToInternet) }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    private func restore(bridge: BillingBridgeProtocol?, provider: BillingProvider, log: EventLog,
                         configured: Bool = true, waitFor: TimeInterval = 5) async -> Spy {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixr1.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: bridge,
            billingPolicy: BillingOwnership.policy(for: provider, bridgeLinked: bridge != nil),
            billingConfigured: { configured },
            eventTracker: makeTracker(log)
        )
        let spy = Spy()
        await MainActor.run {
            manager.handleRestore(paywallId: "pw_r", delegate: spy, viewController: UIViewController(),
                                  dismissGuard: PaywallDismissGuard())
        }
        // `messages` is appended after `failed` in the same callback: wait on the later one.
        _ = await poll(timeout: waitFor) { !spy.messages.value.isEmpty }
        return spy
    }

    /// SPEC-497 I3 r7 m5 — a restore tap while billing is not configured (before `configure`, or after
    /// `shutdown()`) fails with the `unknown` "not configured yet" error, as the purchase tap in the same
    /// window — not `providerNotAvailable` — and never reaches the bridge or `onPaywallRestoreStarted`.
    /// NEGATIVE CONTROL: without the `billingConfigured()` check in `handleRestore`, the StoreKit bridge's
    /// restore runs (Started fires, then the bridge's own network error) — this fails.
    func testNotConfiguredPaywallRestoreFailsUnknownNotConfigured() async {
        let log = EventLog()
        let spy = await restore(bridge: FailingRestoreBridge(), provider: .storeKit2, log: log, configured: false)
        let failed = log.events.filter { $0.event_name == "purchase_restore_failed" }
        XCTAssertEqual(failed.count, 1, "got \(log.names)")
        XCTAssertEqual(failed.first?.properties?["error_type"]?.value as? String, "unknown")
        XCTAssertEqual(failed.first?.properties?["error"]?.value as? String, AppDNA.BillingModule.notConfiguredMessage)
        // I4 R8 m3 — as Android.
        XCTAssertEqual(failed.first?.properties?["reason"]?.value as? String, "not_configured")
        XCTAssertEqual(spy.failed.value, ["unknown"])
        XCTAssertEqual(spy.messages.value, [AppDNA.BillingModule.notConfiguredMessage])
        XCTAssertEqual(spy.started.value, 0, "the restore never started")
    }

    /// SPEC-497 I4 r7 m3 — a cancelled paywall restore is untracked and calls no delegate (symmetry with
    /// Android). NEGATIVE CONTROL: without the `catch is CancellationError` the catch-all tracks one
    /// `purchase_restore_failed` and calls `onPaywallRestoreFailed` — this fails.
    func testCancelledPaywallRestoreIsUntracked() async {
        let log = EventLog()
        await MainActor.run { AppDNA.paywall.skipNextAutoDismissOnRestore = true }
        let spy = await restore(bridge: CancelledRestoreBridge(), provider: .storeKit2, log: log, waitFor: 1)
        // Wait on what the assertions depend on (the start, then the flag cleared on main), not on a clock.
        _ = await poll {
            guard spy.started.value == 1 else { return false }
            return await MainActor.run { !AppDNA.paywall.skipNextAutoDismissOnRestore }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)   // the absence window for a stray failure
        await MainActor.run {}
        XCTAssertEqual(spy.started.value, 1)
        XCTAssertTrue(spy.failed.value.isEmpty, "no onPaywallRestoreFailed")
        XCTAssertEqual(log.events.filter { $0.event_name == "purchase_restore_failed" }.count, 0, "got \(log.names)")
        let flag = await MainActor.run { AppDNA.paywall.skipNextAutoDismissOnRestore }
        XCTAssertFalse(flag, "the one-shot skip flag is cleared")
    }

    func testNoBridgePaywallRestoreFailsWithProviderNotAvailable() async {
        let log = EventLog()
        let spy = await restore(bridge: nil, provider: .none, log: log)
        let failed = log.events.filter { $0.event_name == "purchase_restore_failed" }
        XCTAssertEqual(failed.count, 1, "got \(log.names)")
        XCTAssertEqual(failed.first?.properties?["error_type"]?.value as? String, "providerNotAvailable")
        XCTAssertEqual(failed.first?.properties?["paywall_id"]?.value as? String, "pw_r")
        XCTAssertEqual(failed.first?.properties?["error"]?.value as? String, "No billing provider configured")
        XCTAssertNil(failed.first?.properties?["reason"], "configured: no not_configured reason")
        XCTAssertEqual(spy.failed.value, ["providerNotAvailable"])
    }

    /// SPEC-497 I4 R8 m4 — the refused paywall restore under an unlinked `revenueCat` carries the same
    /// message on both platforms (Android `BillingOwnership.restoreRefusalMessage` now uses this wording).
    func testRevenueCatPaywallRestoreRefusalMessageMatchesAndroid() async {
        let log = EventLog()
        let spy = await restore(bridge: nil, provider: .revenueCat, log: log)
        let failed = log.events.filter { $0.event_name == "purchase_restore_failed" }
        XCTAssertEqual(failed.count, 1, "got \(log.names)")
        XCTAssertEqual(failed.first?.properties?["error"]?.value as? String,
                       "RevenueCat: purchases are made by RevenueCat in your app")
        XCTAssertEqual(spy.messages.value, ["RevenueCat: purchases are made by RevenueCat in your app"])
        XCTAssertEqual(spy.failed.value, ["providerNotAvailable"])
    }

    func testFailedPaywallRestoreCarriesErrorType() async {
        let log = EventLog()
        let spy = await restore(bridge: FailingRestoreBridge(), provider: .storeKit2, log: log)
        let failed = log.events.filter { $0.event_name == "purchase_restore_failed" }
        XCTAssertEqual(failed.count, 1, "got \(log.names)")
        let expected = billingErrorType(URLError(.notConnectedToInternet))
        XCTAssertEqual(failed.first?.properties?["error_type"]?.value as? String, expected)
        XCTAssertEqual(spy.failed.value, [expected])
    }

    /// SPEC-497 §13b.2 (R37–R39, I3 M1) — the direct `BillingModule.restorePurchases()` now tracks its own
    /// `purchase_restore_failed`. A paywall restore must still track exactly ONE, even with the facade wired
    /// to the same tracker and bridge (the paywall calls `bridge.restore` itself, never the facade).
    func testPaywallRestoreStillTracksExactlyOneWithTheFacadeWired() async {
        let log = EventLog()
        let bridge = FailingRestoreBridge()
        let tracker = makeTracker(log)
        // SPEC-497 round 5 (I4 m5) — `AppDNA.billing` is process-wide: save what an earlier test (or a
        // configure) left there and put exactly that back, rather than tearing it down, so the result
        // does not depend on test order.
        let prior = (configured: AppDNA.billing.configured, bridge: AppDNA.billing.bridge,
                     policy: AppDNA.billing.ownershipPolicy, tracker: AppDNA.billing.eventTracker)
        AppDNA.billing.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        defer {
            if prior.configured {
                AppDNA.billing.wire(bridge: prior.bridge, policy: prior.policy, tracker: prior.tracker)
            } else {
                AppDNA.billing.teardown()
                AppDNA.billing.bridge = prior.bridge
                AppDNA.billing.eventTracker = prior.tracker
            }
        }
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixr4.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: bridge,
            billingPolicy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true),
            eventTracker: tracker
        )
        let spy = Spy()
        await MainActor.run {
            manager.handleRestore(paywallId: "pw_r4", delegate: spy, viewController: UIViewController(),
                                  dismissGuard: PaywallDismissGuard())
        }
        _ = await poll(timeout: 5) { !spy.failed.value.isEmpty }
        // Let any stray second emission land before counting.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let failed = log.events.filter { $0.event_name == "purchase_restore_failed" }
        XCTAssertEqual(failed.count, 1, "got \(log.names)")
        XCTAssertEqual(failed.first?.properties?["paywall_id"]?.value as? String, "pw_r4")
    }
}

// MARK: - Push

final class Spec497PushFixTests: XCTestCase {

    private final class PushSpy: AppDNAPushDelegate {
        let tapped = Box<[String]>([])
        let received = Box<[String]>([])
        func onPushReceived(notification: PushPayload, inForeground: Bool) { received.value.append(notification.pushId) }
        func onPushTapped(notification: PushPayload, actionId: String?) {
            tapped.value.append("\(notification.pushId)|\(actionId ?? "nil")")
        }
    }

    private var log: EventLog!
    private var tracker: EventTracker!          // held: PushTokenManager keeps its tracker weakly
    private var manager: PushTokenManager!
    private var spy: PushSpy!

    override func setUp() {
        super.setUp()
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        log = EventLog()
        let keychain = KeychainStore(service: "ai.appdna.sdk.fixr1.push.\(UUID().uuidString)")
        tracker = makeTracker(log)
        manager = PushTokenManager(keychainStore: keychain, eventTracker: tracker, apiClient: nil)
        AppDNA.pushModule.manager = manager
        spy = PushSpy()
        AppDNA.pushDelegate = spy
        PushTapRouter.routeSink = { _, _ in }
    }

    override func tearDown() {
        AppDNA.pushModule.manager = nil
        AppDNA.pushDelegate = nil
        PushTapRouter.routeSink = nil
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        super.tearDown()
    }

    private func push(_ id: String) -> [AnyHashable: Any] { ["appdna": "1", "push_id": id, "delivery_id": "d_\(id)"] }

    private func settle(_ seconds: Double) {
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    private func tapped() -> [String] {
        log.events.filter { $0.event_name == "push_tapped" }.map {
            "\($0.properties?["push_id"]?.value as? String ?? "?")|\($0.properties?["action"]?.value as? String ?? "?")"
        }
    }

    // Minor 19 — cold start: the launch-options entry (no action id) is captured after the configured
    // point, and the proxy's `didReceive` for the same push (with the action button's id) arrives a moment
    // later. The richer one is handled; the tap is tracked once, with its action.
    func testColdStartActionButtonTapKeepsItsActionId() {
        PushGate.shared.launchTapGrace = 0.5
        PushGate.shared.markConfigured()
        PushGate.shared.bufferLaunchTap(push("p1"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDNA.pushModule.handleNotificationTap(self.push("p1"), actionIdentifier: "accept", requestId: "r1")
        }
        settle(1.0)
        XCTAssertEqual(tapped(), ["p1|accept"])
        XCTAssertEqual(spy.tapped.value, ["p1|accept"])
    }

    func testColdStartTapWithoutADidReceiveIsHandledAfterTheGraceAsABodyTap() {
        PushGate.shared.launchTapGrace = 0.2
        PushGate.shared.markConfigured()
        PushGate.shared.bufferLaunchTap(push("p2"))
        settle(0.6)
        XCTAssertEqual(tapped(), ["p2|\(UNNotificationDefaultActionIdentifier)"])
        XCTAssertEqual(spy.tapped.value, ["p2|nil"])
    }

    // Minor 23 — strict arrival order: a call that lands after the configured point but before the buffer
    // has drained queues behind the buffered entries instead of overtaking them.
    func testTheBufferDrainsInStrictArrivalOrder() {
        AppDNA.pushModule.handleNotificationTap(push("a"), actionIdentifier: nil, requestId: "ra")   // buffered
        PushGate.shared.markConfigured()                  // drain scheduled on main — this test holds main
        AppDNA.pushModule.handleNotificationTap(push("b"), actionIdentifier: nil, requestId: "rb")
        AppDNA.pushModule.handleMessageData(push("c"), inForeground: true, requestId: "rc")
        settle(0.3)
        let order = log.events.map { "\($0.event_name):\($0.properties?["push_id"]?.value as? String ?? "?")" }
        XCTAssertEqual(order, ["push_tapped:a", "push_tapped:b", "push_delivered:c"])
    }

    // Minor 22 — a `markConfigured` of an epoch whose `shutdown()` already ran keeps the gate closed.
    func testMarkConfiguredAfterTheShutdownOfItsEpochIsIgnored() {
        PushGate.shared.markShutDown(epoch: 5)
        PushGate.shared.markConfigured(epoch: 5)
        XCTAssertFalse(PushGate.shared.isConfigured)
        XCTAssertTrue(PushGate.shared.isShutDown)
        PushGate.shared.markConfigured(epoch: 6)
        XCTAssertTrue(PushGate.shared.isConfigured)
        XCTAssertFalse(PushGate.shared.isShutDown)
    }

    // Minor 20 — after shutdown the proxy presents with the DEFAULT options, not the Info.plist override.
    func testPassThroughUsesTheDefaultPresentation() {
        PushGate.shared.markConfigured()
        PushGate.shared.markShutDown()
        let core = ProxyCore(previous: nil, advertisesWillPresent: true, presentationOverride: [])
        var options: UNNotificationPresentationOptions = []
        core.willPresent(userInfo: push("s1"), requestId: "rs", forward: nil) { options = $0 }
        XCTAssertEqual(core.lastDecision, .passThrough)
        XCTAssertEqual(NotificationProxyPolicy.names(options), NotificationProxyPolicy.defaultPresentation)
        XCTAssertTrue(log.events.isEmpty)
    }

    // Minor 21 — the install-time `responds(to: willPresent)` rule, through `install(slot:plist:)`.
    func testInstallAppliesTheWillPresentRule() {
        typealias T = SharedFixtureTests
        XCTAssertEqual(T.installedProxyAdvertisesWillPresent(previousKind: "none", override: nil, detectedLibraries: []), true)
        XCTAssertEqual(T.installedProxyAdvertisesWillPresent(previousKind: "implements_both", override: nil, detectedLibraries: []), true)
        XCTAssertEqual(T.installedProxyAdvertisesWillPresent(previousKind: "implements_neither", override: nil, detectedLibraries: []), false)
        XCTAssertEqual(T.installedProxyAdvertisesWillPresent(previousKind: "implements_neither", override: ["banner"], detectedLibraries: []), true)
        XCTAssertEqual(T.installedProxyAdvertisesWillPresent(previousKind: "none", override: nil,
                                                             detectedLibraries: ["FLTFirebaseMessagingPlugin"]), false)
        XCTAssertNil(NSClassFromString("FLTFirebaseMessagingPlugin"), "the throwaway library class is disposed")
    }

    // Minor 30 — `handleMessageData` from a background thread never blocks on the main thread.
    func testHandleMessageDataOffMainDoesNotBlockOnMain() {
        PushGate.shared.markConfigured()
        settle(0.1)
        let returned = Box<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            returned.value = AppDNA.pushModule.handleMessageData(self.push("bg"))
            done.signal()
        }
        // The main thread (this test) waits for the background call — the old `main.sync` deadlocked here.
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "handleMessageData blocked on the main thread")
        XCTAssertEqual(returned.value, true)
        // Round 2 I5: TRACKED synchronously, before the call returned — the main thread has not run yet
        // (it is this test, blocked in `done.wait` above); only `onPushReceived` waits for main.
        XCTAssertEqual(log.names, ["push_delivered"], "tracked before handleMessageData returned")
        XCTAssertEqual(spy.received.value, [], "onPushReceived waits for the main thread")
        settle(0.3)
        XCTAssertEqual(log.names, ["push_delivered"])
        XCTAssertEqual(spy.received.value, ["bg"])
    }
}

// MARK: - Maps / network

final class Spec497MiscFixTests: XCTestCase {

    override func tearDown() {
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        super.tearDown()
    }

    // Minor 24 — 0.0 and 1.0 coordinates survive (an NSNumber 0 / 1 is not a Bool); a real Bool does not.
    func testZeroAndOneCoordinatesSurvive() throws {
        let fromJSON = try JSONSerialization.jsonObject(with: Data(#"{"formatted_address":"x","latitude":0.0,"longitude":1.0}"#.utf8))
        let parsed = try XCTUnwrap(LocationData.fromStoredAnswer(fromJSON))
        XCTAssertEqual(parsed.latitude, 0.0)
        XCTAssertEqual(parsed.longitude, 1.0)

        let native = try XCTUnwrap(LocationData.fromStoredAnswer(["formatted_address": "y", "latitude": 0, "longitude": 1.0] as [String: Any]))
        XCTAssertEqual(native.latitude, 0.0)
        XCTAssertEqual(native.longitude, 1.0)

        let bools = try XCTUnwrap(LocationData.fromStoredAnswer(["formatted_address": "z", "latitude": true, "longitude": false] as [String: Any]))
        XCTAssertNil(bools.latitude)
        XCTAssertNil(bools.longitude)
    }

    // Minor 25 — `APIClient.post` sends to the override host under the same rule as every other request.
    func testPostUsesTheOverrideHost() throws {
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? "https://x.example" : nil }
        APIBaseURL.gateForTesting = { true }
        let sandbox = try APIClient(apiKey: "k", environment: .sandbox).postRequest(path: "/api/v1/sdk/identify", body: ["a": 1])
        XCTAssertEqual(sandbox.url?.host, "x.example")
        XCTAssertEqual(sandbox.url?.path, "/api/v1/sdk/identify")
        XCTAssertEqual(sandbox.httpMethod, "POST")
        XCTAssertEqual(sandbox.value(forHTTPHeaderField: "x-api-key"), "k")
        let production = try APIClient(apiKey: "k", environment: .production).postRequest(path: "/api/v1/sdk/identify", body: [:])
        XCTAssertEqual(production.url?.host, "api.appdna.ai")
    }
}
