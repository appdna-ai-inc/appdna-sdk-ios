import Foundation
import UIKit
import UserNotifications

// SPEC-497 B6 (§9a) — the iOS SDK installs its notification handler itself, as a DELEGATE PROXY that
// holds the previous `UNUserNotificationCenter` delegate and forwards everything that is not an AppDNA
// push to it. Swizzling was rejected (§9a.2): it mutates host classes and composes badly with
// Firebase's own swizzling. FlutterFire, RNFirebase and notifee all use this same pattern, so the
// proxy composes with them in either install order — outermost or innermost.

// MARK: - The notification-centre seam

/// Get/set the notification-centre delegate and its categories. Production wraps
/// `UNUserNotificationCenter.current()`; hostless tests inject an in-memory slot, because
/// `UNUserNotificationCenter.current()` raises "bundleProxyForCurrentProcess is nil" there.
protocol NotificationCenterSlot: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void)
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// The ONLY route by which the SDK may post a notification itself. iOS never does from a received
    /// push (the OS or the host presents; `handleMessageData` never displays — SPEC-497 §8.7), so
    /// nothing calls it today; the push fixtures read `notification_posted` from this slot instead of
    /// asserting a constant.
    func add(_ request: UNNotificationRequest)
}

final class SystemNotificationCenterSlot: NotificationCenterSlot {
    var delegate: UNUserNotificationCenterDelegate? {
        get { UNUserNotificationCenter.current().delegate }
        set { UNUserNotificationCenter.current().delegate = newValue }
    }
    func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) {
        UNUserNotificationCenter.current().getNotificationCategories(completionHandler: completion)
    }
    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Pure decisions

enum NotificationProxyPolicy {
    /// Push libraries that install their own proxy later and would wrap AppDNA (§9a.4 rule 3).
    static let knownPushLibraryClasses = [
        "FLTFirebaseMessagingPlugin",
        "RNFBMessagingUNUserNotificationCenter",
        "NotifeeCore",
    ]

    static let presentationKey = "AppDNAForegroundPresentation"
    static let disableKey = "AppDNADisableNotificationProxy"

    /// Does the proxy answer YES to `responds(to: willPresent)`? Fixed at install time (S2-M1 / X2-M4):
    /// FlutterFire and RNFirebase defer EVERY `willPresent` to their original delegate when it
    /// implements the method, so advertising it while AppDNA is innermost would take FCM foreground
    /// presentation away from them.
    static func advertisesWillPresent(
        previousResponds: Bool,
        previousIsNil: Bool,
        presentationOverrideSet: Bool,
        detectedLibraries: [String]
    ) -> Bool {
        previousResponds || presentationOverrideSet || (previousIsNil && detectedLibraries.isEmpty)
    }

    enum Decision: String {
        case track
        case forward
        case completeWith = "complete_with"
        case buffer
        case passThrough = "pass_through"
    }

    /// What the proxy does with one delegate call.
    /// - `reentered`: the proxy is already forwarding this (selector, notification) — a loop through a
    ///   library that wrapped it anyway. Never forward again; complete once.
    /// - An AppDNA push is handled by AppDNA and never forwarded (it could reach notifee with no
    ///   original, which would claim it as its own press): tracked from the configured point, buffered
    ///   before it, and passed through (presented, untracked) after `shutdown()`.
    /// - Anything else goes to `previous` when it implements the method, else is completed by the proxy.
    static func decide(
        isAppDNA: Bool,
        previousRespondsWillPresent: Bool,
        presentationOverride: [String]?,
        configured: Bool,
        reentered: Bool,
        shutdown: Bool
    ) -> Decision {
        if reentered { return .completeWith }
        if isAppDNA {
            if shutdown { return .passThrough }
            return configured ? .track : .buffer
        }
        return previousRespondsWillPresent ? .forward : .completeWith
    }

    /// The Info.plist `AppDNAForegroundPresentation` array (`banner`, `list`, `sound`, `badge`); nil
    /// when the key is not set. An empty array means "do not present".
    static func presentationOverride(from plist: [String: Any]) -> [String]? {
        guard let raw = plist[presentationKey] else { return nil }
        if let names = raw as? [String] { return names }
        if let array = raw as? [Any] { return array.compactMap { $0 as? String } }
        return nil
    }

    static let defaultPresentation = ["banner", "list", "sound", "badge"]

    static func options(_ names: [String]) -> UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = []
        for name in names {
            switch name {
            case "banner": options.insert(.banner)
            case "list": options.insert(.list)
            case "sound": options.insert(.sound)
            case "badge": options.insert(.badge)
            default: Log.warning("[Push] unknown \(presentationKey) entry '\(name)' ignored")
            }
        }
        return options
    }

    /// Stable names for an options set (fixtures and logs).
    static func names(_ options: UNNotificationPresentationOptions) -> [String] {
        var out: [String] = []
        if options.contains(.banner) { out.append("banner") }
        if options.contains(.list) { out.append("list") }
        if options.contains(.sound) { out.append("sound") }
        if options.contains(.badge) { out.append("badge") }
        return out
    }

    static func isDisabled(_ plist: [String: Any]) -> Bool {
        if let flag = plist[disableKey] as? Bool { return flag }
        if let number = plist[disableKey] as? NSNumber { return number.boolValue }
        if let text = plist[disableKey] as? String { return ["yes", "true", "1"].contains(text.lowercased()) }
        return false
    }
}

enum NotificationProxyInstall {
    enum Action: String {
        case none
        case deferToObserver = "defer_to_observer"
        case installFallback = "install_fallback"
    }

    /// What `configure` does about the proxy (§9a.4, S5-M2). `configure` runs INSIDE
    /// `didFinishLaunching`, before `UIApplicationDidFinishLaunchingNotification` is posted; a host that
    /// sets its own delegate after `configure` would replace a proxy installed here, and the install-once
    /// launch observer would then do nothing. So `configure` installs only when no launch observer was
    /// ever registered.
    static func decide(installed: Bool, observerRegistered: Bool, launchObserved: Bool, disabled: Bool) -> Action {
        if disabled { return .none }
        if installed { return .none }
        if !observerRegistered { return .installFallback }
        if !launchObserved { return .deferToObserver }
        return .none
    }
}

// MARK: - The core (testable without UNNotification)

/// The proxy's behaviour on plain values. `UNNotification` / `UNNotificationResponse` cannot be built
/// in a unit test, so the two delegate methods are thin adapters that extract
/// `(userInfo, request.identifier, actionIdentifier)` and call this.
final class ProxyCore {
    /// Held STRONGLY: every push library holds its own previous delegate weakly, and so would an
    /// assignment chain that dropped this one.
    let previous: UNUserNotificationCenterDelegate?
    let advertisesWillPresent: Bool
    let presentationOverride: [String]?

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private(set) var lastDecision: NotificationProxyPolicy.Decision?

    init(previous: UNUserNotificationCenterDelegate?, advertisesWillPresent: Bool, presentationOverride: [String]?) {
        self.previous = previous
        self.advertisesWillPresent = advertisesWillPresent
        self.presentationOverride = presentationOverride
    }

    var appDNAOptions: UNNotificationPresentationOptions {
        NotificationProxyPolicy.options(presentationOverride ?? NotificationProxyPolicy.defaultPresentation)
    }

    typealias WillPresentForward = (@escaping (UNNotificationPresentationOptions) -> Void) -> Void
    typealias DidReceiveForward = (@escaping () -> Void) -> Void

    /// `forward` is nil when `previous` does not implement `willPresent`.
    func willPresent(
        userInfo: [AnyHashable: Any],
        requestId: String,
        forward: WillPresentForward?,
        completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NotificationProxyBootstrap.recordCallback()
        let isAppDNA = PushMarker.isAppDNA(userInfo)
        let key = "willPresent|" + requestId
        let decision = decide(isAppDNA: isAppDNA, key: key, previousResponds: forward != nil)
        switch decision {
        case .track, .buffer:
            // One gate: `handleMessageData` buffers before the configured point itself.
            AppDNA.pushModule.handleMessageData(userInfo, inForeground: true, requestId: requestId)
            completion(appDNAOptions)
        case .passThrough:
            // After `shutdown()`: the DEFAULT presentation (§9a.4) — the Info.plist override belongs to a
            // configured SDK — and neither tracked nor routed.
            completion(NotificationProxyPolicy.options(NotificationProxyPolicy.defaultPresentation))
        case .forward:
            enter(key)
            defer { leave(key) }
            forward?(completion)
        case .completeWith:
            if !isAppDNA && isInFlight(key) {
                Log.warning("[Push] notification delegate loop detected (willPresent); completing once without presenting")
            }
            completion(isAppDNA ? appDNAOptions : [])
        }
    }

    /// `forward` is nil when `previous` does not implement `didReceive`.
    func didReceive(
        userInfo: [AnyHashable: Any],
        requestId: String,
        actionId: String,
        forward: DidReceiveForward?,
        completion: @escaping () -> Void
    ) {
        NotificationProxyBootstrap.recordCallback()
        let isAppDNA = PushMarker.isAppDNA(userInfo)
        let key = "didReceive|" + requestId
        let decision = decide(isAppDNA: isAppDNA, key: key, previousResponds: forward != nil)
        switch decision {
        case .track, .buffer:
            // Never hold the completion.
            completion()
            AppDNA.pushModule.handleNotificationTap(userInfo, actionIdentifier: actionId, requestId: requestId)
        case .passThrough:
            completion()
        case .forward:
            enter(key)
            defer { leave(key) }
            forward?(completion)
        case .completeWith:
            if !isAppDNA && isInFlight(key) {
                Log.warning("[Push] notification delegate loop detected (didReceive); completing once")
            }
            completion()
        }
    }

    private func decide(isAppDNA: Bool, key: String, previousResponds: Bool) -> NotificationProxyPolicy.Decision {
        let gate = PushGate.shared
        let decision = NotificationProxyPolicy.decide(
            isAppDNA: isAppDNA,
            previousRespondsWillPresent: previousResponds,
            presentationOverride: presentationOverride,
            configured: gate.isConfigured,
            reentered: isInFlight(key),
            shutdown: gate.isShutDown
        )
        lock.lock(); lastDecision = decision; lock.unlock()
        return decision
    }

    // The re-entrancy key is inserted just before the forward call and removed when that call RETURNS —
    // not when its completion runs (notifee's `willPresent` may never complete).
    private func enter(_ key: String) { lock.lock(); inFlight.insert(key); lock.unlock() }
    private func leave(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }
    private func isInFlight(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return inFlight.contains(key) }
}

// MARK: - The proxy object

final class AppDNANotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate {
    let core: ProxyCore

    init(core: ProxyCore) {
        self.core = core
        super.init()
    }

    private static let willPresentSelector = #selector(
        UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
    )

    // UserNotifications checks `responds(to:)` before calling an optional method, so
    // `forwardingTarget(for:)` alone would never be consulted (SDK minor 9).
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == Self.willPresentSelector { return core.advertisesWillPresent }
        if super.responds(to: aSelector) { return true }
        return core.previous?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let previous = core.previous, previous.responds(to: aSelector) { return previous }
        return super.forwardingTarget(for: aSelector)
    }

    /// Answers for `previous`'s protocols too — so when AppDNA wraps `FlutterAppDelegate`, FlutterFire
    /// sees a `FlutterAppLifeCycleProvider` and, by its own design, does not wrap it (flutterfire#4026).
    override func conforms(to aProtocol: Protocol) -> Bool {
        if super.conforms(to: aProtocol) { return true }
        return core.previous?.conforms(to: aProtocol) == true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        var forward: ProxyCore.WillPresentForward?
        if let previous = core.previous,
           previous.responds(to: Self.willPresentSelector) {
            forward = { completion in
                previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completion)
            }
        }
        core.willPresent(
            userInfo: request.content.userInfo,
            requestId: request.identifier,
            forward: forward,
            completion: completionHandler
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        var forward: ProxyCore.DidReceiveForward?
        let didReceiveSelector = #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)
        )
        if let previous = core.previous, previous.responds(to: didReceiveSelector) {
            forward = { completion in
                previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completion)
            }
        }
        core.didReceive(
            userInfo: PushReply.userInfo(of: response),
            requestId: request.identifier,
            actionId: response.actionIdentifier,
            forward: forward,
            completion: completionHandler
        )
    }
}

// MARK: - Bootstrap (installation)

/// One class, two names (round-20 SDK minor 4): `NotificationProxyBootstrap` in Swift and
/// `AppDNANotificationBootstrap` in the ObjC runtime — the name the `AppDNASDKLoader` `+load` observer
/// resolves with `NSClassFromString`, so it does not depend on the module name (SPM vs CocoaPods).
@objc(AppDNANotificationBootstrap)
final class NotificationProxyBootstrap: NSObject {

    enum InstallSource: String {
        case launchObserver = "launch_observer"
        case explicit
        case configureFallback = "configure_fallback"
        case none
    }

    /// The ObjC class that owns `+load`. A parameter default so tests can pass a test double's name.
    static var loaderClassName = "AppDNASDKLoader"

    /// Hostless tests inject a slot here; `handleLaunch` and the configure fallback never reach the
    /// real notification centre under XCTest without one.
    static var injectedSlot: NotificationCenterSlot?

    private static let lock = NSLock()
    private static var installed = false
    private static var disabledRecorded = false
    private static var source: InstallSource = .none
    private static var slot: NotificationCenterSlot?
    private static var proxy: AppDNANotificationCenterProxy?   // retained forever (static strong)
    private static var launchObserved = false
    private static var lastCallbackAt: Date?

    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Launch observer entry

    /// Called by the ObjC loader when `UIApplicationDidFinishLaunchingNotification` fires.
    @objc(handleLaunchNotification:)
    static func handleLaunchNotification(_ notification: Notification) {
        handleLaunch(source: .launchObserver, launchOptions: notification.userInfo)
    }

    /// The launch entry point (the sequence tests call it to simulate the observer).
    static func handleLaunch(source: InstallSource, launchOptions: [AnyHashable: Any]? = nil) {
        lock.lock(); launchObserved = true; lock.unlock()
        guard let slot = injectedSlot ?? (isRunningUnderXCTest ? nil : SystemNotificationCenterSlot()) else { return }
        install(slot: slot, plist: Bundle.main.infoDictionary ?? [:], source: source, launchOptions: launchOptions)
    }

    // MARK: Install

    /// Installs the proxy into `slot` once. Every install source goes through here, so the disabled
    /// flag is always recorded before any early return.
    static func install(
        slot: NotificationCenterSlot,
        plist: [String: Any],
        source: InstallSource = .explicit,
        launchOptions: [AnyHashable: Any]? = nil
    ) {
        if NotificationProxyPolicy.isDisabled(plist) {
            lock.lock(); disabledRecorded = true; lock.unlock()
            Log.info("[Push] notification proxy disabled by Info.plist")
            return
        }

        // Cold-start capture from the launch options (non-scene apps, fallback only — the proxy's own
        // `didReceive` is the primary source and replaces this entry).
        if let remote = launchOptions?[UIApplication.LaunchOptionsKey.remoteNotification] as? [AnyHashable: Any],
           PushMarker.isAppDNA(remote) {
            PushGate.shared.bufferLaunchTap(remote)
        }

        lock.lock()
        if installed { lock.unlock(); return }
        let previous = slot.delegate
        let override = NotificationProxyPolicy.presentationOverride(from: plist)
        let detected = NotificationProxyPolicy.knownPushLibraryClasses.filter { NSClassFromString($0) != nil }
        let advertises = NotificationProxyPolicy.advertisesWillPresent(
            previousResponds: previous?.responds(to: #selector(
                UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
            )) == true,
            previousIsNil: previous == nil,
            presentationOverrideSet: override != nil,
            detectedLibraries: detected
        )
        if previous is AppDNANotificationCenterProxy {
            Log.warning("[Push] notification proxy already the delegate; not wrapping it again")
        }
        let proxy = AppDNANotificationCenterProxy(core: ProxyCore(
            previous: previous, advertisesWillPresent: advertises, presentationOverride: override
        ))
        self.proxy = proxy
        self.slot = slot
        self.installed = true
        self.source = source
        lock.unlock()
        slot.delegate = proxy
        Log.info("[Push] notification proxy installed (source: \(source.rawValue), previous: \(previous.map { String(describing: type(of: $0)) } ?? "none"))")
    }

    // MARK: Configure fallback

    /// Reads `+[AppDNASDKLoader observerRegistered]` through the ObjC runtime (class and selector names
    /// survive symbol stripping; a C global read with `dlsym` would not). Missing class, missing
    /// selector or a nil result all mean "never registered".
    static func observerRegistered(loaderClass className: String = loaderClassName) -> Bool {
        guard let cls = NSClassFromString(className),
              let classObject = (cls as AnyObject) as? NSObjectProtocol else { return false }
        let selector = NSSelectorFromString("observerRegistered")
        guard classObject.responds(to: selector),
              let value = classObject.perform(selector)?.takeUnretainedValue() as? NSNumber else { return false }
        return value.boolValue
    }

    /// Called from `configure` (on the main queue). See `NotificationProxyInstall.decide`.
    static func configureFallback(plist: [String: Any]) {
        lock.lock()
        let isInstalled = installed
        let observed = launchObserved
        lock.unlock()
        let action = NotificationProxyInstall.decide(
            installed: isInstalled,
            observerRegistered: observerRegistered(),
            launchObserved: observed,
            disabled: NotificationProxyPolicy.isDisabled(plist)
        )
        guard action == .installFallback else { return }
        // Under XCTest with no injected slot this is a no-op that records nothing (round-11 SDK minor 3).
        guard let slot = injectedSlot ?? (isRunningUnderXCTest ? nil : SystemNotificationCenterSlot()) else { return }
        Log.warning("launch-time notification proxy not registered; launch taps before configure may be missed")
        install(slot: slot, plist: plist, source: .configureFallback)
    }

    // MARK: Categories / diagnostics

    /// The slot action categories are registered through: the installed one, else the real centre
    /// (never under XCTest).
    static func categorySlot() -> NotificationCenterSlot? {
        lock.lock(); let installedSlot = slot; lock.unlock()
        if let installedSlot { return installedSlot }
        if let injectedSlot { return injectedSlot }
        return isRunningUnderXCTest ? nil : SystemNotificationCenterSlot()
    }

    static func recordCallback() {
        lock.lock(); lastCallbackAt = Date(); lock.unlock()
    }

    /// `notificationDelegate` state, in this fixed order: disabled → not_installed → shutdown →
    /// installed → wrapped-or-replaced. `disabled` and `not_installed` read no notification centre.
    static func delegateState() -> String {
        lock.lock()
        let disabled = disabledRecorded
        let installedSlot = slot
        let installedProxy = proxy
        lock.unlock()
        if disabled || (!isRunningUnderXCTest && NotificationProxyPolicy.isDisabled(Bundle.main.infoDictionary ?? [:])) {
            return "disabled"
        }
        guard let installedSlot, let installedProxy else { return "not_installed" }
        if PushGate.shared.isShutDown { return "shutdown" }
        return installedSlot.delegate === installedProxy ? "installed" : "wrapped-or-replaced"
    }

    static func diagnoseLines() -> [String] {
        lock.lock()
        let src = source
        let last = lastCallbackAt
        lock.unlock()
        let lastText = last.map { ISO8601DateFormatter().string(from: $0) } ?? "null"
        return [
            "notificationDelegate: \(delegateState())",
            "notificationProxyInstallSource: \(src.rawValue)",
            "notificationProxyLastCallbackAt: \(lastText)",
            "launchBufferSize: \(PushGate.shared.bufferCount)",
        ]
    }

    /// Test isolation (round-16/17 SDK minor 1).
    static func resetForTesting() {
        lock.lock()
        installed = false
        disabledRecorded = false
        source = .none
        slot = nil
        proxy = nil
        launchObserved = false
        lastCallbackAt = nil
        loaderClassName = "AppDNASDKLoader"
        injectedSlot = nil
        lock.unlock()
        PushGate.shared.resetForTesting()
    }
}

// MARK: - Public API

extension AppDNA {
    /// Installs AppDNA's notification delegate proxy now (idempotent, main thread). The SDK installs it
    /// automatically at launch; call this only if your build drops the SDK's launch hook, and call it
    /// AFTER you set your own `UNUserNotificationCenter.current().delegate` — otherwise your assignment
    /// replaces the proxy. `AppDNADisableNotificationProxy = YES` in Info.plist always wins.
    public static func installNotificationProxy() {
        let run = {
            NotificationProxyBootstrap.install(
                slot: SystemNotificationCenterSlot(),
                plist: Bundle.main.infoDictionary ?? [:],
                source: .explicit
            )
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }
}
