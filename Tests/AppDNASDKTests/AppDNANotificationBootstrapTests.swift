// AppDNANotificationBootstrapTests.swift
//
// SPEC-497 B6 (§9a.4, §9a.8) — installing the proxy: the launch-options capture, the disabled key,
// the ObjC loader (present in the test bundle, inert under XCTest), the `observerRegistered` reader,
// the configure-fallback decision table and the "configure → host sets its delegate → launch observer
// fires" sequence. Hostless: an in-memory slot throughout.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import ObjectiveC
import UIKit
import UserNotifications
@testable import AppDNASDK

final class AppDNANotificationBootstrapTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
    }

    override func tearDown() {
        NotificationProxyBootstrap.resetForTesting()
        PushIdempotency.resetForTesting()
        super.tearDown()
    }

    // MARK: - The ObjC loader

    func testRealLoaderClassIsLinkedIntoTheTestBundle() {
        XCTAssertNotNil(NSClassFromString("AppDNASDKLoader"))
    }

    /// `+load` returns immediately when `XCTestConfigurationFilePath` is set, so it neither registers
    /// an observer nor sets the flag.
    func testLoaderIsInertUnderXCTest() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertFalse(NotificationProxyBootstrap.observerRegistered())
        XCTAssertFalse(NotificationProxyBootstrap.observerRegistered(loaderClass: "AppDNASDKLoader"))
    }

    func testObserverRegisteredReader() {
        // Missing class.
        XCTAssertFalse(NotificationProxyBootstrap.observerRegistered(loaderClass: "NoSuchLoader_\(UUID().uuidString.prefix(6))"))
        // Class without the selector.
        let bare = makeClass { _ in }
        XCTAssertFalse(NotificationProxyBootstrap.observerRegistered(loaderClass: bare))
        // Selector returning nil.
        let nilReturning = makeClass { cls in
            let block: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            Self.addClassMethod(cls, "observerRegistered", imp_implementationWithBlock(block))
        }
        XCTAssertFalse(NotificationProxyBootstrap.observerRegistered(loaderClass: nilReturning))
        // Present and YES.
        let yes = makeRegisteredLoaderDouble()
        XCTAssertTrue(NotificationProxyBootstrap.observerRegistered(loaderClass: yes))
    }

    // MARK: - install(slot:plist:)

    func testInstallBuffersALaunchOptionsTap() {
        let slot = InMemoryNotificationCenterSlot()
        let remote: [AnyHashable: Any] = ["appdna": "1", "push_id": "p1", "delivery_id": "d1"]
        NotificationProxyBootstrap.install(
            slot: slot, plist: [:], source: .launchObserver,
            launchOptions: [UIApplication.LaunchOptionsKey.remoteNotification: remote]
        )
        XCTAssertTrue(slot.delegate is AppDNANotificationCenterProxy)
        XCTAssertEqual(PushGate.shared.bufferCount, 1)
    }

    func testForeignLaunchOptionsPushIsNotBuffered() {
        NotificationProxyBootstrap.install(
            slot: InMemoryNotificationCenterSlot(), plist: [:], source: .launchObserver,
            launchOptions: [UIApplication.LaunchOptionsKey.remoteNotification: ["push_id": "host"]]
        )
        XCTAssertEqual(PushGate.shared.bufferCount, 0)
    }

    func testDisabledKeyRecordsTheFlagAndInstallsNothing() {
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.install(slot: slot, plist: ["AppDNADisableNotificationProxy": true], source: .launchObserver)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationDelegate: disabled"))
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: none"))
        XCTAssertEqual(slot.delegateReads, 0, "neither the disabled install nor diagnose() read the centre")
        XCTAssertNil(slot.delegate)
    }

    // MARK: - Configure fallback

    func testInstallDecisionTable() {
        typealias I = NotificationProxyInstall
        XCTAssertEqual(I.decide(installed: false, observerRegistered: false, launchObserved: false, disabled: true), .none)
        XCTAssertEqual(I.decide(installed: true, observerRegistered: false, launchObserved: false, disabled: false), .none)
        XCTAssertEqual(I.decide(installed: false, observerRegistered: false, launchObserved: false, disabled: false), .installFallback)
        XCTAssertEqual(I.decide(installed: false, observerRegistered: true, launchObserved: false, disabled: false), .deferToObserver)
        XCTAssertEqual(I.decide(installed: false, observerRegistered: true, launchObserved: true, disabled: false), .none)
    }

    /// Under XCTest with no injected slot the fallback records nothing and does not set the
    /// install-once flag, so a later `install(slot:plist:)` still installs and reports its own source.
    func testFallbackWithoutAnInjectedSlotIsANoOp() {
        NotificationProxyBootstrap.configureFallback(plist: [:])
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: none"))
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.install(slot: slot, plist: [:], source: .explicit)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: explicit"))
    }

    func testFallbackInstallsIntoTheInjectedSlotWhenNoObserverWasRegistered() {
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.injectedSlot = slot
        NotificationProxyBootstrap.configureFallback(plist: [:])
        XCTAssertTrue(slot.delegate is AppDNANotificationCenterProxy)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: configure_fallback"))
    }

    /// configure (observer registered, still inside launch → defers) → the host sets its delegate →
    /// the launch observer fires → the proxy wraps the host delegate, source `launch_observer`.
    func testConfigureThenHostDelegateThenLaunchObserverWrapsTheHostDelegate() {
        let slot = InMemoryNotificationCenterSlot()
        NotificationProxyBootstrap.injectedSlot = slot
        NotificationProxyBootstrap.loaderClassName = makeRegisteredLoaderDouble()

        NotificationProxyBootstrap.configureFallback(plist: [:])
        XCTAssertNil(slot.delegate, "configure defers to the launch observer")

        let host = RecordingPreviousDelegate()
        slot.delegate = host

        NotificationProxyBootstrap.handleLaunch(source: .launchObserver)
        let proxy = slot.delegate as? AppDNANotificationCenterProxy
        XCTAssertNotNil(proxy)
        XCTAssertTrue(proxy?.core.previous === host)
        XCTAssertTrue(NotificationProxyBootstrap.diagnoseLines().contains("notificationProxyInstallSource: launch_observer"))

        // After the observer ran, configure does nothing.
        NotificationProxyBootstrap.configureFallback(plist: [:])
        XCTAssertTrue(slot.delegate === proxy)
    }

    // MARK: - Helpers

    private func makeClass(_ configure: (AnyClass) -> Void) -> String {
        let name = "AppDNALoaderDouble_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        let cls: AnyClass = objc_allocateClassPair(NSObject.self, name, 0)!
        configure(cls)
        objc_registerClassPair(cls)
        return name
    }

    private func makeRegisteredLoaderDouble() -> String {
        makeClass { cls in
            let block: @convention(block) (AnyObject) -> NSNumber = { _ in NSNumber(value: true) }
            Self.addClassMethod(cls, "observerRegistered", imp_implementationWithBlock(block))
        }
    }

    private static func addClassMethod(_ cls: AnyClass, _ selectorName: String, _ imp: IMP) {
        guard let meta = object_getClass(cls) else { return }
        class_addMethod(meta, NSSelectorFromString(selectorName), imp, "@@:")
    }
}
