// SharedFixtureDrivers+Push.swift
//
// SPEC-497 — iOS drivers for the Push-area fixture kinds (classify_push, notification_proxy).
// Dispatched from `SharedFixtureTests.drive`'s default branch. Every value asserted is produced by a
// REAL SDK symbol (see the header of SharedFixtureTests.swift).
//
//   classify_push       REAL: `AppDNA.pushModule.isAppDNAMessage` — the B2 marker rule.
//   notification_proxy  REAL: `ProxyCore.willPresent` / `.didReceive` (the proxy's behaviour on plain
//                       values — `UNNotification` cannot be built in a test; the delegate methods are
//                       thin adapters onto exactly these), the push gate / launch buffer and
//                       `AppDNA.pushModule.handleNotificationTap` for `host_forward`; `install` runs
//                       the real `NotificationProxyBootstrap.install(slot:plist:)` (each declared
//                       `detected_libraries` name is registered as a throwaway ObjC class for the
//                       call) and reads the installed proxy's `responds(to: willPresent)`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import UserNotifications
import XCTest
import ObjectiveC
@testable import AppDNASDK

/// The in-memory notification-centre slot hostless tests inject (the real centre raises there).
final class InMemoryNotificationCenterSlot: NotificationCenterSlot {
    private var storedDelegate: UNUserNotificationCenterDelegate?
    private(set) var categories: Set<UNNotificationCategory> = []
    /// How often the delegate was READ — `diagnose()` must not read it for disabled / not installed.
    private(set) var delegateReads = 0

    var delegate: UNUserNotificationCenterDelegate? {
        get { delegateReads += 1; return storedDelegate }
        set { storedDelegate = newValue }
    }

    init(delegate: UNUserNotificationCenterDelegate? = nil) { self.storedDelegate = delegate }

    func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) { completion(categories) }
    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
    /// Every notification the SDK posted through the slot (`notification_posted`).
    private(set) var posted: [UNNotificationRequest] = []
    func add(_ request: UNNotificationRequest) { posted.append(request) }
}

/// A previous delegate that implements both methods and records the calls.
final class RecordingPreviousDelegate: NSObject, UNUserNotificationCenterDelegate {
    var willPresentCalls = 0
    var didReceiveCalls = 0
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        willPresentCalls += 1
        completionHandler([.list])
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        didReceiveCalls += 1
        completionHandler()
    }
}

/// A previous delegate that implements neither method.
final class SilentPreviousDelegate: NSObject, UNUserNotificationCenterDelegate {}

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveSpec497Push(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "classify_push":
            runClassifyPush(f, h)
            return true
        case "notification_proxy":
            await runNotificationProxy(f, h)
            return true
        default:
            return false
        }
    }

    /// Installs the proxy into an in-memory slot holding `previousKind`, with `override` in the plist and
    /// each of `detectedLibraries` present in the ObjC runtime (a throwaway class registered under that
    /// name for the call, then disposed), and returns what the installed proxy answers for
    /// `responds(to: willPresent)`.
    static func installedProxyAdvertisesWillPresent(
        previousKind: String,
        override: [String]?,
        detectedLibraries: [String]
    ) -> Bool? {
        NotificationProxyBootstrap.resetForTesting()
        defer { NotificationProxyBootstrap.resetForTesting() }
        var registered: [AnyClass] = []
        for name in detectedLibraries where NSClassFromString(name) == nil {
            guard let cls = objc_allocateClassPair(NSObject.self, name, 0) else { continue }
            objc_registerClassPair(cls)
            registered.append(cls)
        }
        defer { registered.forEach { objc_disposeClassPair($0) } }
        let previous: UNUserNotificationCenterDelegate?
        switch previousKind {
        case "none": previous = nil
        case "implements_neither": previous = SilentPreviousDelegate()
        default: previous = RecordingPreviousDelegate()
        }
        let slot = InMemoryNotificationCenterSlot(delegate: previous)
        var plist: [String: Any] = [:]
        if let override { plist[NotificationProxyPolicy.presentationKey] = override }
        NotificationProxyBootstrap.install(slot: slot, plist: plist, source: .explicit)
        guard let proxy = slot.delegate as? AppDNANotificationCenterProxy else { return nil }
        return withExtendedLifetime(previous) {
            proxy.responds(to: #selector(
                UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
            ))
        }
    }

    private func runClassifyPush(_ f: Fixture, _ h: Harness) {
        guard let payloadJSON = f.action.raw["payload"]?.objectValue else {
            return XCTFail("[\(f.id)] classify_push needs action.payload")
        }
        let userInfo: [AnyHashable: Any] = payloadJSON.mapValues { $0.foundation }
        h.state["is_appdna"] = AppDNA.pushModule.isAppDNAMessage(userInfo)    // REAL
    }

    private func runNotificationProxy(_ f: Fixture, _ h: Harness) async {
        let action = f.action.raw
        guard let method = action["method"]?.stringValue else {
            return XCTFail("[\(f.id)] notification_proxy needs action.method")
        }
        let previousKind = action["previous"]?.stringValue ?? "none"
        let override = action["presentation_override"]?.arrayValue?.compactMap { $0.stringValue }
        let detected = action["detected_libraries"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let previousResponds = previousKind == "implements_both" || previousKind == "reenters"
        let advertises = NotificationProxyPolicy.advertisesWillPresent(          // REAL
            previousResponds: previousResponds,
            previousIsNil: previousKind == "none",
            presentationOverrideSet: override != nil,
            detectedLibraries: detected
        )
        if method == "install" {
            // REAL install: `install(slot:plist:)` reads the previous delegate from the slot, the override
            // from the plist and the libraries from the ObjC runtime, and the installed proxy answers
            // `responds(to: willPresent)` — the value asserted. The pure rule must agree.
            let installed = Self.installedProxyAdvertisesWillPresent(
                previousKind: previousKind, override: override, detectedLibraries: detected
            )
            XCTAssertEqual(installed, advertises, "[\(f.id)] install() and advertisesWillPresent disagree")
            h.state["advertises_will_present"] = installed
            return
        }

        guard let payloadJSON = action["payload"]?.objectValue else {
            return XCTFail("[\(f.id)] notification_proxy \(method) needs action.payload")
        }
        let userInfo: [AnyHashable: Any] = payloadJSON.mapValues { $0.foundation }

        // Gate state: configured / not yet / after shutdown.
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        let manager = pushTokenManager(h)
        AppDNA.pushModule.manager = manager
        let pushSpy = PushDelegateSpy(harness: h)   // held here: `AppDNA.pushDelegate` is weak
        AppDNA.pushDelegate = pushSpy
        defer { withExtendedLifetime((manager, pushSpy)) { finishPushEntryPoints() } }
        if action["shutdown"]?.boolValue == true {
            PushGate.shared.markShutDown()
        } else if action["configured"]?.boolValue == true {
            PushGate.shared.markConfigured()
        }

        let previous: UNUserNotificationCenterDelegate?
        switch previousKind {
        case "none": previous = nil
        case "implements_neither": previous = SilentPreviousDelegate()
        default: previous = RecordingPreviousDelegate()
        }
        let core = ProxyCore(previous: previous, advertisesWillPresent: advertises, presentationOverride: override)

        var forwarded = 0
        var completions = 0
        var presented: [String]?
        let requestId = "req-\(f.id)"

        switch method {
        case "willPresent":
            var forward: ProxyCore.WillPresentForward?
            switch previousKind {
            case "implements_both":
                // What the adapter builds: the previous delegate's own method, original completion.
                forward = { completion in forwarded += 1; completion([.list]) }
            case "reenters":
                // A library that wrapped the proxy anyway: its willPresent calls straight back in.
                var reentering: ProxyCore.WillPresentForward!
                reentering = { completion in
                    forwarded += 1
                    core.willPresent(userInfo: userInfo, requestId: requestId, forward: reentering, completion: completion)
                }
                forward = reentering
            default:
                forward = nil
            }
            core.willPresent(userInfo: userInfo, requestId: requestId, forward: forward) { options in
                completions += 1
                presented = NotificationProxyPolicy.names(options)
            }
        case "didReceive":
            var forward: ProxyCore.DidReceiveForward?
            switch previousKind {
            case "implements_both":
                forward = { completion in forwarded += 1; completion() }
            case "reenters":
                var reentering: ProxyCore.DidReceiveForward!
                reentering = { completion in
                    forwarded += 1
                    core.didReceive(userInfo: userInfo, requestId: requestId,
                                    actionId: UNNotificationDefaultActionIdentifier,
                                    forward: reentering, completion: completion)
                }
                forward = reentering
            default:
                forward = nil
            }
            core.didReceive(userInfo: userInfo, requestId: requestId,
                            actionId: UNNotificationDefaultActionIdentifier, forward: forward) {
                completions += 1
            }
            if action["host_forward"]?.boolValue == true {
                // The host forwards the same response too — deduped by the B2 idempotency set.
                AppDNA.pushModule.handleNotificationTap(userInfo, actionIdentifier: UNNotificationDefaultActionIdentifier)
            }
        default:
            return XCTFail("[\(f.id)] notification_proxy method '\(method)' has no iOS driver")
        }

        if action["configure_after"]?.boolValue == true {
            PushGate.shared.markConfigured()                                   // the configured point
        }
        await settlePushMainQueue(seconds: 0.3)

        h.state["decision"] = core.lastDecision?.rawValue ?? NSNull()
        h.state["forwarded_to_previous"] = forwarded
        h.state["completion_calls"] = completions
        if let presented { h.state["presentation_options"] = presented }
    }
}
