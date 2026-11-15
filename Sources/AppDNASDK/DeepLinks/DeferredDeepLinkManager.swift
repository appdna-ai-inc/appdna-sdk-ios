import Foundation
import FirebaseFirestore
import UIKit

/// A resolved deferred deep link.
public struct DeferredDeepLink {
    public let screen: String            // e.g., "/workout/123"
    public let params: [String: String]  // Additional context
    public let visitorId: String

    /// Convert to dictionary for Flutter/RN bridging.
    public func toMap() -> [String: Any] {
        return [
            "screen": screen,
            "params": params,
            "visitorId": visitorId,
        ]
    }
}

/// Checks for and resolves deferred deep links on first app launch.
/// Path: /orgs/{orgId}/apps/{appId}/config/deferred_deep_links/{visitorId}
final class DeferredDeepLinkManager {
    private let orgId: String
    private let appId: String
    private weak var eventTracker: EventTracker?

    private static let firstLaunchKey = "ai.appdna.sdk.first_launch_completed"
    private static let expiryHours: TimeInterval = 72

    /// Failed attempts so far, so a transport error does not spend the one chance.
    private static let failedAttemptsKey = "ai.appdna.sdk.ddl_failed_attempts"

    /// 🔴 A TRANSPORT FAILURE IS NOT AN ANSWER. `markLaunched()` used to run on every path out of
    /// the fetch, error included — so a user who installed from a link and opened the app with no
    /// network (a lift, a plane, a carrier handover, or simply before Firestore's first connection
    /// completed) lost the destination and the referrer PERMANENTLY, and silently: the host got
    /// `nil`, which is indistinguishable from "this install did not come from a link".
    ///
    /// The chance survives a failure now, bounded so a permanently offline device does not read
    /// Firestore on every launch for the life of the install. A SUCCESSFUL read — document present,
    /// or genuinely absent — is still an answer and still spends it.
    ///
    /// Four, not one: the link expires after `expiryHours` anyway, so the attempts only need to
    /// cover the launches a user plausibly makes inside three days while something is wrong with
    /// their connection.
    static let maxFailedAttempts = 4

    /// Where the visitor id copied by the web page is read from: the system pasteboard. Reading
    /// `UIPasteboard.general.string` is synchronous, and when the pasteboard holds another app's text iOS
    /// asks the user for permission first and blocks the calling thread until they answer, which in a
    /// test process (no one to answer) is forever. A test passes its own source.
    private let pasteboard: PasteboardReading

    init(orgId: String, appId: String, eventTracker: EventTracker?, pasteboard: PasteboardReading = SystemPasteboard()) {
        self.orgId = orgId
        self.appId = appId
        self.eventTracker = eventTracker
        self.pasteboard = pasteboard
    }

    /// Check for a deferred deep link. Should be called after configure() on first launch.
    func checkDeferredDeepLink(completion: @escaping (DeferredDeepLink?) -> Void) {
        // Only check on first launch
        guard isFirstLaunch() else {
            completion(nil)
            return
        }

        // The pasteboard probe answers asynchronously (iOS's pattern detection takes a completion
        // handler), and the read it may lead to must never run on the main thread.
        // `self` is held STRONGLY until the probe answers: the check is one short hop, and a weak
        // capture let a manager nobody else retained vanish mid-check and skip the bookkeeping.
        resolveVisitorId { visitorId in
            guard let visitorId else {
                Log.debug("DeferredDeepLink: no visitor ID resolved")
                self.markLaunched()
                completion(nil)
                return
            }
            self.fetchDeferredContext(visitorId: visitorId, completion: completion)
        }
    }

    private func fetchDeferredContext(visitorId: String, completion: @escaping (DeferredDeepLink?) -> Void) {
        // Check Firestore for deferred context
        // Path: config/deferred_deep_links = document, {visitorId} = subcollection doc
        let path = "orgs/\(orgId)/apps/\(appId)/config/deferred_deep_links/visitors/\(visitorId)"
        Log.debug("DeferredDeepLink: checking \(path)")

        // 🔴 NOT an answer either: without a Firestore handle nothing was asked.
        guard let db = AppDNA.firestoreDB else {
            recordFailedAttempt(reason: "Firestore is not available")
            completion(nil)
            return
        }
        db.document(path).getDocument { [weak self] snapshot, error in
            guard let self else {
                completion(nil)
                return
            }

            // The fetch never reached the server: keep the chance for the next launch.
            if let error {
                self.recordFailedAttempt(reason: error.localizedDescription)
                completion(nil)
                return
            }

            // From here the server answered, so the chance is spent whatever it said.
            self.markLaunched()

            guard let data = snapshot?.data() else {
                completion(nil)
                return
            }

            // Check expiry
            if let createdAt = data["created_at"] as? TimeInterval {
                let age = Date().timeIntervalSince1970 - createdAt
                if age > Self.expiryHours * 3600 {
                    Log.debug("DeferredDeepLink: expired (age: \(age / 3600)h)")
                    snapshot?.reference.delete()
                    completion(nil)
                    return
                }
            }

            let deepLink = DeferredDeepLink(
                screen: data["screen"] as? String ?? "",
                params: data["params"] as? [String: String] ?? [:],
                visitorId: visitorId
            )

            // Delete after resolving (one-time use)
            snapshot?.reference.delete()

            // Track event
            self.eventTracker?.track(event: "deferred_deep_link_resolved", properties: [
                "path": deepLink.screen,
                "params": deepLink.params,
                "visitor_id": visitorId,
            ])

            // Auto-show server-driven screen from deep link
            if let screenId = data["screen_id"] as? String, !screenId.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppDNA.showScreen(screenId)
                }
            }

            completion(deepLink)
        }
    }

    // MARK: - Visitor ID resolution

    private func resolveVisitorId(completion: @escaping (String?) -> Void) {
        // Strategy 1: the pasteboard (set by the web page before the store redirect) — read only when
        // iOS can tell, WITHOUT asking the user, that it holds a web link.
        checkPasteboard { pasteboardId in
            if let pasteboardId {
                completion(pasteboardId)
                return
            }
            // Strategy 2: Check URL scheme launch params
            if let launchId = self.checkLaunchParams() {
                completion(launchId)
                return
            }
            // Strategy 3: Use IDFV as fallback fingerprint
            completion(UIDevice.current.identifierForVendor?.uuidString.lowercased())
        }
    }

    /**
     🔴 READ THE PASTEBOARD ONLY WHEN IT HOLDS A LINK — and never on the main thread.

     This read `UIPasteboard.general.string` on every first launch to look for the visitor id a web
     page may have copied before the App Store redirect. Reading another app's content makes iOS 16+
     show "<App> would like to paste from <other app>" and BLOCKS the reading thread until the user
     answers — so every first launch of every host app whose user had copied anything anywhere showed
     a paste-permission alert, for a feature almost no install uses.

     The order now is: `hasStrings` (no prompt) → `detectPatterns(for: [.probableWebURL])` (no
     prompt) → the read, only when both say yes → `DeferredLinkPasteboard.visitorId(from:)`, which
     accepts only our own marker. Arbitrary text never reaches the read. A copied web link still can
     — iOS cannot tell OUR link from any other without reading it — and that read happens on a
     background queue, never the main thread.
     */
    private func checkPasteboard(completion: @escaping (String?) -> Void) {
        let pasteboard = self.pasteboard
        let finish: (String?) -> Void = { id in
            DeferredLinkPasteboard.workQueue.async { completion(id) }
        }
        guard pasteboard.hasStrings else {
            finish(nil)
            return
        }
        pasteboard.detectProbableWebURL { isProbableURL in
            DeferredLinkPasteboard.workQueue.async {
                guard DeferredLinkPasteboard.shouldRead(hasStrings: true, probableWebURL: isProbableURL) else {
                    Log.debug("DeferredDeepLink: pasteboard holds no link — not read, so iOS asks the user nothing")
                    completion(nil)
                    return
                }
                guard let visitorId = DeferredLinkPasteboard.visitorId(from: pasteboard.string) else {
                    completion(nil)
                    return
                }
                // Clear only OUR marker: someone else's link is left exactly where they put it.
                pasteboard.clear()
                Log.debug("DeferredDeepLink: resolved visitor ID from pasteboard")
                completion(visitorId)
            }
        }
    }

    private func checkLaunchParams() -> String? {
        // Check if the app was launched with a URL scheme containing visitor_id
        // This would be set via a custom URL scheme redirect
        return nil // Handled at the app level, not here
    }

    // MARK: - First launch tracking

    private func isFirstLaunch() -> Bool {
        !UserDefaults.standard.bool(forKey: Self.firstLaunchKey)
    }

    private func markLaunched() {
        UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
        UserDefaults.standard.removeObject(forKey: Self.failedAttemptsKey)
    }

    /// Count a check that never got an answer, and give up once it has happened `maxFailedAttempts`
    /// times — at which point the chance IS spent, so the SDK stops asking.
    private func recordFailedAttempt(reason: String) {
        let attempts = UserDefaults.standard.integer(forKey: Self.failedAttemptsKey) + 1
        if attempts >= Self.maxFailedAttempts {
            Log.warning(
                "DeferredDeepLink: giving up after \(attempts) failed attempts (\(reason)) — "
                    + "no deferred link will be resolved for this install"
            )
            markLaunched()
            return
        }
        UserDefaults.standard.set(attempts, forKey: Self.failedAttemptsKey)
        Log.debug("DeferredDeepLink: attempt \(attempts) of \(Self.maxFailedAttempts) failed (\(reason)) — will retry next launch")
    }
}

/// The pasteboard the deferred deep link reads its visitor id from.
///
/// `hasStrings` and `detectProbableWebURL` are the two questions iOS answers WITHOUT a paste prompt;
/// `string` is the one that prompts when another app put the content there.
protocol PasteboardReading {
    var hasStrings: Bool { get }
    func detectProbableWebURL(completion: @escaping (Bool) -> Void)
    var string: String? { get }
    func clear()
}

/// The system pasteboard.
struct SystemPasteboard: PasteboardReading {
    var hasStrings: Bool { UIPasteboard.general.hasStrings }

    func detectProbableWebURL(completion: @escaping (Bool) -> Void) {
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            switch result {
            case .success(let patterns): completion(patterns.contains(.probableWebURL))
            case .failure: completion(false)
            }
        }
    }

    var string: String? { UIPasteboard.general.string }
    func clear() { UIPasteboard.general.string = "" }
}

/**
 WHETHER the deferred deep link may read the pasteboard, and what it accepts from it.

 Pure, so the rule is pinned by the shared `deferred_link_pasteboard` fixture on both platforms.

 - The read happens only when the pasteboard holds text AND the system classifies it as a web link
   without reading it (`detectPatterns` on iOS, `ClipDescription` classification on Android 12+).
 - Accepted content: a URL carrying an `appdna_visitor` query item (the same key the Android Install
   Referrer carries), or the legacy `appdna:visitor:<id>` marker. Anything else is someone else's
   and is neither used nor cleared.
 */
enum DeferredLinkPasteboard {
    static let legacyPrefix = "appdna:visitor:"
    static let queryItem = "appdna_visitor"

    /// Where the probe's continuation and the read run: never the main thread.
    static let workQueue = DispatchQueue(label: "ai.appdna.sdk.ddl-pasteboard", qos: .utility)

    static func shouldRead(hasStrings: Bool, probableWebURL: Bool) -> Bool {
        hasStrings && probableWebURL
    }

    static func visitorId(from text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix(legacyPrefix) {
            let id = String(raw.dropFirst(legacyPrefix.count))
            return isVisitorIdShaped(id) ? id : nil
        }
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let id = comps.queryItems?.first(where: { $0.name == queryItem })?.value,
              isVisitorIdShaped(id) else { return nil }
        return id
    }

    /// A visitor id is an opaque token: letters, digits, `-` and `_`, 1–128 characters. Anything
    /// else is not ours, and must not become a Firestore document path segment.
    static func isVisitorIdShaped(_ id: String) -> Bool {
        guard (1...128).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }
}
