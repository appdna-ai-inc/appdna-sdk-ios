import Foundation
import CommonCrypto
import UIKit
import UserNotifications

/// Manages push token capture, Keychain storage, backend registration, and delivery tracking.
final class PushTokenManager {
    private let keychainStore: KeychainStore
    private weak var eventTracker: EventTracker?
    private weak var apiClient: APIClient?

    private static let keychainKey = "push_token"
    private let lastTokenLock = NSLock()
    private var lastToken: String?

    private static let osVersionString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// The current push token string (hex-encoded), read from Keychain.
    var currentTokenString: String? {
        keychainStore.getString(key: Self.keychainKey)
    }

    /// Who the token belongs to, read at send time: the device's anonymous id and, once `identify` ran,
    /// the host's user id. Without them the server stored every token as user `anonymous`, so a push to
    /// a user, a list or a segment found no token for an SDK device.
    private let identity: () -> (anonId: String?, userId: String?)
    /// Sends one registration body. The API client by default; a test passes a recorder.
    private let send: ([String: Any]) async throws -> Void

    init(keychainStore: KeychainStore, eventTracker: EventTracker?, apiClient: APIClient? = nil,
         identity: @escaping () -> (anonId: String?, userId: String?) = { (nil, nil) },
         send: (([String: Any]) async throws -> Void)? = nil) {
        self.keychainStore = keychainStore
        self.eventTracker = eventTracker
        self.apiClient = apiClient
        self.identity = identity
        if let send {
            self.send = send
        } else {
            self.send = { [weak apiClient] body in
                let _: EmptyResponse = try await apiClient?.request(.registerPushToken(body: body)) ?? EmptyResponse()
            }
        }
    }

    /// Registers the stored token again, with the identity as it is NOW. `identify` and `reset` call
    /// this, so the server's row follows the user who is signed in. No stored token, nothing sent.
    func reregister() {
        // The token this process registered, else the stored one: the Keychain can refuse a write (a
        // host without the entitlement, a locked device), and a token the SDK already holds must not be
        // lost to that.
        lastTokenLock.lock(); let held = lastToken; lastTokenLock.unlock()
        guard let token = held ?? currentTokenString, !token.isEmpty else { return }
        registerTokenWithBackend(token)
    }

    /// Store the push token, send a registration event, and register with backend.
    /// - Parameter token: The raw APNS token data from `didRegisterForRemoteNotificationsWithDeviceToken`.
    func setPushToken(_ token: Data) {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        let previousToken = keychainStore.getString(key: Self.keychainKey)

        lastTokenLock.lock(); lastToken = tokenString; lastTokenLock.unlock()
        // Store in Keychain (not UserDefaults — sensitive data)
        keychainStore.setString(key: Self.keychainKey, value: tokenString)

        // Only send event if token is new or changed
        if tokenString != previousToken {
            let hashedToken = sha256(tokenString)
            eventTracker?.track(event: "push_token_registered", properties: [
                "token_hash": hashedToken,
                "platform": "ios",
            ])
            Log.info("Push token registered (hash: \(hashedToken.prefix(12))...)")
            // Fire onPushTokenRegistered to the host's
            // AppDNAPushDelegate. Token registration with the backend
            // continues regardless of whether the host has a delegate.
            DispatchQueue.main.async {
                AppDNA.pushDelegate?.onPushTokenRegistered(token: tokenString)
            }
        }

        // Register token with backend (POST /api/v1/push/token)
        registerTokenWithBackend(tokenString)
    }

    /// Track push permission status.
    /// - Parameter granted: Whether the user granted push notification permission.
    func setPushPermission(granted: Bool) {
        if granted {
            eventTracker?.track(event: "push_permission_granted", properties: [:])
        } else {
            eventTracker?.track(event: "push_permission_denied", properties: [:])
        }
        Log.info("Push permission: \(granted ? "granted" : "denied")")
    }

    /// Track that a push notification was delivered (called from notification extension or foreground handler).
    func trackDelivered(pushId: String) {
        trackDelivered(pushId: pushId, deliveryId: nil)
    }

    /// The delivered call with the per-token `delivery_id` the server stamps on every
    /// AppDNA push. The id rides in both the `push_delivered` event and the `/push/delivered` body, so
    /// the server can move exactly this delivery row (the push id alone only increments counters).
    func trackDelivered(pushId: String, deliveryId: String?) {
        var props: [String: String] = ["push_id": pushId]
        var body: [String: Any] = ["push_id": pushId]
        if let deliveryId, !deliveryId.isEmpty {
            props["delivery_id"] = deliveryId
            body["delivery_id"] = deliveryId
        }
        eventTracker?.track(event: "push_delivered", properties: props)

        Task {
            do {
                let _: EmptyResponse = try await apiClient?.request(.pushDelivered(body: body)) ?? EmptyResponse()
            } catch {
                Log.warning("Failed to track push delivered: \(error)")
            }
        }
    }

    /// Track that a push notification was tapped.
    func trackTapped(pushId: String, action: String? = nil) {
        trackTapped(pushId: pushId, action: action, deliveryId: nil)
    }

    /// The tapped call with `delivery_id`, sent in both the `push_tapped` event and the
    /// `/push/tapped` body.
    func trackTapped(pushId: String, action: String?, deliveryId: String?) {
        var props: [String: String] = ["push_id": pushId]
        if let action = action { props["action"] = action }
        var body: [String: Any] = ["push_id": pushId]
        if let deliveryId, !deliveryId.isEmpty {
            props["delivery_id"] = deliveryId
            body["delivery_id"] = deliveryId
        }
        eventTracker?.track(event: "push_tapped", properties: props)

        Task {
            do {
                let _: EmptyResponse = try await apiClient?.request(.pushTapped(body: body)) ?? EmptyResponse()
            } catch {
                Log.warning("Failed to track push tapped: \(error)")
            }
        }
    }

    /// Track that a push notification was DISMISSED — swiped away without being opened.
    ///
    /// The only negative signal a push campaign has, and this platform could not emit it:
    /// iOS reports a dismissal solely for a category registered with `.customDismissAction`, which
    /// `PushActionCategories` now sets. Android has emitted it from a delete intent all along, so a
    /// funnel built on this event measured one platform and read as zero dismissals on the other.
    ///
    /// Properties match Android's exactly (`push_id`, and `delivery_id` when present) so one query
    /// reads both. No `/push/...` call is made: unlike delivered and tapped there is no server
    /// endpoint for a dismissal, and inventing one here would fail silently against production.
    func trackDismissed(pushId: String, deliveryId: String?) {
        var props: [String: String] = ["push_id": pushId]
        if let deliveryId, !deliveryId.isEmpty {
            props["delivery_id"] = deliveryId
        }
        eventTracker?.track(event: "push_dismissed", properties: props)
    }

    // MARK: - Public: Permission Request

    /// Request push notification permission from the user.
    /// Returns `true` if the user granted permission, `false` otherwise.
    public func requestPermission() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            setPushPermission(granted: granted)
            return granted
        } catch {
            Log.error("Failed to request push permission: \(error)")
            return false
        }
    }

    // MARK: - Private

    private func registerTokenWithBackend(_ tokenString: String) {
        Task {
            do {
                let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? "" }
                let who = identity()
                let body = PushTokenRegistration.body(
                    token: tokenString, platform: "ios", deviceId: deviceId,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                    sdkVersion: AppDNA.sdkVersion, osVersion: Self.osVersionString,
                    anonId: who.anonId, userId: who.userId)
                try await send(body)
                Log.info("Push token registered with backend")
            } catch {
                Log.warning("Failed to register push token with backend: \(error)")
            }
        }
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// The body of `POST /api/v1/push/token`. Shared with Android and driven by the
/// `push_token_registration_body` fixture: `anon_id` and `user_id` ride along when known (an empty
/// string is not an id), so the server stores who the token belongs to.
enum PushTokenRegistration {
    static func body(token: String, platform: String, deviceId: String, appVersion: String,
                     sdkVersion: String, osVersion: String, anonId: String?, userId: String?) -> [String: Any] {
        var body: [String: Any] = [
            "token": token,
            "platform": platform,
            "device_id": deviceId,
            "app_version": appVersion,
            "sdk_version": sdkVersion,
            "os_version": osVersion,
        ]
        if let anonId, !anonId.isEmpty { body["anon_id"] = anonId }
        if let userId, !userId.isEmpty { body["user_id"] = userId }
        return body
    }
}

/// Empty Codable response for fire-and-forget requests.
private struct EmptyResponse: Codable {}
