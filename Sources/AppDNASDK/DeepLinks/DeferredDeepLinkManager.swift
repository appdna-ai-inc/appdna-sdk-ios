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
    init(orgId: String, appId: String, eventTracker: EventTracker?) {
        self.orgId = orgId
        self.appId = appId
        self.eventTracker = eventTracker
    }

    /// Check for a deferred deep link. Should be called after configure() on first launch.
    func checkDeferredDeepLink(completion: @escaping (DeferredDeepLink?) -> Void) {
        // Only check on first launch
        guard isFirstLaunch() else {
            completion(nil)
            return
        }

        // Get visitor ID
        guard let visitorId = resolveVisitorId() else {
            Log.debug("DeferredDeepLink: no visitor ID resolved")
            markLaunched()
            completion(nil)
            return
        }

        // Check Firestore for deferred context
        // Path: config/deferred_deep_links = document, {visitorId} = subcollection doc
        let path = "orgs/\(orgId)/apps/\(appId)/config/deferred_deep_links/visitors/\(visitorId)"
        Log.debug("DeferredDeepLink: checking \(path)")

        guard let db = AppDNA.firestoreDB else { completion(nil); return }
        db.document(path).getDocument { [weak self] snapshot, error in
            guard let self else {
                completion(nil)
                return
            }

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

    private func resolveVisitorId() -> String? {
        // Strategy 1: Check pasteboard for visitor ID (set by web page before store redirect)
        if let pasteboardId = checkPasteboard() {
            return pasteboardId
        }

        // Strategy 2: Check URL scheme launch params
        if let launchId = checkLaunchParams() {
            return launchId
        }

        // Strategy 3: Use IDFV as fallback fingerprint
        return UIDevice.current.identifierForVendor?.uuidString.lowercased()
    }

    private func checkPasteboard() -> String? {
        // Web pages can copy a visitor ID to pasteboard before redirecting to App Store.
        // Format: "appdna:visitor:{uuid}"
        guard let content = UIPasteboard.general.string,
              content.hasPrefix("appdna:visitor:") else {
            return nil
        }
        let visitorId = String(content.dropFirst("appdna:visitor:".count))
        // Clear the pasteboard after reading
        UIPasteboard.general.string = ""
        Log.debug("DeferredDeepLink: resolved visitor ID from pasteboard")
        return visitorId
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
    }
}
