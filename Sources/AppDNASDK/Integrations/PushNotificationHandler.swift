import Foundation
import UserNotifications

/// Handles push notification display and tracking.
///
/// SPEC-497 B6: the SDK no longer relies on a host instantiating this class (nothing ever did — its
/// `init` is internal). The installed `AppDNANotificationCenterProxy` is the SDK's delegate now; this
/// class stays for source compatibility and forwards to the same `AppDNA.pushModule` entry points.
public class PushNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    private weak var eventTracker: EventTracker?
    private weak var pushTokenManager: PushTokenManager?

    init(eventTracker: EventTracker?, pushTokenManager: PushTokenManager?) {
        self.eventTracker = eventTracker
        self.pushTokenManager = pushTokenManager
        super.init()
    }

    /// Called when notification received in foreground
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        AppDNA.pushModule.handleMessageData(request.content.userInfo, inForeground: true, requestId: request.identifier)
        completionHandler([.banner, .badge, .sound])
    }

    /// Called when user taps notification
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        completionHandler()
        AppDNA.pushModule.handleNotificationTap(
            request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            requestId: request.identifier
        )
    }

    // SPEC-084: Register notification categories with action buttons
    func registerActionCategories(from userInfo: [AnyHashable: Any]) {
        PushActionCategories.register(from: userInfo, slot: NotificationProxyBootstrap.categorySlot())
    }

    private func buildPayload(from content: UNNotificationContent) -> PushPayload {
        PushPayloadParser.parse(userInfo: content.userInfo, title: content.title, body: content.body)
    }
}

// MARK: - Action categories

/// SPEC-084 — registers the push's action buttons as a notification category. Goes through a
/// `NotificationCenterSlot` (SPEC-497 §9a.8) so it never touches `UNUserNotificationCenter.current()`
/// in a hostless test, where that call raises.
enum PushActionCategories {
    static func register(from userInfo: [AnyHashable: Any], slot: NotificationCenterSlot?) {
        guard let slot else { return }
        guard let actionsData = userInfo["actions"] as? [[String: Any]], !actionsData.isEmpty else { return }
        let categoryId = userInfo["category"] as? String ?? "appdna_default"

        // SPEC-088: Interpolate action button labels
        let pushCtx = TemplateEngine.shared.buildContext()
        let actions: [UNNotificationAction] = actionsData.compactMap { actionData in
            guard let id = actionData["id"] as? String,
                  let rawLabel = actionData["label"] as? String else { return nil }
            let label = TemplateEngine.shared.interpolate(rawLabel, context: pushCtx)
            let foreground = actionData["foreground"] as? Bool ?? false
            let options: UNNotificationActionOptions = foreground ? [.foreground] : []

            // SPEC-085: Action button icon support (iOS 15+)
            if #available(iOS 15.0, *) {
                if let iconData = actionData["icon"] as? [String: Any],
                   let iconLib = iconData["library"] as? String,
                   let iconName = iconData["name"] as? String {
                    let sfSymbolName: String
                    if iconLib == "sf-symbols" {
                        sfSymbolName = iconName
                    } else if iconLib == "lucide", let mapped = IconMapping.lucideToSFSymbol[iconName] {
                        sfSymbolName = mapped
                    } else if iconLib == "material", let mapped = IconMapping.materialToSFSymbol[iconName] {
                        sfSymbolName = mapped
                    } else {
                        sfSymbolName = iconName
                    }
                    let icon = UNNotificationActionIcon(systemImageName: sfSymbolName)
                    return UNNotificationAction(identifier: id, title: label, options: options, icon: icon)
                }
            }
            return UNNotificationAction(identifier: id, title: label, options: options)
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        slot.getCategories { existing in
            var categories = existing
            categories.insert(category)
            slot.setCategories(categories)
        }
    }
}

// MARK: - Push payload parsing

/// Turns a raw APNs `userInfo` dictionary into the `PushPayload` handed to the host.
///
/// Extracted from `PushNotificationHandler.buildPayload` and stripped of its `UNNotificationContent`
/// dependency: the only two things it needed from the content are the title and body strings, and
/// `UNNotificationContent` cannot be constructed with a payload in a unit test — which is why the
/// `actions` array was shipped by the server, registered as buttons, and then silently dropped on the
/// way to the host without any test noticing.
enum PushPayloadParser {
    static func parse(userInfo: [AnyHashable: Any], title: String, body: String) -> PushPayload {
        let pushId = userInfo["push_id"] as? String ?? ""
        let imageUrl = userInfo["image_url"] as? String
        let data = userInfo["data"] as? [String: Any]

        // SPEC-088: Interpolate push title, body, and action button labels via TemplateEngine.
        let ctx = TemplateEngine.shared.buildContext()

        var actions: [PushAction] = []
        for entry in userInfo["actions"] as? [[String: Any]] ?? [] {
            guard let type = entry["action_type"] as? String else { continue }
            let rawLabel = entry["label"] as? String
            actions.append(PushAction(
                type: type,
                // "dismiss" and friends carry no target — an absent value is not a malformed button.
                value: entry["action_value"] as? String ?? "",
                id: entry["id"] as? String,
                label: rawLabel.map { TemplateEngine.shared.interpolate($0, context: ctx) }
            ))
        }

        // The notification-body tap action. Falls back to the first button so hosts reading the
        // pre-existing single `action` field keep working on payloads that only carry `actions`.
        var action: PushAction? = nil
        if let actionData = userInfo["action"] as? [String: String],
           let type = actionData["type"], let value = actionData["value"] {
            action = PushAction(type: type, value: value)
        }

        return PushPayload(
            pushId: pushId,
            title: TemplateEngine.shared.interpolate(title, context: ctx),
            body: TemplateEngine.shared.interpolate(body, context: ctx),
            imageUrl: imageUrl,
            data: data,
            action: action ?? actions.first,
            actions: actions
        )
    }
}

// MARK: - Push tap routing

/// Which built-in destination a push tap resolves to. Pure, so the routing table is assertable
/// without a `UNNotificationResponse` (which cannot be constructed in a unit test — which is exactly
/// how iOS shipped for months routing `show_screen` and silently dropping `deep_link`).
///
/// SPEC-497 §9.2: the same routing ladder as Android (see `PushTapRouter.route`). Android additionally
/// routes `show_paywall` / `show_survey` from a push — iOS does not (known gap, not closed here).
enum PushTapRoute: Equatable {
    case showScreen(String)
    case deepLink(String)
    /// No built-in destination (dismiss, a custom action the host owns, or no action at all).
    case ignored
}

enum PushTapRouter {
    /// SPEC-497 §8.7 — the route-sink test seam. Production leaves it nil. When set, the tap router
    /// reports `("show_screen", id)` / `("deep_link", url)` to it BEFORE `showScreen` / `handleURL`
    /// run, so a failure in the real navigation can never hide the decision from a test.
    static var routeSink: ((_ type: String, _ value: String) -> Void)?

    /// The routing ladder (SPEC-497 §9.2, the same one Android uses):
    ///   (0) a tapped BUTTON's own action (`tappedActionId` matches an entry of `actions`);
    ///   (1) the canonical body `action` `{type, value}`;
    ///   (2) flat `action_type` / `action_value`;
    ///   (3) `screen_id`;
    ///   (4) `deep_link`;
    ///   (5) iOS only, unchanged: the first button's action when the payload has no body action.
    /// Rungs (1)–(4) are read from the RAW `userInfo`, because `PushPayload.action` folds
    /// `action ?? actions.first` and so cannot tell a real body action from the rung-(5) fallback.
    /// The first rung that is present decides; iOS routes `show_screen` and `deep_link` / `open_url`
    /// only (Android also routes paywalls and surveys — a known gap, not closed here).
    static func route(payload: PushPayload, userInfo: [AnyHashable: Any], tappedActionId: String?) -> PushTapRoute {
        if let tappedActionId, let button = payload.actions.first(where: { $0.id == tappedActionId }) {
            return resolve(type: button.type, value: button.value)
        }
        if let canonical = canonicalAction(userInfo["action"]) {
            return resolve(type: canonical.type, value: canonical.value)
        }
        if let type = userInfo["action_type"] as? String, !type.isEmpty {
            return resolve(type: type, value: userInfo["action_value"] as? String ?? "")
        }
        if let screenId = userInfo["screen_id"] as? String, !screenId.isEmpty {
            return .showScreen(screenId)
        }
        if let deepLink = userInfo["deep_link"] as? String, !deepLink.isEmpty {
            return .deepLink(deepLink)
        }
        if let first = payload.action {
            return resolve(type: first.type, value: first.value)
        }
        return .ignored
    }

    /// `action` as a nested `{type, value}` object (APNs, and iOS wrappers pass it untouched) or, for
    /// robustness, as a JSON string of the same object.
    private static func canonicalAction(_ raw: Any?) -> (type: String, value: String)? {
        var dict = raw as? [String: Any]
        if dict == nil, let text = raw as? String, let data = text.data(using: .utf8) {
            dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let dict, let type = dict["type"] as? String, !type.isEmpty else { return nil }
        return (type, dict["value"] as? String ?? "")
    }

    private static func resolve(type: String, value: String) -> PushTapRoute {
        guard !value.isEmpty else { return .ignored }
        switch type {
        case "show_screen":
            return .showScreen(value)
        case "deep_link", "open_url":
            return .deepLink(value)
        default:
            return .ignored
        }
    }

    /// Performs a route after the 0.5 s settle delay (the app is foregrounded before the host is asked
    /// to navigate). The sink, when set, hears the decision first.
    static func perform(_ route: PushTapRoute) {
        switch route {
        case .showScreen(let screenId):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                routeSink?("show_screen", screenId)
                AppDNA.showScreen(screenId)
            }
        case .deepLink(let urlString):
            guard let url = URL(string: urlString) else {
                Log.warning("[Push] deep link action carried an unparseable URL: \(urlString)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                routeSink?("deep_link", urlString)
                AppDNA.deepLinks.handleURL(url)
            }
        case .ignored:
            break
        }
    }
}

/// Rolling 30-minute record of the last push_id received, so events emitted shortly after a push can
/// be attributed to it (`context.push_id`). Mirrors Android's `PushSessionContext`
/// (integrations/AppDNAMessagingService.kt): persisted in UserDefaults so it survives restart; the
/// window logic ages stale ids out so callers never clear it.
enum PushSessionContext {
    private static let keyLastId = "ai.appdna.sdk.push.last_push_id"
    private static let keyLastAt = "ai.appdna.sdk.push.last_push_at"
    private static let windowMs: Double = 30 * 60 * 1000

    static func recordPushReceived(_ pushId: String) {
        guard !pushId.isEmpty else { return }
        let d = UserDefaults.standard
        d.set(pushId, forKey: keyLastId)
        d.set(Date().timeIntervalSince1970 * 1000, forKey: keyLastAt)
    }

    /// The last push_id received within the rolling 30-minute window, or nil.
    static func currentPushId() -> String? {
        let d = UserDefaults.standard
        guard let pushId = d.string(forKey: keyLastId) else { return nil }
        let at = d.double(forKey: keyLastAt)
        if at == 0 { return nil }
        if Date().timeIntervalSince1970 * 1000 - at > windowMs { return nil }
        return pushId
    }
}
