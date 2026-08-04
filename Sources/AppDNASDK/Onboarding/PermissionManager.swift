import Foundation
import AVFoundation
import Photos
import Contacts
import CoreLocation
import EventKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// MARK: - Permission status

/// Coarse, cross-type permission status the onboarding permission pipeline routes on.
/// `.unavailable` means the request cannot be made safely (missing Info.plist usage
/// description, or an unsupported/unknown type) — it is NEVER routed to `.denied`.
public enum PermissionStatus: String, Equatable {
    case granted
    case denied
    case undetermined
    case unavailable
}

/// SPEC-421 — pure routing decision the renderer derives from a `PermissionStatus`.
/// Kept separate + pure so the status→action mapping is unit-testable without the OS.
public enum PermissionRouteDecision: String, Equatable {
    /// Already granted: emit `permission_already_granted`, store `granted`, advance (no prompt).
    case alreadyGranted
    /// Distinct iOS denied: emit `permission_denied`, store `denied`, optional settings fallback, advance.
    case denied
    /// Unavailable (missing key / unsupported): emit `permission_unavailable`, advance, store nothing.
    case unavailable
    /// Undetermined: emit `permission_prompted`, request the OS prompt, then store the result.
    case prompt
}

/// SPEC-421 — async, per-type runtime permission manager for onboarding permission steps.
///
/// Two responsibilities:
///  1. `status(_:)` — read the current authorization (async where the API requires it).
///     Applies the Info.plist crash-guard: a type whose usage-description key is ABSENT
///     returns `.unavailable` (we never touch the OS API → no TCC `SIGABRT`).
///  2. `request(_:)` — fire the real OS prompt and return whether it was granted.
///
/// The manager retains a `CLLocationManager` (+ delegate coordinator) because Core Location
/// only reports its result via the delegate — it has no async request API.
public final class PermissionManager {
    /// Retained for the lifetime of the manager so the delegate callback isn't lost. Location
    /// authorization is reported ONLY via `locationManagerDidChangeAuthorization`.
    private let location = LocationAuthCoordinator()

    public init() {}

    // MARK: Info.plist crash-guard (pure, testable)

    /// The usage-description Info.plist key that MUST be present before requesting `type`.
    /// `notification` intentionally maps to `nil` — notification auth needs no usage string.
    /// Unknown/unsupported types also map to `nil` (handled as `.unavailable` by `requiresDeclaredKey`).
    public static func requiredInfoPlistKey(for type: String) -> String? {
        switch type {
        case "camera": return "NSCameraUsageDescription"
        case "microphone": return "NSMicrophoneUsageDescription"
        case "photos": return "NSPhotoLibraryUsageDescription"
        case "location": return "NSLocationWhenInUseUsageDescription"
        case "contacts": return "NSContactsUsageDescription"
        case "att": return "NSUserTrackingUsageDescription"
        case "calendar":
            if #available(iOS 17.0, *) { return "NSCalendarsFullAccessUsageDescription" }
            return "NSCalendarsUsageDescription"
        case "notification":
            return nil
        default:
            return nil
        }
    }

    /// Whether `type` is a supported permission type at all. `notification` is the only
    /// supported type with no required key; everything else with a `nil` key is unsupported.
    public static func isSupported(_ type: String) -> Bool {
        switch type {
        case "notification", "att", "location", "camera",
             "microphone", "photos", "contacts", "calendar":
            return true
        // Mrozu QA (2026-08-04, Flo s26) — `health` (HealthKit connect) is a console-authorable
        // permission_type that already ROUTES through this manager (resolvePermissionType → here),
        // but the native HealthKit authorization request is DEFERRED (needs the HealthKit entitlement
        // + a per-app read/share type set, which is host infra). It falls to the `default` safe path
        // below, so the CTA advances instead of stranding the user. The standalone `health_connect`
        // block is the host-driven connect surface today.
        default:
            return false
        }
    }

    /// Pure guard decision. Returns `.unavailable` when the type is unsupported, or when it
    /// requires a usage-description key that is absent. Returns `nil` to mean "safe to proceed".
    /// Injectable `keyPresent` lookup keeps this unit-testable without a real bundle.
    public static func plistGuardStatus(
        type: String,
        keyPresent: (String) -> Bool
    ) -> PermissionStatus? {
        guard isSupported(type) else { return .unavailable }
        guard let key = requiredInfoPlistKey(for: type) else {
            // Supported + no key required (notification) → safe.
            return nil
        }
        return keyPresent(key) ? nil : .unavailable
    }

    /// Pure status → route mapping used by the renderer's permission pipeline. Extracted so the
    /// routing (already-granted / denied / unavailable / prompt) is unit-testable without the OS.
    public static func route(for status: PermissionStatus) -> PermissionRouteDecision {
        switch status {
        case .granted: return .alreadyGranted
        case .denied: return .denied
        case .unavailable: return .unavailable
        case .undetermined: return .prompt
        }
    }

    /// Whether iOS 14.5+ ATT should be skipped and treated as granted (no tracking prompt exists
    /// below 14.5). Pure so the short-circuit is testable independent of the running OS.
    public static func attGrantedWithoutPrompt(major: Int, minor: Int) -> Bool {
        if major < 14 { return true }
        if major == 14 && minor < 5 { return true }
        return false
    }

    private func liveKeyPresent(_ key: String) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    /// Applies the crash-guard against the live main bundle.
    private func guardStatus(_ type: String) -> PermissionStatus? {
        Self.plistGuardStatus(type: type, keyPresent: liveKeyPresent)
    }

    // MARK: Status

    public func status(_ type: String) async -> PermissionStatus {
        if let guarded = guardStatus(type) { return guarded }

        switch type {
        case "notification":
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }

        case "att":
            #if canImport(AppTrackingTransparency)
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
            #else
            return .granted
            #endif

        case "camera":
            return Self.mapAV(AVCaptureDevice.authorizationStatus(for: .video))

        case "microphone":
            return Self.mapAV(AVCaptureDevice.authorizationStatus(for: .audio))

        case "photos":
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }

        case "contacts":
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .undetermined
            // `.limited` (iOS 18+) and any future access-granting case → granted.
            @unknown default: return .granted
            }

        case "location":
            return location.currentStatus

        case "calendar":
            let s = EKEventStore.authorizationStatus(for: .event)
            if #available(iOS 17.0, *) {
                switch s {
                case .fullAccess, .authorized, .writeOnly: return .granted
                case .denied, .restricted: return .denied
                case .notDetermined: return .undetermined
                @unknown default: return .undetermined
                }
            } else {
                switch s {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                case .notDetermined: return .undetermined
                @unknown default: return .undetermined
                }
            }

        default:
            return .unavailable
        }
    }

    // MARK: Request

    /// Fire the real OS prompt. Returns whether the permission was granted.
    /// Re-applies the Info.plist crash-guard defensively: a missing key returns `false`
    /// WITHOUT touching the OS API (the renderer already routes `.unavailable` off `status`,
    /// so it never reaches here, but the guard makes `request` safe to call directly).
    public func request(_ type: String) async -> Bool {
        if guardStatus(type) != nil { return false }

        switch type {
        case "notification":
            return await requestNotification()

        case "att":
            return await requestATT()

        case "camera":
            return await AVCaptureDevice.requestAccess(for: .video)

        case "microphone":
            return await AVCaptureDevice.requestAccess(for: .audio)

        case "photos":
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            // `.limited` is treated as granted (SPEC-421).
            return status == .authorized || status == .limited

        case "contacts":
            do {
                return try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                Log.warning("[Permission] contacts request failed: \(error.localizedDescription)")
                return false
            }

        case "location":
            return await location.request()

        case "calendar":
            return await requestCalendar()

        default:
            return false
        }
    }

    // MARK: Settings deep-link

    /// Open the app's Settings page so a permanently-denied permission can be flipped.
    public func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        #endif
    }

    // MARK: - Per-type request helpers

    private func requestNotification() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            Log.warning("[Permission] notification request failed: \(error.localizedDescription)")
            return false
        }
    }

    private func requestATT() async -> Bool {
        // ATT must be requested on the main thread while the app is active. Below 14.5 there is no
        // tracking prompt → treat as granted.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if Self.attGrantedWithoutPrompt(major: os.majorVersion, minor: os.minorVersion) {
            return true
        }
        #if canImport(AppTrackingTransparency)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                #if canImport(UIKit)
                guard UIApplication.shared.applicationState == .active else {
                    // Not safe to prompt when backgrounded — report current status.
                    cont.resume(returning: ATTrackingManager.trackingAuthorizationStatus == .authorized)
                    return
                }
                #endif
                ATTrackingManager.requestTrackingAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        }
        #else
        return true
        #endif
    }

    private func requestCalendar() async -> Bool {
        let store = EKEventStore()
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            Log.warning("[Permission] calendar request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Mapping helpers

    private static func mapAV(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}

// MARK: - Location authorization coordinator

/// Bridges `CLLocationManager`'s delegate-only authorization callback to an async
/// continuation. Retained by `PermissionManager` so the callback survives the request.
private final class LocationAuthCoordinator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var awaitingResult = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var currentStatus: PermissionStatus {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func request() async -> Bool {
        // Already resolved → return immediately without prompting.
        let current = manager.authorizationStatus
        if current != .notDetermined {
            return current == .authorizedWhenInUse || current == .authorizedAlways
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            self.awaitingResult = true
            DispatchQueue.main.async {
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingResult, let cont = continuation else { return }
        let status = manager.authorizationStatus
        // The delegate fires once with `.notDetermined` right after `delegate` is set; ignore
        // it and wait for the real user decision.
        if status == .notDetermined { return }
        continuation = nil
        awaitingResult = false
        cont.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
