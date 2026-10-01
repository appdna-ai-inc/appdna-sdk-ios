import Foundation
import UIKit
import UserNotifications

// The push action-button categories, in the extension-safe `AppDNANotificationExtension` module: a
// Notification Service Extension links this module alone (no `UIApplication.shared`, no Firebase), and
// AppDNASDK depends on it (SwiftPM) or compiles it into its own module (CocoaPods), so the extension and
// the app register categories through the SAME code.

// MARK: - The notification-centre seam

/// Get/set the notification-centre delegate and its categories. Production wraps
/// `UNUserNotificationCenter.current()`; hostless tests inject an in-memory slot, because
/// `UNUserNotificationCenter.current()` raises "bundleProxyForCurrentProcess is nil" there.
@_spi(AppDNAInternal) public protocol NotificationCenterSlot: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void)
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// The category ids of the notifications still in Notification Centre (category pruning keeps them).
    func deliveredCategoryIds(_ completion: @escaping (Set<String>) -> Void)
    /// The ONLY route by which the SDK may post a notification itself. iOS never does from a received
    /// push (the OS or the host presents; `handleMessageData` never displays — SPEC-497 §8.7), so
    /// nothing calls it today; the push fixtures read `notification_posted` from this slot instead of
    /// asserting a constant.
    func add(_ request: UNNotificationRequest)
}

@_spi(AppDNAInternal) public final class SystemNotificationCenterSlot: NotificationCenterSlot {
    public init() {}
    public var delegate: UNUserNotificationCenterDelegate? {
        get { UNUserNotificationCenter.current().delegate }
        set { UNUserNotificationCenter.current().delegate = newValue }
    }
    public func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) {
        UNUserNotificationCenter.current().getNotificationCategories(completionHandler: completion)
    }
    public func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    public func deliveredCategoryIds(_ completion: @escaping (Set<String>) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            completion(Set(notifications.map { $0.request.content.categoryIdentifier }.filter { !$0.isEmpty }))
        }
    }
    public func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Action categories

/// SPEC-084 / SPEC-497 §17 item 28 — registers the push's action buttons as a notification category.
/// iOS shows buttons only for a category registered BEFORE the notification is displayed, so the server
/// sends every distinct button set under its own id (`aps.category` = `appdna_` + a hash of the set) and
/// the SDK registers it:
///   - in the Notification Service Extension (`NotificationService`), on receipt, before display —
///     the only point that works for the FIRST push with a new button set while the app is not running;
///   - when the app sees the push (foreground delivery, a tap) and at `configure` from the notifications
///     still in Notification Centre, so a later push with the same set shows its buttons without the
///     extension.
/// Goes through a `NotificationCenterSlot` (SPEC-497 §9a.8) so it never touches
/// `UNUserNotificationCenter.current()` in a hostless test, where that call raises.
@_spi(AppDNAInternal) public enum PushActionCategories {
    /// The category id a payload's buttons register under: `aps.category`, else a top-level `category`,
    /// else `appdna_default`.
    public static func categoryId(from userInfo: [AnyHashable: Any]) -> String {
        if let aps = userInfo["aps"] as? [String: Any], let id = aps["category"] as? String, !id.isEmpty { return id }
        if let id = userInfo["category"] as? String, !id.isEmpty { return id }
        return "appdna_default"
    }

    /// The category for the payload's buttons, or nil when it has none. Buttons are the server's SDK shape
    /// `{id, label, action_type, action_value?, foreground}`: `foreground` → `.foreground`; `dismiss` →
    /// `.destructive` alone (never `.foreground`, so it never opens the app); `text_reply` → a text-input action whose placeholder is `action_value`.
    public static func category(from userInfo: [AnyHashable: Any]) -> UNNotificationCategory? {
        guard let actionsData = userInfo["actions"] as? [[String: Any]], !actionsData.isEmpty else { return nil }

        let actions: [UNNotificationAction] = actionsData.compactMap { actionData in
            guard let id = actionData["id"] as? String,
                  let rawLabel = actionData["label"] as? String else { return nil }
            let label = buttonTitle(rawLabel)
            let type = actionData["action_type"] as? String
            let foreground = actionData["foreground"] as? Bool ?? false
            // A `dismiss` button never opens the app, whatever `foreground` says (an older server or a
            // journey could send `foreground: true` with it): `.destructive` only.
            let options: UNNotificationActionOptions = type == "dismiss"
                ? [.destructive]
                : (foreground ? [.foreground] : [])

            if type == "text_reply" {
                let placeholder = actionData["action_value"] as? String ?? ""
                return UNTextInputNotificationAction(
                    identifier: id, title: label, options: options,
                    textInputButtonTitle: label, textInputPlaceholder: placeholder
                )
            }

            // SPEC-085: Action button icon support (iOS 15+)
            if #available(iOS 15.0, *) {
                if let iconData = actionData["icon"] as? [String: Any],
                   let iconLib = iconData["library"] as? String,
                   let iconName = iconData["name"] as? String {
                    let sfSymbolName: String
                    if iconLib == "sf-symbols" {
                        sfSymbolName = iconName
                    } else if iconLib == "lucide", let mapped = SFSymbolTables.lucide[iconName] {
                        sfSymbolName = mapped
                    } else if iconLib == "material", let mapped = SFSymbolTables.material[iconName] {
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
        guard !actions.isEmpty else { return nil }
        return UNNotificationCategory(
            identifier: categoryId(from: userInfo),
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }

    /// The title of a button in a registered category. A category is shared by every later push with the
    /// same button set, and it is registered by two processes — the Notification Service Extension
    /// (where the SDK is not configured: no user, no session, no remote config) and the app. Both must
    /// register the SAME titles, or a button's title changes depending on which process registered last.
    /// So the title is resolved with an empty template context in both: a `{{… | fallback}}` variable
    /// shows its fallback, any other variable an empty string. (The `actions` handed to the host in
    /// `PushPayload` are still interpolated with the app's context.)
    public static func buttonTitle(_ rawLabel: String) -> String {
        // `TemplateEngine.interpolate` with an empty context, which the extension cannot link: the same
        // pattern, every variable unresolved. A test pins the two against each other.
        guard rawLabel.contains("{{"), let regex = templateRegex else { return rawLabel }
        var result = rawLabel
        let matches = regex.matches(in: rawLabel, range: NSRange(rawLabel.startIndex..., in: rawLabel))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: rawLabel) else { continue }
            let fallback: String? = match.numberOfRanges > 2
                ? Range(match.range(at: 2), in: rawLabel).map { String(rawLabel[$0]).trimmingCharacters(in: .whitespaces) }
                : nil
            result = result.replacingCharacters(in: fullRange, with: fallback ?? "")
        }
        return result
    }

    /// `TemplateEngine`'s variable pattern: `{{path}}` or `{{path | fallback}}`.
    private static let templateRegex = try? NSRegularExpression(pattern: "\\{\\{([^}|]+)(?:\\|([^}]*))?\\}\\}")

    /// At most this many `appdna_*` categories stay registered. Every distinct button set is its own
    /// category, so without a cap the registered set only grows.
    public static let maxRegisteredCategories = 16

    /// Most recent first: the `appdna_*` category ids THIS process registered (the extension and the app
    /// each keep their own). Test seam: the defaults it is persisted in.
    public static var recencyDefaults: UserDefaults = .standard
    public static let recencyKey = "ai.appdna.push.category_recency"

    /// Registers the payload's category (replacing one with the same id; every other category — the
    /// host's own included — is kept). `completion` runs once the set has been handed to the centre.
    ///
    /// Each registration is a read (`getCategories`) followed by a write (`setCategories`) of the whole
    /// set, so two registrations that overlap both read the same set and the later write drops the
    /// earlier one's category.
    ///   - Within one process they are serialised (`RegistrationQueue`): a registration starts only after
    ///     the previous one has written.
    ///   - Across processes (the Notification Service Extension and the app) nothing can serialise them:
    ///     the SDK has no App Group, so there is no shared lock or file. Instead every write is merged
    ///     into what is registered at that moment and then re-checked: after writing, the registration
    ///     reads the set again and, if its category is gone (the other process wrote a set it had read
    ///     before this write), merges it into that newer set and writes again — up to
    ///     `maxReMergeAttempts` times.
    ///   - The race that remains: the other process writes a set it read BEFORE this registration's last
    ///     write, and that write lands AFTER this registration's last re-check. The category is then
    ///     missing until a process registers it again — the app does when it sees a push with those
    ///     buttons (foreground delivery, a tap) and at `configure` for the notifications still in
    ///     Notification Centre.
    ///
    /// Pruned: when more than `maxRegisteredCategories` `appdna_*` categories would be registered, the
    /// ones kept are the new one, those of notifications still in Notification Centre, and the most
    /// recently registered (`recencyKey`) up to the cap; the rest are removed. Categories without the
    /// `appdna_` prefix (the host's) are never touched.
    public static func register(
        from userInfo: [AnyHashable: Any],
        slot: NotificationCenterSlot?,
        completion: (() -> Void)? = nil
    ) {
        guard let slot, let category = category(from: userInfo) else { completion?(); return }
        RegistrationQueue.run { done in
            let recent = touchRecency(category.identifier)
            let finish = { completion?(); done() }
            // One merge-and-write of `category` into `existing`, then the re-check (see `register`).
            func write(into existing: Set<UNNotificationCategory>, attempt: Int) {
                var categories = existing.filter { $0.identifier != category.identifier }
                let commit: (Set<String>) -> Void = { delivered in
                    categories = prune(categories, newId: category.identifier, recent: recent, delivered: delivered)
                    categories.insert(category)
                    slot.setCategories(categories)
                    slot.getCategories { after in
                        if attempt < maxReMergeAttempts, !after.contains(where: { $0.identifier == category.identifier }) {
                            write(into: after, attempt: attempt + 1)
                        } else {
                            finish()
                        }
                    }
                }
                let ours = categories.filter { isOurs($0.identifier) }.count
                if ours + (isOurs(category.identifier) ? 1 : 0) > maxRegisteredCategories {
                    slot.deliveredCategoryIds(commit)
                } else {
                    commit([])
                }
            }
            slot.getCategories { existing in write(into: existing, attempt: 0) }
        }
    }

    /// How many times a registration re-merges its category after another process's write dropped it.
    public static let maxReMergeAttempts = 3

    public static func isOurs(_ identifier: String) -> Bool { identifier.hasPrefix("appdna_") }

    /// The `appdna_*` categories to keep beside the new one (see `register`). Pure.
    public static func prune(
        _ categories: Set<UNNotificationCategory>,
        newId: String,
        recent: [String],
        delivered: Set<String>
    ) -> Set<UNNotificationCategory> {
        let ours = categories.filter { isOurs($0.identifier) }
        let room = maxRegisteredCategories - (isOurs(newId) ? 1 : 0)
        guard ours.count > room else { return categories }
        var keep = Set(ours.map(\.identifier).filter { delivered.contains($0) })
        for id in recent where id != newId && keep.count < room && ours.contains(where: { $0.identifier == id }) {
            keep.insert(id)
        }
        return categories.filter { !isOurs($0.identifier) || keep.contains($0.identifier) }
    }

    /// Moves `id` to the front of this process's recency list and returns the list.
    private static func touchRecency(_ id: String) -> [String] {
        var list = recencyDefaults.stringArray(forKey: recencyKey) ?? []
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > maxRegisteredCategories * 2 { list = Array(list.prefix(maxRegisteredCategories * 2)) }
        recencyDefaults.set(list, forKey: recencyKey)
        return list
    }

    /// One registration at a time (see `register`). A job calls `done` once it has written; the next one
    /// starts then. Jobs whose slot answers synchronously (the in-memory test slot) run inline.
    enum RegistrationQueue {
        private static let lock = NSLock()
        private static var running = false
        private static var jobs: [(@escaping () -> Void) -> Void] = []

        static func run(_ job: @escaping (@escaping () -> Void) -> Void) {
            lock.lock()
            jobs.append(job)
            let start = !running
            if start { running = true }
            lock.unlock()
            if start { next() }
        }

        private static func next() {
            lock.lock()
            guard !jobs.isEmpty else { running = false; lock.unlock(); return }
            let job = jobs.removeFirst()
            lock.unlock()
            let doneLock = NSLock()
            var finished = false
            job {
                doneLock.lock()
                let first = !finished
                finished = true
                doneLock.unlock()
                if first { next() }
            }
        }
    }
}
