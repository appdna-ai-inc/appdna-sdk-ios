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
/// drained on the main queue, in STRICT arrival order: until it is empty, a new call joins the back of
/// the buffer instead of overtaking the entries ahead of it.
///
/// Cold-start action buttons: the launch-options entry carries no action identifier. It waits
/// `launchTapGrace` (from when it was captured) for the proxy's `didReceive` — which carries the action
/// id — to replace it in its slot, so the richer event is the one handled and the key is never claimed
/// by the poorer one first.
final class PushGate {
    static let shared = PushGate()

    struct Entry {
        let kind: PushIdempotency.Kind
        let userInfo: [AnyHashable: Any]
        let requestId: String?
        let actionIdentifier: String?
        let fromLaunchOptions: Bool
        var capturedAt: Date = Date()
        /// A delivered entry's foreground state, as its caller saw it (impl audit round 2, I4) — the
        /// proxy's `willPresent` is foreground, a host forward may not be. `nil`: not known where it
        /// arrived (off the main thread); the drain reads it on main when it handles the entry.
        var inForeground: Bool? = true
    }

    static let bufferCapacity = 8

    /// How long a launch-options tap waits for its `didReceive` before it is handled as a body tap.
    var launchTapGrace: TimeInterval = 1.0

    private let lock = NSLock()
    private var configured = false
    private var shutDown = false
    /// The newest configure epoch `shutdown()` ended; a `markConfigured(epoch:)` for it (or an older one)
    /// that lands late is ignored.
    private var shutDownThrough = 0
    private var buffer: [Entry] = []
    private var draining = false

    var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return configured }
    var isShutDown: Bool { lock.lock(); defer { lock.unlock() }; return shutDown }
    var bufferCount: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    /// Buffers `entry` when the configured point has not been reached — or when it has but earlier
    /// entries are still waiting to drain (arrival order). Returns `true` when buffered (the caller must
    /// stop), `false` when the caller should handle it now.
    func bufferIfNotConfigured(_ entry: Entry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !configured || !buffer.isEmpty || draining else { return false }
        insertLocked(entry)
        if configured { scheduleDrainLocked() }
        return true
    }

    /// Launch-options capture (cold start, non-scene fallback). Always buffered.
    func bufferLaunchTap(_ userInfo: [AnyHashable: Any]) {
        lock.lock(); defer { lock.unlock() }
        insertLocked(Entry(kind: .tapped, userInfo: userInfo, requestId: nil, actionIdentifier: nil, fromLaunchOptions: true))
        if configured { scheduleDrainLocked() }
    }

    /// Dedup by `(kind, delivery_id ?? push_id)` and by `(kind, request.identifier)`. A `didReceive`
    /// entry REPLACES a launch-options entry with the same key, in its slot (the response carries the
    /// action id).
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
        guard buffer.count < Self.bufferCapacity || configured else {
            Log.warning("[Push] launch buffer full (\(Self.bufferCapacity)); dropping a \(entry.kind.rawValue) entry")
            return
        }
        buffer.append(entry)
    }

    /// The configured point. Drains the buffer on the main queue, in arrival order. `epoch` is the
    /// configure epoch: a `markConfigured` that lands after the `shutdown()` of its own epoch is ignored,
    /// so a `shutdown()` racing a late `configure` build cannot leave the gate open. `nil` (tests) always
    /// opens it.
    func markConfigured(epoch: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let epoch, epoch <= shutDownThrough { return }
        configured = true
        shutDown = false
        scheduleDrainLocked()
    }

    /// `shutdown()`: the proxy becomes pass-through for AppDNA pushes until the next configure. The
    /// launch buffer is CLEARED (impl audit round 2, I6): a push buffered before `shutdown()` belongs to
    /// the session that ended — the next `configure()` (possibly another user, after a sign-out) must
    /// not track, deliver or route it.
    func markShutDown(epoch: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let epoch { shutDownThrough = max(shutDownThrough, epoch) }
        configured = false
        shutDown = true
        buffer.removeAll()
    }

    /// Drains run on the main queue, one at a time (`draining`); an extra scheduled drain finds the
    /// buffer empty (or a grace still running) and returns.
    private func scheduleDrainLocked(after delay: TimeInterval = 0) {
        let work: () -> Void = { [weak self] in self?.drain() }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// One entry at a time, head first. A launch-options head still inside its grace window pauses the
    /// drain (everything behind it waits, keeping arrival order) until the grace ends or its `didReceive`
    /// replaces it.
    private func drain() {
        lock.lock()
        guard configured, !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        while true {
            lock.lock()
            guard configured, let head = buffer.first else {
                draining = false
                lock.unlock()
                return
            }
            if head.fromLaunchOptions {
                let remaining = launchTapGrace - Date().timeIntervalSince(head.capturedAt)
                if remaining > 0 {
                    draining = false
                    scheduleDrainLocked(after: remaining)
                    lock.unlock()
                    return
                }
            }
            buffer.removeFirst()
            lock.unlock()
            switch head.kind {
            case .delivered:
                // The state each entry was buffered with (I4); one that arrived off the main thread is
                // read now, on main.
                AppDNA.pushModule.processDelivered(
                    head.userInfo,
                    inForeground: head.inForeground ?? AppDNA.PushModule.applicationIsActiveOnMain() ?? false
                )
            case .tapped:
                AppDNA.pushModule.processTapped(head.userInfo, actionIdentifier: head.actionIdentifier)
            }
        }
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        configured = false
        shutDown = false
        shutDownThrough = 0
        buffer.removeAll()
        draining = false
        launchTapGrace = 1.0
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
        // Off the main thread (a host's FCM callback) the application state cannot be read here.
        // Per §9.2/§8.2: the delivery is TRACKED synchronously, on this thread, before this returns; the
        // off-main work — reading the foreground state and firing `onPushReceived` — runs async on main.
        // (A `DispatchQueue.main.sync` read would deadlock when the main thread is waiting on this thread
        // — proven by `testHandleMessageDataOffMainDoesNotBlockOnMain`.)
        return handleMessageData(userInfo, inForeground: Self.applicationIsActiveOnMain(), requestId: nil)
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
    /// `inForeground` nil: the caller is off the main thread and could not read it (read on main later).
    @discardableResult
    func handleMessageData(_ userInfo: [AnyHashable: Any], inForeground: Bool?, requestId: String?) -> Bool {
        guard PushMarker.isAppDNA(userInfo) else { return false }
        if PushGate.shared.bufferIfNotConfigured(.init(
            kind: .delivered, userInfo: userInfo, requestId: requestId, actionIdentifier: nil, fromLaunchOptions: false,
            inForeground: inForeground
        )) {
            return true
        }
        processDelivered(userInfo, inForeground: inForeground)
        return true
    }

    /// Past the gate: track once (synchronously, on the calling thread), fire `onPushReceived` — directly
    /// on main when the foreground state is known there, else on main asynchronously with the state read
    /// on main.
    func processDelivered(_ userInfo: [AnyHashable: Any], inForeground: Bool?) {
        if let key = PushMarker.key(userInfo), !PushIdempotency.claim(.delivered, key: key) {
            return
        }
        let pushId = PushMarker.pushId(userInfo)
        manager?.trackDelivered(pushId: pushId, deliveryId: PushMarker.deliveryId(userInfo))
        // Fold push_id into the 30-min window so subsequent events carry context.push_id (mirrors
        // Android's PushSessionContext.recordPushReceived on delivery).
        PushSessionContext.recordPushReceived(pushId)
        // The rest — category registration (it interpolates labels with the template engine) and the
        // delegate — stays on the main thread, as before.
        let notify: (Bool) -> Void = { foreground in
            PushActionCategories.register(from: userInfo, slot: NotificationProxyBootstrap.categorySlot())
            let (title, body) = PushMarker.titleAndBody(userInfo)
            let payload = PushPayloadParser.parse(userInfo: userInfo, title: title, body: body)
            AppDNA.pushDelegate?.onPushReceived(notification: payload, inForeground: foreground)
        }
        if Thread.isMainThread {
            notify(inForeground ?? Self.applicationIsActiveOnMain() ?? false)
            return
        }
        DispatchQueue.main.async {
            notify(inForeground ?? Self.applicationIsActiveOnMain() ?? false)
        }
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
        processTapped(userInfo, actionIdentifier: actionIdentifier)
        return true
    }

    /// Past the gate: track once, fire `onPushTapped`, route.
    func processTapped(_ userInfo: [AnyHashable: Any], actionIdentifier: String?) {
        if let key = PushMarker.key(userInfo), !PushIdempotency.claim(.tapped, key: key) {
            return
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
    }

    /// `UIApplication.shared.applicationState == .active`. `applicationState` is main-thread-only, and a
    /// `DispatchQueue.main.sync` from a background thread can deadlock against a main thread that is
    /// waiting on that thread — so this is read ONLY on the main thread (`nil` elsewhere). The
    /// application is looked up dynamically: a hostless unit test has none.
    static func applicationIsActiveOnMain() -> Bool? {
        guard Thread.isMainThread else { return nil }
        let applicationClass: AnyObject = UIApplication.self
        guard let app = applicationClass.value(forKey: "sharedApplication") as? UIApplication else { return false }
        return app.applicationState == .active
    }
}
