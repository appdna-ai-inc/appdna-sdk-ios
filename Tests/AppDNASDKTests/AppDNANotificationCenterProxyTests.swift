// AppDNANotificationCenterProxyTests.swift
//
// SPEC-497 B6 (§9a.8) — the notification delegate proxy, driven through `ProxyCore` (UNNotification
// cannot be constructed in a test) with recording fake previous delegates, and through the proxy object
// for the `responds(to:)` / `forwardingTarget` / `conforms(to:)` rules. Hostless: an in-memory
// `NotificationCenterSlot`, never the real centre.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import ObjectiveC
import UserNotifications
@testable import AppDNASDK
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

private final class OpenSettingsPrevious: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {}
}

final class AppDNANotificationCenterProxyTests: XCTestCase {

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var manager: PushTokenManager!

    override func setUp() {
        super.setUp()
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        let keychain = KeychainStore(service: "ai.appdna.sdk.proxy.\(UUID().uuidString)")
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        events = []
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        manager = PushTokenManager(keychainStore: keychain, eventTracker: tracker, apiClient: nil)
        AppDNA.pushModule.manager = manager
    }

    override func tearDown() {
        AppDNA.pushModule.manager = nil
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        super.tearDown()
    }

    private let appdna: [AnyHashable: Any] = ["appdna": "1", "push_id": "p1", "delivery_id": "d1"]
    private let foreign: [AnyHashable: Any] = ["push_id": "host"]

    private func core(previous: UNUserNotificationCenterDelegate?, advertises: Bool = true, override: [String]? = nil) -> ProxyCore {
        ProxyCore(previous: previous, advertisesWillPresent: advertises, presentationOverride: override)
    }

    // MARK: - Completion exactly once

    func testAppDNAPushIsHandledNotForwardedAndCompletedOnceWithDefaultOptions() {
        PushGate.shared.markConfigured()
        let c = core(previous: RecordingPreviousDelegate())
        var forwarded = 0, completions = 0
        var options: UNNotificationPresentationOptions = []
        c.willPresent(userInfo: appdna, requestId: "r", forward: { cb in forwarded += 1; cb([]) }) {
            completions += 1; options = $0
        }
        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(NotificationProxyPolicy.names(options), ["banner", "list", "sound", "badge"])
        XCTAssertEqual(events.map(\.event_name), ["push_delivered"])
        XCTAssertEqual(c.lastDecision, .track)
    }

    func testPresentationOverrideIsUsedForAppDNAPushes() {
        PushGate.shared.markConfigured()
        let c = core(previous: nil, override: ["banner"])
        var options: UNNotificationPresentationOptions = []
        c.willPresent(userInfo: appdna, requestId: "r", forward: nil) { options = $0 }
        XCTAssertEqual(NotificationProxyPolicy.names(options), ["banner"])
    }

    func testForeignPushReachesPreviousWithTheOriginalCompletion() {
        PushGate.shared.markConfigured()
        let c = core(previous: RecordingPreviousDelegate())
        var forwarded = 0, completions = 0
        var options: UNNotificationPresentationOptions = []
        c.willPresent(userInfo: foreign, requestId: "r", forward: { cb in forwarded += 1; cb([.list]) }) {
            completions += 1; options = $0
        }
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(options, [.list], "the previous delegate's own presentation")
        XCTAssertTrue(events.isEmpty)
    }

    func testForeignPushWithNoPreviousIsNotPresented() {
        let c = core(previous: nil)
        var completions = 0
        var options: UNNotificationPresentationOptions = [.banner]
        c.willPresent(userInfo: foreign, requestId: "r", forward: nil) { completions += 1; options = $0 }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(options, [])
        var tapCompletions = 0
        c.didReceive(userInfo: foreign, requestId: "r", actionId: "x", forward: nil) { tapCompletions += 1 }
        XCTAssertEqual(tapCompletions, 1)
    }

    func testReentryCompletesOnceAndDoesNotForwardAgain() {
        PushGate.shared.markConfigured()
        let c = core(previous: RecordingPreviousDelegate())
        var forwarded = 0, completions = 0
        var reentering: ProxyCore.WillPresentForward!
        reentering = { cb in
            forwarded += 1
            c.willPresent(userInfo: self.foreign, requestId: "r", forward: reentering, completion: cb)
        }
        c.willPresent(userInfo: foreign, requestId: "r", forward: reentering) { _ in completions += 1 }
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(c.lastDecision, .completeWith)
    }

    /// notifee's `willPresent` never completes: the in-flight key is released when the FORWARD CALL
    /// returns, so a later `didReceive` of the same notification is still forwarded.
    func testInFlightKeyIsReleasedWhenTheForwardReturnsNotWhenItCompletes() {
        PushGate.shared.markConfigured()
        let c = core(previous: RecordingPreviousDelegate())
        var didForward = 0
        c.willPresent(userInfo: foreign, requestId: "r", forward: { _ in /* never completes */ }) { _ in }
        c.didReceive(userInfo: foreign, requestId: "r", actionId: "a", forward: { cb in didForward += 1; cb() }) {}
        c.willPresent(userInfo: foreign, requestId: "r", forward: { cb in didForward += 1; cb([]) }) { _ in }
        XCTAssertEqual(didForward, 2)
    }

    func testAppDNATapCompletesImmediatelyAndTracksOnce() {
        PushGate.shared.markConfigured()
        let c = core(previous: RecordingPreviousDelegate())
        var order: [String] = []
        c.didReceive(userInfo: appdna, requestId: "r", actionId: UNNotificationDefaultActionIdentifier,
                     forward: { _ in order.append("forwarded") }) { order.append("completion") }
        XCTAssertEqual(order, ["completion"])
        XCTAssertEqual(events.map(\.event_name), ["push_tapped"])
    }

    func testAfterShutdownTheProxyIsPassThroughAndConfigureReenablesIt() {
        PushGate.shared.markConfigured()
        PushGate.shared.markShutDown()
        let c = core(previous: nil)
        var options: UNNotificationPresentationOptions = []
        c.willPresent(userInfo: appdna, requestId: "r", forward: nil) { options = $0 }
        XCTAssertEqual(c.lastDecision, .passThrough)
        XCTAssertFalse(options.isEmpty, "presented with the default options")
        XCTAssertTrue(events.isEmpty, "neither tracked nor routed")

        PushGate.shared.markConfigured()
        c.willPresent(userInfo: appdna, requestId: "r2", forward: nil) { _ in }
        XCTAssertEqual(c.lastDecision, .track)
        XCTAssertEqual(events.map(\.event_name), ["push_delivered"])
    }

    func testBeforeTheConfiguredPointAnAppDNAPushIsPresentedAndBuffered() {
        let c = core(previous: nil)
        var options: UNNotificationPresentationOptions = []
        c.willPresent(userInfo: appdna, requestId: "r", forward: nil) { options = $0 }
        XCTAssertEqual(c.lastDecision, .buffer)
        XCTAssertFalse(options.isEmpty)
        XCTAssertEqual(PushGate.shared.bufferCount, 1)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - responds / forwarding / conforms

    func testRespondsToWillPresentFollowsTheInstallTimeRule() {
        let willPresent = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        let didReceive = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        let advertising = AppDNANotificationCenterProxy(core: core(previous: nil, advertises: true))
        let silent = AppDNANotificationCenterProxy(core: core(previous: nil, advertises: false))
        XCTAssertTrue(advertising.responds(to: willPresent))
        XCTAssertFalse(silent.responds(to: willPresent))
        XCTAssertTrue(silent.responds(to: didReceive), "didReceive is always answered")
    }

    func testOptionalSelectorOnlyPreviousImplementsIsAdvertisedAndForwarded() {
        let openSettings = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:))
        let previous = OpenSettingsPrevious()
        let proxy = AppDNANotificationCenterProxy(core: core(previous: previous))
        XCTAssertTrue(proxy.responds(to: openSettings))
        XCTAssertTrue((proxy.forwardingTarget(for: openSettings) as? OpenSettingsPrevious) === previous)
        let bare = AppDNANotificationCenterProxy(core: core(previous: nil))
        XCTAssertFalse(bare.responds(to: openSettings))
    }

    /// When AppDNA wraps a `FlutterAppDelegate`, FlutterFire must still see a
    /// `FlutterAppLifeCycleProvider` (the protocol here is a test stand-in created at test time).
    func testConformsToAnswersForThePreviousDelegatesProtocols() {
        let name = "AppDNATestLifeCycleProvider_\(UUID().uuidString.prefix(8))"
        guard let proto = objc_allocateProtocol(name) else { return XCTFail("could not allocate protocol") }
        objc_registerProtocol(proto)
        let previousClassName = "AppDNATestPrevious_\(UUID().uuidString.prefix(8))"
        guard let cls = objc_allocateClassPair(NSObject.self, previousClassName, 0) else { return XCTFail("class pair") }
        class_addProtocol(cls, proto)
        class_addProtocol(cls, UNUserNotificationCenterDelegate.self)
        objc_registerClassPair(cls)
        guard let previous = (cls as? NSObject.Type)?.init() as? UNUserNotificationCenterDelegate else {
            return XCTFail("instance")
        }
        let proxy = AppDNANotificationCenterProxy(core: core(previous: previous))
        XCTAssertTrue(proxy.conforms(to: proto))
        XCTAssertFalse(AppDNANotificationCenterProxy(core: core(previous: nil)).conforms(to: proto))
        XCTAssertTrue(proxy.conforms(to: UNUserNotificationCenterDelegate.self))
    }

    // MARK: - Install / diagnose

    func testInstallIsIdempotentAndWrapsThePrevious() {
        let host = RecordingPreviousDelegate()
        let slot = InMemoryNotificationCenterSlot(delegate: host)
        NotificationProxyBootstrap.install(slot: slot, plist: [:], source: .explicit)
        let first = slot.delegate
        XCTAssertTrue(first is AppDNANotificationCenterProxy)
        XCTAssertTrue((first as? AppDNANotificationCenterProxy)?.core.previous === host)
        NotificationProxyBootstrap.install(slot: slot, plist: [:], source: .explicit)
        XCTAssertTrue(slot.delegate === first)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: installed"))
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: explicit"))
    }

    func testDisabledKeyInstallsNothingAndDiagnosesDisabled() {
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.install(slot: slot, plist: ["AppDNADisableNotificationProxy": true], source: .explicit)
        XCTAssertNil(slot.delegate)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: disabled"))
    }

    func testDiagnoseStatesNotInstalledShutdownAndReplaced() {
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: not_installed"))
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: none"))
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.install(slot: slot, plist: [:], source: .launchObserver)
        PushGate.shared.markShutDown()
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: shutdown"))
        PushGate.shared.markConfigured()
        slot.delegate = RecordingPreviousDelegate()
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: wrapped-or-replaced"))
    }

    func testLaunchBufferDrainsOnceAfterConfigure() {
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.install(slot: slot, plist: [:], source: .launchObserver)
        let c = (slot.delegate as? AppDNANotificationCenterProxy)!.core
        c.didReceive(userInfo: appdna, requestId: "r", actionId: UNNotificationDefaultActionIdentifier, forward: nil) {}
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("launchBufferSize: 1"))
        XCTAssertTrue(events.isEmpty)
        PushGate.shared.markConfigured()
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(events.map(\.event_name), ["push_tapped"])
        PushGate.shared.markConfigured()
        let exp2 = expectation(description: "drain again")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp2.fulfill() }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(events.count, 1, "drained once")
    }

    // MARK: - Pure policies

    func testAdvertisesWillPresentRule() {
        XCTAssertTrue(NotificationProxyPolicy.advertisesWillPresent(previousResponds: true, previousIsNil: false, presentationOverrideSet: false, detectedLibraries: ["NotifeeCore"]))
        XCTAssertTrue(NotificationProxyPolicy.advertisesWillPresent(previousResponds: false, previousIsNil: true, presentationOverrideSet: true, detectedLibraries: ["NotifeeCore"]))
        XCTAssertTrue(NotificationProxyPolicy.advertisesWillPresent(previousResponds: false, previousIsNil: true, presentationOverrideSet: false, detectedLibraries: []))
        XCTAssertFalse(NotificationProxyPolicy.advertisesWillPresent(previousResponds: false, previousIsNil: true, presentationOverrideSet: false, detectedLibraries: ["FLTFirebaseMessagingPlugin"]))
        XCTAssertFalse(NotificationProxyPolicy.advertisesWillPresent(previousResponds: false, previousIsNil: false, presentationOverrideSet: false, detectedLibraries: []))
    }

    func testDecideTable() {
        typealias P = NotificationProxyPolicy
        XCTAssertEqual(P.decide(isAppDNA: true, previousRespondsWillPresent: true, presentationOverride: nil, configured: true, reentered: false, shutdown: false), .track)
        XCTAssertEqual(P.decide(isAppDNA: true, previousRespondsWillPresent: true, presentationOverride: nil, configured: false, reentered: false, shutdown: false), .buffer)
        XCTAssertEqual(P.decide(isAppDNA: true, previousRespondsWillPresent: false, presentationOverride: nil, configured: false, reentered: false, shutdown: true), .passThrough)
        XCTAssertEqual(P.decide(isAppDNA: false, previousRespondsWillPresent: true, presentationOverride: nil, configured: true, reentered: false, shutdown: false), .forward)
        XCTAssertEqual(P.decide(isAppDNA: false, previousRespondsWillPresent: false, presentationOverride: nil, configured: true, reentered: false, shutdown: false), .completeWith)
        XCTAssertEqual(P.decide(isAppDNA: false, previousRespondsWillPresent: true, presentationOverride: nil, configured: true, reentered: true, shutdown: false), .completeWith)
        XCTAssertEqual(P.decide(isAppDNA: true, previousRespondsWillPresent: true, presentationOverride: nil, configured: true, reentered: true, shutdown: false), .completeWith)
    }

    func testPresentationOverrideParsing() {
        XCTAssertNil(NotificationProxyPolicy.presentationOverride(from: [:]))
        XCTAssertEqual(NotificationProxyPolicy.presentationOverride(from: ["AppDNAForegroundPresentation": ["banner", "sound"]]), ["banner", "sound"])
        XCTAssertEqual(NotificationProxyPolicy.presentationOverride(from: ["AppDNAForegroundPresentation": [String]()]), [])
        XCTAssertEqual(NotificationProxyPolicy.options([]), [])
    }
}
