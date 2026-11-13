import Foundation
import FirebaseFirestore
import UIKit
import SwiftUI

/// Listens for journey-triggered in-app messages at
/// `orgs/{orgId}/apps/{appId}/users/{id}/pending_messages` and
/// renders them through the same `MessageRenderer` pipeline used for
/// remote-config-driven messages, so a journey-delivered modal /
/// fullscreen / banner / tooltip looks identical to one configured in
/// the console. Writes `consumed: true` back to Firestore after display
/// so repeat polls / the REST fallback don't double-deliver.
///
/// WHICH ids it listens on. A journey enrols the unit the server keys every event on, `user_id ?? anon_id`,
/// and delivers each of its in-app steps to that enrolment's id for the life of the enrolment. So:
///   - from configure, the device's ANON id — an anonymous user's journey writes there (the listener used to start
///     only at `identify`, so those messages were marked sent and never drawn);
///   - after `identify`, the anon id AND the user id — a journey that enrolled the device anonymously keeps writing to
///     the anon id after the user signs in, and a journey that enrols the signed-in user writes to the user id;
///   - after `reset()`, the anon id again (the anon id survives a reset; the signed-out user's id is dropped).
/// `listenIds(anonId:userId:)` is that rule; `follow(...)` applies it, keeping a listener that is still wanted (no
/// restart, so no re-delivery) and remembering what it presented (a delivery is drawn at most once per process).
final class PendingMessageListener {

    /// One delivery document as a subscription hands it over.
    struct Delivery {
        let id: String
        let data: [String: Any]
        /// Writes `consumed: true` back to the delivery document.
        let markConsumed: () -> Void
    }

    /// Opens a listener on one user's unconsumed deliveries (`path` = `orgs/{o}/apps/{a}/users/{id}/pending_messages`);
    /// the closure it returns removes it. The default is the Firestore snapshot listener; a test passes its own.
    typealias Subscribe = (_ orgId: String, _ appId: String, _ id: String, _ onAdded: @escaping (Delivery) -> Void) -> (() -> Void)?
    /// Draws a delivery. `onShown(true)` once it is on screen, `onShown(false)` when it could not be drawn (no window
    /// yet); `onClosed` when the user dismissed it. The default is `MessageRenderer` over the top view controller.
    typealias Present = (_ deliveryId: String, _ config: MessageConfig, _ onShown: @escaping (Bool) -> Void, _ onClosed: @escaping () -> Void) -> Void
    /// Runs `block` after `seconds` — the retry of a delivery that could not be drawn yet.
    typealias Schedule = (_ seconds: Double, _ block: @escaping () -> Void) -> Void
    /// Calls `block` each time the app (one of its scenes) becomes active; the closure it returns stops that. The
    /// default observes `UIApplication.didBecomeActiveNotification` and `UIScene.didActivateNotification`.
    typealias ObserveActivation = (_ block: @escaping () -> Void) -> (() -> Void)

    /// The ids whose deliveries the device shows: the anon id, then the user id when it is set and different.
    static func listenIds(anonId: String?, userId: String?) -> [String] {
        var ids: [String] = []
        if let a = anonId, !a.isEmpty { ids.append(a) }
        if let u = userId, !u.isEmpty, !ids.contains(u) { ids.append(u) }
        return ids
    }

    /// How many times a delivery that could not be drawn (no window yet, at a cold launch) is retried.
    static let maxPresentAttempts = 5

    /// #1782 — a delivery that is still undrawn when its retries run out (the app was launched in the BACKGROUND —
    /// a content-available push, a background task — so there is no window, and the retries last seconds) waits
    /// here, and is drawn the next time the app becomes active. Without this it waited for the process to die: the
    /// listener hands a document over once, so the same process never saw it again, however often the user opened
    /// the app.

    private struct Pending {
        let key: String
        let ownerKey: String
        let delivery: Delivery
        let config: MessageConfig
    }

    private weak var eventTracker: EventTracker?
    private let subscribe: Subscribe
    private let presentDelivery: Present
    private let schedule: Schedule
    private let lock = NSLock()
    private final class Token {}
    private struct Subscription {
        let token: Token
        /// nil while the listener is being opened.
        let remove: (() -> Void)?
    }
    /// Live subscriptions, keyed `org/app/id`.
    private var subscriptions: [String: Subscription] = [:]
    /// The delivery on screen (or being put there), keyed `org/app/id/deliveryId`.
    private var presentingKey: String?
    /// Deliveries that arrived while another was on screen, in arrival order.
    private var waiting: [Pending] = []
    /// Deliveries drawn by this process — a re-delivered document (a listener re-opened before the `consumed` write
    /// landed) is never drawn twice.
    private var presented: Set<String> = []
    private var attempts: [String: Int] = [:]
    /// Deliveries whose retries ran out with no window to draw in, in arrival order (#1782).
    private var parked: [Pending] = []
    private var stopActivation: (() -> Void)?

    init(
        eventTracker: EventTracker?,
        subscribe: Subscribe? = nil,
        present: Present? = nil,
        schedule: Schedule? = nil,
        observeActivation: ObserveActivation? = nil
    ) {
        self.eventTracker = eventTracker
        self.subscribe = subscribe ?? PendingMessageListener.firestoreSubscribe
        self.presentDelivery = present ?? { [weak eventTracker] id, config, onShown, onClosed in
            PendingMessageListener.presentOnTopViewController(
                tracker: eventTracker, messageId: id, config: config, onShown: onShown, onClosed: onClosed
            )
        }
        self.schedule = schedule ?? { seconds, block in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block) }
        let observe = observeActivation ?? PendingMessageListener.observeAppActivation
        self.stopActivation = observe({ [weak self] in self?.presentParked() })
    }

    /// Both notifications: an app with scenes posts the scene one per scene and the app one once; an app without
    /// scenes posts only the app one. A second call finds nothing parked, so a delivery is not drawn twice.
    private static func observeAppActivation(_ block: @escaping () -> Void) -> (() -> Void) {
        let center = NotificationCenter.default
        let tokens = [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { _ in block() }
        }
        return { tokens.forEach { center.removeObserver($0) } }
    }

    /// The app became active: every parked delivery that is still listened on and not expired gets a fresh round of
    /// attempts, in arrival order.
    private func presentParked() {
        let now = Date()
        lock.lock()
        let due = parked.filter { subscriptions[$0.ownerKey] != nil && !presented.contains($0.key) }
        parked.removeAll()
        for p in due { attempts[p.key] = 0 }
        lock.unlock()
        for p in due {
            guard Self.decodeDelivery(data: p.delivery.data, now: now) != nil else {
                Log.debug("PendingMessageListener: \(p.delivery.id) expired while waiting for a window — dropped")
                continue
            }
            Log.debug("PendingMessageListener: app active — presenting \(p.delivery.id), parked with no window")
            retry(p)
        }
    }

    /// Listen on exactly `listenIds(anonId:userId:)` under this org and app: a listener still wanted is kept as it is,
    /// one no longer wanted is removed (and its waiting deliveries dropped), a new one is opened. Called at configure
    /// (once the bootstrap names the org and app), on a recovered bootstrap, on `identify` and on `reset()`.
    func follow(orgId: String, appId: String, anonId: String?, userId: String?) {
        let wanted = Self.listenIds(anonId: anonId, userId: userId).map { (id: $0, key: "\(orgId)/\(appId)/\($0)") }
        let wantedKeys = Set(wanted.map(\.key))
        lock.lock()
        let removed = subscriptions.filter { !wantedKeys.contains($0.key) }
        for key in removed.keys { subscriptions.removeValue(forKey: key) }
        waiting.removeAll { !wantedKeys.contains($0.ownerKey) }
        parked.removeAll { !wantedKeys.contains($0.ownerKey) }
        let toOpen = wanted.filter { subscriptions[$0.key] == nil }
        // Registered before the listener opens: its first snapshot (the deliveries already waiting) may arrive at once.
        var placeholders: [String: Token] = [:]
        for w in toOpen {
            let token = Token()
            placeholders[w.key] = token
            subscriptions[w.key] = Subscription(token: token, remove: nil)
        }
        lock.unlock()
        for (_, sub) in removed { sub.remove?() }
        for w in toOpen {
            Log.debug("PendingMessageListener: observing orgs/\(orgId)/apps/\(appId)/users/\(w.id)/pending_messages")
            let ownerKey = w.key
            let remove = subscribe(orgId, appId, w.id, { [weak self] delivery in
                self?.handleIncoming(ownerKey: ownerKey, delivery: delivery, now: Date())
            })
            lock.lock()
            let stillOurs = subscriptions[w.key]?.token === placeholders[w.key]
            if stillOurs {
                if let remove { subscriptions[w.key] = Subscription(token: placeholders[w.key]!, remove: remove) }
                else { subscriptions.removeValue(forKey: w.key) }
            }
            lock.unlock()
            if !stillOurs { remove?() }
        }
    }

    /// The ids listened on now (`org/app/id`), sorted — what a test reads.
    var observedKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return subscriptions.keys.sorted()
    }

    /// Tear down every listener. Called from `AppDNA.shutdown()`.
    func stopObserving() {
        lock.lock()
        let all = Array(subscriptions.values)
        subscriptions.removeAll()
        waiting.removeAll()
        parked.removeAll()
        lock.unlock()
        for sub in all { sub.remove?() }
    }

    deinit {
        stopActivation?()
        stopObserving()
    }

    // MARK: - Private

    private func handleIncoming(ownerKey: String, delivery: Delivery, now: Date) {
        guard let config = Self.decodeDelivery(data: delivery.data, now: now) else {
            Log.debug("PendingMessageListener: skipping \(delivery.id) (expired or missing content)")
            return
        }
        let key = "\(ownerKey)/\(delivery.id)"
        lock.lock()
        // Still listened on (a late callback from a removed listener is ignored), and not already drawn or queued.
        guard subscriptions[ownerKey] != nil, !presented.contains(key), presentingKey != key,
              !waiting.contains(where: { $0.key == key }) else { lock.unlock(); return }
        let firstSight = attempts[key] == nil
        if firstSight { attempts[key] = 0 }
        lock.unlock()

        if firstSight {
            eventTracker?.track(event: "in_app_message_received", properties: [
                "delivery_id": delivery.id,
                "trigger": (delivery.data["trigger"] as? String) ?? "journey",
                "source": "pending_messages",
            ])
        }
        enqueue(Pending(key: key, ownerKey: ownerKey, delivery: delivery, config: config))
    }

    private func enqueue(_ p: Pending) {
        lock.lock()
        if presentingKey != nil {
            Log.debug("PendingMessageListener: another message presenting — queueing \(p.delivery.id)")
            waiting.append(p)
            lock.unlock()
            return
        }
        presentingKey = p.key
        lock.unlock()
        presentNow(p)
    }

    private func presentNow(_ p: Pending) {
        presentDelivery(p.delivery.id, p.config, { [weak self] rendered in
            guard let self else { return }
            if rendered {
                self.lock.lock(); self.presented.insert(p.key); self.lock.unlock()
                p.delivery.markConsumed()
                self.eventTracker?.track(event: "in_app_message_shown", properties: [
                    "delivery_id": p.delivery.id,
                    "source": "pending_messages",
                    "message_type": p.config.message_type?.rawValue ?? "modal",
                ])
            } else {
                // Not drawn (no window yet at a cold launch): the document stays unconsumed; retried a few times.
                self.lock.lock()
                self.presentingKey = nil
                let n = (self.attempts[p.key] ?? 0) + 1
                self.attempts[p.key] = n
                self.lock.unlock()
                if n < Self.maxPresentAttempts {
                    self.schedule(Double(n)) { [weak self] in self?.retry(p) }
                } else {
                    // #1782 — no window for the whole retry window (a background launch): drawn when the app is next
                    // active. The document stays unconsumed meanwhile, so a cold launch still draws it too.
                    self.lock.lock()
                    if !self.parked.contains(where: { $0.key == p.key }) { self.parked.append(p) }
                    self.lock.unlock()
                    Log.debug("PendingMessageListener: no window after \(n) attempts — \(p.delivery.id) waits for the app to be active")
                }
                self.presentNext()
            }
        }, { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.presentingKey = nil; self.lock.unlock()
            self.presentNext()
        })
    }

    private func retry(_ p: Pending) {
        lock.lock()
        let live = subscriptions[p.ownerKey] != nil && !presented.contains(p.key)
            && presentingKey != p.key && !waiting.contains(where: { $0.key == p.key })
            && !parked.contains(where: { $0.key == p.key })
        lock.unlock()
        if live { enqueue(p) }
    }

    private func presentNext() {
        lock.lock()
        guard presentingKey == nil, !waiting.isEmpty else { lock.unlock(); return }
        let next = waiting.removeFirst()
        presentingKey = next.key
        lock.unlock()
        presentNow(next)
    }

    private static func firestoreSubscribe(
        orgId: String, appId: String, id: String, onAdded: @escaping (Delivery) -> Void
    ) -> (() -> Void)? {
        guard let db = AppDNA.firestoreDB else {
            Log.debug("PendingMessageListener: Firestore not configured — skipping")
            return nil
        }
        let registration = db
            .collection("orgs").document(orgId)
            .collection("apps").document(appId)
            .collection("users").document(id)
            .collection("pending_messages")
            .whereField("consumed", isEqualTo: false)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Log.error("PendingMessageListener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot else { return }
                for change in snapshot.documentChanges where change.type == .added {
                    let doc = change.document
                    onAdded(Delivery(id: doc.documentID, data: doc.data(), markConsumed: {
                        doc.reference.updateData(["consumed": true]) { err in
                            if let err {
                                Log.warning("PendingMessageListener: failed to mark consumed: \(err.localizedDescription)")
                            }
                        }
                    }))
                }
            }
        return { registration.remove() }
    }

    /// The delivery document as the listener receives it → the `MessageConfig` it presents, or nil
    /// when the delivery is expired or carries no `content`. The one decode `handleIncoming` runs;
    /// static so a test can drive it with a document read back from Firestore.
    static func decodeDelivery(data: [String: Any], now: Date) -> MessageConfig? {
        // Server-side expiry filter (TTL): Firestore lacks compound
        // `expires_at > now AND consumed == false` without a composite
        // index, so we filter locally.
        if let expiresMs = (data["expires_at_ms"] as? NSNumber)?.doubleValue {
            let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
            if expiresAt < now { return nil }
        }
        guard let content = data["content"] as? [String: Any] else { return nil }
        // Decode the delivered Firestore content into the same Codable
        // `MessageConfig` shape used by the remote-config pipeline so we
        // can route through the existing `MessageRenderer` views (modal,
        // fullscreen, banner, tooltip) with full styling + rich-media
        // support — instead of falling back to a plain UIAlertController.
        return decodeMessageConfig(content: content, root: data)
    }

    /// Best-effort decode of the delivered content into `MessageConfig`.
    /// Server payload mirrors the InAppMessageTrigger schema, so a
    /// JSONSerialization roundtrip + JSONDecoder works cleanly. On
    /// failure (corrupt or malformed payload) we synthesize a minimal
    /// modal config with whatever string fields we can salvage.
    static func decodeMessageConfig(content: [String: Any], root: [String: Any]) -> MessageConfig {
        // Build a config-shaped dict so MessageConfig (which expects
        // top-level message_type + content + etc) can decode it.
        var configDict: [String: Any] = [:]
        configDict["content"] = content
        if let mt = root["message_type"] as? String { configDict["message_type"] = mt }
        else if let mt = content["message_type"] as? String { configDict["message_type"] = mt }
        if let pri = root["priority"] as? Int { configDict["priority"] = pri }
        if let name = root["trigger_id"] as? String { configDict["name"] = name }

        do {
            let json = try JSONSerialization.data(withJSONObject: configDict)
            let decoded = try JSONDecoder().decode(MessageConfig.self, from: json)
            return decoded
        } catch {
            Log.warning("PendingMessageListener: MessageConfig decode failed (\(error.localizedDescription)) — using fallback")
            // Fallback: minimal modal with whatever copy we can extract.
            let fallbackContent = MessageContent(
                title: content["title"] as? String,
                body: (content["body"] as? String) ?? (content["message"] as? String),
                image_url: content["image_url"] as? String,
                cta_text: (content["cta_text"] as? String) ?? "OK",
                cta_action: nil,
                dismiss_text: content["dismiss_text"] as? String,
                background_color: content["background_color"] as? String,
                banner_position: nil,
                auto_dismiss_seconds: content["auto_dismiss_seconds"] as? Int,
                text_color: content["text_color"] as? String,
                button_color: content["button_color"] as? String,
                button_text_color: content["button_text_color"] as? String,
                button_corner_radius: content["button_corner_radius"] as? Int,
                corner_radius: content["corner_radius"] as? Int,
                secondary_cta_text: content["secondary_cta_text"] as? String,
                lottie_url: nil, rive_url: nil, rive_state_machine: nil,
                video_url: nil, video_thumbnail_url: nil,
                cta_icon: nil, secondary_cta_icon: nil,
                haptic: nil, particle_effect: nil, blur_backdrop: nil
            )
            return MessageConfig(
                name: nil, message_type: .modal, content: fallbackContent,
                trigger_rules: nil, priority: nil, start_date: nil, end_date: nil
            )
        }
    }

    /// Present the SwiftUI `MessageRenderer` view for this delivery.
    /// Mirrors the present-on-top-VC pattern from `MessageManager.present`
    /// so journey-delivered messages get identical UX to config-driven
    /// ones (no UIAlertController fallback, no missing styling, no
    /// missing rich-media fields).
    private static func presentOnTopViewController(
        tracker: EventTracker?,
        messageId: String,
        config: MessageConfig,
        onShown: @escaping (Bool) -> Void,
        onClosed: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                Log.warning("PendingMessageListener: no root view controller — cannot present \(messageId) yet")
                onShown(false)
                return
            }
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }

            let view = MessageRenderer(
                messageId: messageId,
                config: config,
                onCTATap: {
                    tracker?.track(event: "in_app_message_clicked", properties: [
                        "delivery_id": messageId,
                        "cta_action": config.content?.cta_action?.type?.rawValue ?? "dismiss",
                        "source": "pending_messages",
                    ])
                    handleCTAAction(config.content?.cta_action)
                    topVC.dismiss(animated: true) { onClosed() }
                },
                onDismiss: {
                    tracker?.track(event: "in_app_message_dismissed", properties: [
                        "delivery_id": messageId,
                        "source": "pending_messages",
                    ])
                    topVC.dismiss(animated: true) { onClosed() }
                }
            )

            let hostingVC = MessageHosting.makeHost(rootView: view, config: config)
            topVC.present(hostingVC, animated: true) { onShown(true) }
        }
    }

    private static func handleCTAAction(_ action: CTAAction?) {
        // dismiss / unknown / a link type with no link: nothing extra (the caller dismisses).
        // Config-driven URL — scheme-checked before it reaches the OS.
        guard let urlString = action?.linkToOpen, let url = URLSafety.sanitized(urlString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}
