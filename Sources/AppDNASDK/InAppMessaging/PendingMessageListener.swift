import Foundation
import FirebaseFirestore
import UIKit
import SwiftUI

/// Listens for journey-triggered in-app messages at
/// `orgs/{orgId}/apps/{appId}/users/{userId}/pending_messages` and
/// renders them through the same `MessageRenderer` pipeline used for
/// remote-config-driven messages, so a journey-delivered modal /
/// fullscreen / banner / tooltip looks identical to one configured in
/// the console. Writes `consumed: true` back to Firestore after display
/// so repeat polls / the REST fallback don't double-deliver.
final class PendingMessageListener {
    private var listener: ListenerRegistration?
    private weak var eventTracker: EventTracker?
    private var isPresenting = false

    init(eventTracker: EventTracker?) {
        self.eventTracker = eventTracker
    }

    /// Begin observing the per-user pending_messages subcollection.
    /// Called from `AppDNA.identify(userId:traits:)`. Tears down any
    /// previous listener first so rapid re-identify doesn't leak.
    func startObserving(orgId: String, appId: String, userId: String) {
        stopObserving()

        guard let db = AppDNA.firestoreDB else {
            Log.debug("PendingMessageListener: Firestore not configured — skipping")
            return
        }

        let ref = db
            .collection("orgs").document(orgId)
            .collection("apps").document(appId)
            .collection("users").document(userId)
            .collection("pending_messages")
            .whereField("consumed", isEqualTo: false)

        Log.debug("PendingMessageListener: observing orgs/\(orgId)/apps/\(appId)/users/\(userId)/pending_messages")

        listener = ref.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                Log.error("PendingMessageListener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            let now = Date()
            for change in snapshot.documentChanges where change.type == .added {
                let doc = change.document
                self.handleIncoming(doc: doc, now: now)
            }
        }
    }

    /// Tear down listener. Called from `AppDNA.reset()` and on sign-out.
    func stopObserving() {
        listener?.remove()
        listener = nil
    }

    deinit { stopObserving() }

    // MARK: - Private

    private func handleIncoming(doc: QueryDocumentSnapshot, now: Date) {
        let data = doc.data()

        // Server-side expiry filter (TTL): Firestore lacks compound
        // `expires_at > now AND consumed == false` without a composite
        // index, so we filter locally.
        if let expiresMs = data["expires_at_ms"] as? Double {
            let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
            if expiresAt < now {
                Log.debug("PendingMessageListener: skipping expired \(doc.documentID)")
                return
            }
        }

        guard let content = data["content"] as? [String: Any] else {
            Log.debug("PendingMessageListener: \(doc.documentID) missing content — skipping")
            return
        }

        // Decode the delivered Firestore content into the same Codable
        // `MessageConfig` shape used by the remote-config pipeline so we
        // can route through the existing `MessageRenderer` views (modal,
        // fullscreen, banner, tooltip) with full styling + rich-media
        // support — instead of falling back to a plain UIAlertController.
        let config = decodeMessageConfig(content: content, root: data)

        eventTracker?.track(event: "in_app_message_received", properties: [
            "delivery_id": doc.documentID,
            "trigger": (data["trigger"] as? String) ?? "journey",
            "source": "pending_messages",
        ])

        present(messageId: doc.documentID, config: config) { [weak self] rendered in
            if rendered {
                doc.reference.updateData(["consumed": true]) { err in
                    if let err {
                        Log.warning("PendingMessageListener: failed to mark consumed: \(err.localizedDescription)")
                    }
                }
                self?.eventTracker?.track(event: "in_app_message_shown", properties: [
                    "delivery_id": doc.documentID,
                    "source": "pending_messages",
                    "message_type": config.message_type?.rawValue ?? "modal",
                ])
            }
        }
    }

    /// Best-effort decode of the delivered content into `MessageConfig`.
    /// Server payload mirrors the InAppMessageTrigger schema, so a
    /// JSONSerialization roundtrip + JSONDecoder works cleanly. On
    /// failure (corrupt or malformed payload) we synthesize a minimal
    /// modal config with whatever string fields we can salvage.
    private func decodeMessageConfig(content: [String: Any], root: [String: Any]) -> MessageConfig {
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
    private func present(
        messageId: String,
        config: MessageConfig,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(false); return }
            guard !self.isPresenting else {
                Log.debug("PendingMessageListener: another message presenting — deferring \(messageId)")
                completion(false)
                return
            }
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                Log.warning("PendingMessageListener: no root view controller — cannot present \(messageId)")
                completion(false)
                return
            }
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }

            self.isPresenting = true

            let view = MessageRenderer(
                messageId: messageId,
                config: config,
                onCTATap: { [weak self] in
                    self?.eventTracker?.track(event: "in_app_message_clicked", properties: [
                        "delivery_id": messageId,
                        "cta_action": config.content?.cta_action?.type?.rawValue ?? "dismiss",
                        "source": "pending_messages",
                    ])
                    self?.handleCTAAction(config.content?.cta_action)
                    topVC.dismiss(animated: true) {
                        self?.isPresenting = false
                    }
                },
                onDismiss: { [weak self] in
                    self?.eventTracker?.track(event: "in_app_message_dismissed", properties: [
                        "delivery_id": messageId,
                        "source": "pending_messages",
                    ])
                    topVC.dismiss(animated: true) {
                        self?.isPresenting = false
                    }
                }
            )

            let hostingVC = UIHostingController(rootView: view)
            hostingVC.modalPresentationStyle = config.message_type == .fullscreen
                ? .fullScreen : .overCurrentContext
            hostingVC.modalTransitionStyle = .crossDissolve
            hostingVC.view.backgroundColor = .clear
            topVC.present(hostingVC, animated: true) { completion(true) }
        }
    }

    private func handleCTAAction(_ action: CTAAction?) {
        guard let action, let actionType = action.type else { return }
        switch actionType {
        case .dismiss, .unknown:
            break // dismiss handled by caller
        case .deep_link, .open_url:
            // Config-driven URL — scheme-checked before it reaches the OS.
            if let urlString = action.url, let url = URLSafety.sanitized(urlString) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
