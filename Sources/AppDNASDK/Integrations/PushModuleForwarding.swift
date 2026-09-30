import Foundation
import UIKit
import UserNotifications

// SPEC-497 B2 (§9.2) + B6 (§9a.4) — the push forwarding API, its idempotency set, the launch buffer and
// the one gate ("the push configured point") that the notification proxy and host forwarding share.

// MARK: - Marker

/// The AppDNA push marker. The server stamps `appdna: "1"` on every push it sends (SPEC-497 B1). A
/// bare `push_id` is NOT enough: hosts and third-party pushers commonly use a `push_id` key of their
/// own, and claiming their messages is exactly the defect B2 removes.
enum PushMarker {
    static func isAppDNA(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["appdna"] as? String) == "1"
    }

    static func pushId(_ userInfo: [AnyHashable: Any]) -> String {
        userInfo["push_id"] as? String ?? ""
    }

    static func deliveryId(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["delivery_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// `delivery_id ?? push_id` — the idempotency and launch-buffer key. Nil when neither is present.
    static func key(_ userInfo: [AnyHashable: Any]) -> String? {
        if let deliveryId = deliveryId(userInfo) { return deliveryId }
        let pushId = pushId(userInfo)
        return pushId.isEmpty ? nil : pushId
    }

    /// Title / body from `aps.alert` (a dictionary or a plain string).
    static func titleAndBody(_ userInfo: [AnyHashable: Any]) -> (String, String) {
        let aps = userInfo["aps"] as? [String: Any]
        if let alert = aps?["alert"] as? [String: Any] {
            return (alert["title"] as? String ?? "", alert["body"] as? String ?? "")
        }
        if let alert = aps?["alert"] as? String { return ("", alert) }
        return (userInfo["title"] as? String ?? "", userInfo["body"] as? String ?? "")
    }
}

// MARK: - Idempotency

/// SPEC-497 §9.2 — an in-process set of handled keys per kind, capped at 256 (oldest evicted). A second
/// call for the same key and kind is a no-op, so the SDK's automatic path (the B6 proxy) and a host's
/// forwarding can both run for one message and it is tracked once. Across a process restart the set is
/// empty — the server's per-delivery status transition keeps that from double-counting.
enum PushIdempotency {
    enum Kind: String { case delivered, tapped }

    private static let lock = NSLock()
    private static var order: [String] = []
    private static var keys: Set<String> = []
    static let capacity = 256

    /// Records `key` for `kind`. Returns `true` when it was new (the caller should handle the push).
    static func claim(_ kind: Kind, key: String) -> Bool {
        let composite = kind.rawValue + "|" + key
        lock.lock(); defer { lock.unlock() }
        guard !keys.contains(composite) else { return false }
        keys.insert(composite)
        order.append(composite)
        if order.count > capacity {
            let evicted = order.removeFirst()
            keys.remove(evicted)
        }
        return true
    }

    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        order.removeAll()
        keys.removeAll()
    }
}

// MARK: - The gate + launch buffer

/// The push **configured point** (SPEC-497 §9a.4, R72): set right after `AppDNA.pushModule.manager` is
/// wired in `configure`, cleared in `shutdown()` — deliberately NOT `isConfigured` (set before anything
/// is built) and NOT `isReady` (set after the bootstrap network call). While it is false, every
/// `handleMessageData` / `handleNotificationTap` — from the proxy AND from host forwarding — goes into
/// the launch buffer and does not record an idempotency key. From the configured point the buffer is
/// drained on the main queue, in arrival order.
final class PushGate {
    static let shared = PushGate()

    struct Entry {
        let kind: PushIdempotency.Kind
        let userInfo: [AnyHashable: Any]
        let requestId: String?
        let actionIdentifier: String?
        let fromLaunchOptions: Bool
    }

    static let bufferCapacity = 8

    private let lock = NSLock()
    private var configured = false
    private var shutDown = false
    private var buffer: [Entry] = []

    var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return configured }
    var isShutDown: Bool { lock.lock(); defer { lock.unlock() }; return shutDown }
    var bufferCount: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    /// Buffers `entry` when the configured point has not been reached. Returns `true` when buffered
    /// (the caller must stop), `false` when the SDK is configured and the caller should handle it now.
    func bufferIfNotConfigured(_ entry: Entry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !configured else { return false }
        insertLocked(entry)
        return true
    }

    /// Launch-options capture (cold start, non-scene fallback). Always buffered.
    func bufferLaunchTap(_ userInfo: [AnyHashable: Any]) {
        lock.lock(); defer { lock.unlock() }
        insertLocked(Entry(kind: .tapped, userInfo: userInfo, requestId: nil, actionIdentifier: nil, fromLaunchOptions: true))
        if configured { scheduleDrainLocked() }
    }

    /// Dedup by `(kind, delivery_id ?? push_id)` and by `(kind, request.identifier)`. A `didReceive`
    /// entry REPLACES a launch-options entry with the same key (the response carries the action id).
    private func insertLocked(_ entry: Entry) {
        let key = PushMarker.key(entry.userInfo)
        if let index = buffer.firstIndex(where: { existing in
            guard existing.kind == entry.kind else { return false }
            if let key, PushMarker.key(existing.userInfo) == key { return true }
            if let rid = entry.requestId, existing.requestId == rid { return true }
            return false
        }) {
            if buffer[index].fromLaunchOptions && !entry.fromLaunchOptions {
                buffer[index] = entry
            }
            return
        }
        guard buffer.count < Self.bufferCapacity else {
            Log.warning("[Push] launch buffer full (\(Self.bufferCapacity)); dropping a \(entry.kind.rawValue) entry")
            return
        }
        buffer.append(entry)
    }

    /// The configured point. Drains the buffer on the main queue, in arrival order.
    func markConfigured() {
        lock.lock()
        configured = true
        shutDown = false
        scheduleDrainLocked()
        lock.unlock()
    }

    /// `shutdown()`: the proxy becomes pass-through for AppDNA pushes until the next configure.
    func markShutDown() {
        lock.lock(); defer { lock.unlock() }
        configured = false
        shutDown = true
    }

    private func scheduleDrainLocked() {
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        lock.lock()
        guard configured else { lock.unlock(); return }
        let entries = buffer
        buffer.removeAll()
        lock.unlock()
        for entry in entries {
            switch entry.kind {
            case .delivered:
                // They arrived in `willPresent`, i.e. in the foreground.
                AppDNA.pushModule.handleMessageData(entry.userInfo, inForeground: true, requestId: entry.requestId)
            case .tapped:
                AppDNA.pushModule.handleNotificationTap(
                    entry.userInfo, actionIdentifier: entry.actionIdentifier, requestId: entry.requestId
                )
            }
        }
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        configured = false
        shutDown = false
        buffer.removeAll()
    }
}

// MARK: - Forwarding API

extension AppDNA.PushModule {

    /// `true` when `userInfo` is an AppDNA push (it carries the `appdna: "1"` marker the server adds).
    /// Use it in your own notification handling to leave AppDNA pushes to AppDNA.
    public func isAppDNAMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        PushMarker.isAppDNA(userInfo)
    }

    /// Forward a received push (e.g. from your own `willPresent`, or a data message). For an AppDNA push
    /// it tracks delivery once (with its `delivery_id`) and fires `AppDNAPushDelegate.onPushReceived`;
    /// it never presents anything. Returns `false`, doing nothing, for any other push.
    @discardableResult
    public func handleMessageData(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard PushMarker.isAppDNA(userInfo) else { return false }
        return handleMessageData(userInfo, inForeground: Self.applicationIsActive(), requestId: nil)
    }

    /// Forward a notification tap (e.g. from your own `didReceive`, with `response.actionIdentifier`).
    /// For an AppDNA push it tracks the tap once, fires `AppDNAPushDelegate.onPushTapped` and routes the
    /// push's action (`show_screen` / deep link). Returns `false`, doing nothing, for any other push.
    @discardableResult
    public func handleNotificationTap(_ userInfo: [AnyHashable: Any], actionIdentifier: String? = nil) -> Bool {
        handleNotificationTap(userInfo, actionIdentifier: actionIdentifier, requestId: nil)
    }

    /// The one delivered path — host forwarding, the proxy's `willPresent` and the launch-buffer drain
    /// all come here.
    @discardableResult
    func handleMessageData(_ userInfo: [AnyHashable: Any], inForeground: Bool, requestId: String?) -> Bool {
        guard PushMarker.isAppDNA(userInfo) else { return false }
        if PushGate.shared.bufferIfNotConfigured(.init(
            kind: .delivered, userInfo: userInfo, requestId: requestId, actionIdentifier: nil, fromLaunchOptions: false
        )) {
            return true
        }
        if let key = PushMarker.key(userInfo), !PushIdempotency.claim(.delivered, key: key) {
            return true
        }
        let pushId = PushMarker.pushId(userInfo)
        manager?.trackDelivered(pushId: pushId, deliveryId: PushMarker.deliveryId(userInfo))
        // Fold push_id into the 30-min window so subsequent events carry context.push_id (mirrors
        // Android's PushSessionContext.recordPushReceived on delivery).
        PushSessionContext.recordPushReceived(pushId)
        PushActionCategories.register(from: userInfo, slot: NotificationProxyBootstrap.categorySlot())
        let (title, body) = PushMarker.titleAndBody(userInfo)
        let payload = PushPayloadParser.parse(userInfo: userInfo, title: title, body: body)
        AppDNA.pushDelegate?.onPushReceived(notification: payload, inForeground: inForeground)
        return true
    }

    /// The one tap path — host forwarding, the proxy's `didReceive` and the launch-buffer drain.
    @discardableResult
    func handleNotificationTap(_ userInfo: [AnyHashable: Any], actionIdentifier: String?, requestId: String?) -> Bool {
        guard PushMarker.isAppDNA(userInfo) else { return false }
        if PushGate.shared.bufferIfNotConfigured(.init(
            kind: .tapped, userInfo: userInfo, requestId: requestId, actionIdentifier: actionIdentifier, fromLaunchOptions: false
        )) {
            return true
        }
        if let key = PushMarker.key(userInfo), !PushIdempotency.claim(.tapped, key: key) {
            return true
        }
        let pushId = PushMarker.pushId(userInfo)
        // The TRACKED action is the system identifier for a body tap (R69); routing and `onPushTapped`
        // keep `nil` for a body tap, as they always have.
        manager?.trackTapped(
            pushId: pushId,
            action: actionIdentifier ?? UNNotificationDefaultActionIdentifier,
            deliveryId: PushMarker.deliveryId(userInfo)
        )
        PushSessionContext.recordPushReceived(pushId)

        let (title, body) = PushMarker.titleAndBody(userInfo)
        let payload = PushPayloadParser.parse(userInfo: userInfo, title: title, body: body)
        let tappedAction = (actionIdentifier == nil || actionIdentifier == UNNotificationDefaultActionIdentifier)
            ? nil : actionIdentifier
        AppDNA.pushDelegate?.onPushTapped(notification: payload, actionId: tappedAction)

        // SPEC-089c / SPEC-497 §9.2: auto-route with the ladder.
        PushTapRouter.perform(PushTapRouter.route(payload: payload, userInfo: userInfo, tappedActionId: tappedAction))
        return true
    }

    /// `UIApplication.shared.applicationState == .active`, read on the main thread. The shared
    /// application is looked up dynamically: a hostless unit test has none.
    static func applicationIsActive() -> Bool {
        let read: () -> Bool = {
            let applicationClass: AnyObject = UIApplication.self
            guard let app = applicationClass.value(forKey: "sharedApplication") as? UIApplication else { return false }
            return app.applicationState == .active
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
}
