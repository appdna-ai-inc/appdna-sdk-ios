// PermissionRuntimeTests.swift
//
// SPEC-497 §13i.4 (D3) — every runtime-resolved permission type, through `PermissionManager` with an
// injected Info.plist reader and a recording fake class resolver:
//   key present  → the request reaches the fake class, with the right selector and arguments;
//   key absent   → `.unavailable` without touching the class;
//   class absent → `.unavailable`.
// The real system classes are used only for read-only status selectors.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import AVFoundation
@testable import AppDNASDK

// MARK: - Recording fakes (ObjC classes with the system selectors)

final class PermissionCallLog {
    static var calls: [String] = []
    static var args: [String: Any] = [:]
    static func reset() { calls = []; args = [:] }
}

@objc(AppDNATestFakeContactStore) final class FakeContactStore: NSObject {
    static var status = 0
    @objc(authorizationStatusForEntityType:) class func authorizationStatus(forEntityType t: Int) -> Int {
        PermissionCallLog.calls.append("contacts.status"); PermissionCallLog.args["contacts.entity"] = t
        return status
    }
    @objc(requestAccessForEntityType:completionHandler:) func requestAccess(forEntityType t: Int, completionHandler: @escaping (Bool, Error?) -> Void) {
        PermissionCallLog.calls.append("contacts.request"); PermissionCallLog.args["contacts.request.entity"] = t
        completionHandler(true, nil)
    }
}

@objc(AppDNATestFakeEventStore) final class FakeEventStore: NSObject {
    static var status = 0
    @objc(authorizationStatusForEntityType:) class func authorizationStatus(forEntityType t: Int) -> Int {
        PermissionCallLog.calls.append("calendar.status"); PermissionCallLog.args["calendar.entity"] = t
        return status
    }
    @objc(requestFullAccessToEventsWithCompletion:) func requestFullAccess(completion: @escaping (Bool, Error?) -> Void) {
        PermissionCallLog.calls.append("calendar.requestFull")
        completion(true, nil)
    }
    @objc(requestAccessToEntityType:completion:) func requestAccess(toEntityType t: Int, completion: @escaping (Bool, Error?) -> Void) {
        PermissionCallLog.calls.append("calendar.requestLegacy"); PermissionCallLog.args["calendar.request.entity"] = t
        completion(true, nil)
    }
}

@objc(AppDNATestFakeTrackingManager) final class FakeTrackingManager: NSObject {
    static var status = 0
    @objc(trackingAuthorizationStatus) class func trackingAuthorizationStatus() -> Int {
        PermissionCallLog.calls.append("att.status"); return status
    }
    @objc(requestTrackingAuthorizationWithCompletionHandler:) class func requestTracking(completionHandler: @escaping (Int) -> Void) {
        PermissionCallLog.calls.append("att.request"); completionHandler(3)
    }
}

@objc(AppDNATestFakePhotoLibrary) final class FakePhotoLibrary: NSObject {
    static var status = 0
    @objc(authorizationStatusForAccessLevel:) class func authorizationStatus(forAccessLevel l: Int) -> Int {
        PermissionCallLog.calls.append("photos.status"); PermissionCallLog.args["photos.level"] = l
        return status
    }
    @objc(requestAuthorizationForAccessLevel:handler:) class func requestAuthorization(forAccessLevel l: Int, handler: @escaping (Int) -> Void) {
        PermissionCallLog.calls.append("photos.request"); PermissionCallLog.args["photos.request.level"] = l
        handler(4) // limited → granted
    }
}

@objc(AppDNATestFakeCaptureDevice) final class FakeCaptureDevice: NSObject {
    static var status = 0
    @objc(authorizationStatusForMediaType:) class func authorizationStatus(forMediaType m: NSString) -> Int {
        PermissionCallLog.calls.append("capture.status"); PermissionCallLog.args["capture.media"] = m as String
        return status
    }
    @objc(requestAccessForMediaType:completionHandler:) class func requestAccess(forMediaType m: NSString, completionHandler: @escaping (Bool) -> Void) {
        PermissionCallLog.calls.append("capture.request"); PermissionCallLog.args["capture.request.media"] = m as String
        completionHandler(true)
    }
}

/// Hands back the fakes by the SYSTEM class names the runtime asks for; records every lookup.
final class FakePermissionResolver: PermissionClassResolving {
    var lookups: [String] = []
    var missing: Set<String> = []
    func resolveClass(named name: String, framework: String) -> AnyClass? {
        lookups.append("\(framework)/\(name)")
        if missing.contains(name) { return nil }
        switch name {
        case "CNContactStore": return FakeContactStore.self
        case "EKEventStore": return FakeEventStore.self
        case "ATTrackingManager": return FakeTrackingManager.self
        case "PHPhotoLibrary": return FakePhotoLibrary.self
        case "AVCaptureDevice": return FakeCaptureDevice.self
        default: return nil
        }
    }
}

final class PermissionRuntimeTests: XCTestCase {

    private var resolver: FakePermissionResolver!

    override func setUp() {
        super.setUp()
        PermissionCallLog.reset()
        resolver = FakePermissionResolver()
        FakeContactStore.status = 0; FakeEventStore.status = 0; FakeTrackingManager.status = 0
        FakePhotoLibrary.status = 0; FakeCaptureDevice.status = 0
    }

    private func manager(keys: Bool) -> PermissionManager {
        PermissionManager(infoPlist: { _ in keys ? "why" : nil }, resolver: resolver)
    }

    // MARK: key present → forwarded to the fake class

    func testContactsForwarded() async {
        let m = manager(keys: true)
        let s = await m.status("contacts")
        XCTAssertEqual(s, .undetermined)
        XCTAssertEqual(PermissionCallLog.args["contacts.entity"] as? Int, 0)
        let granted = await m.request("contacts")
        XCTAssertTrue(granted)
        XCTAssertEqual(PermissionCallLog.calls, ["contacts.status", "contacts.request"])
        XCTAssertEqual(PermissionCallLog.args["contacts.request.entity"] as? Int, 0)
        XCTAssertEqual(resolver.lookups.first, "Contacts/CNContactStore")
    }

    func testCalendarForwarded() async {
        let m = manager(keys: true)
        FakeEventStore.status = 4
        let s = await m.status("calendar")
        XCTAssertEqual(s, .granted, "writeOnly (4) counts as granted")
        let granted = await m.request("calendar")
        XCTAssertTrue(granted)
        if #available(iOS 17.0, *) {
            XCTAssertEqual(PermissionCallLog.calls.last, "calendar.requestFull")
        } else {
            XCTAssertEqual(PermissionCallLog.calls.last, "calendar.requestLegacy")
        }
    }

    func testTrackingForwarded() async {
        let m = manager(keys: true)
        FakeTrackingManager.status = 2
        let s = await m.status("att")
        XCTAssertEqual(s, .denied)
        XCTAssertTrue(PermissionCallLog.calls.contains("att.status"))
    }

    /// The ATT REQUEST, through the fake tracking manager: while the app is active it prompts (the fake
    /// answers authorized, 3); while it is not, it only reads the status (SPEC-497 §13i.4, impl audit 29).
    func testTrackingRequestReachesTheFakeOnlyWhileActive() async throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try XCTSkipIf(PermissionManager.attGrantedWithoutPrompt(major: os.majorVersion, minor: os.minorVersion),
                      "no ATT prompt below iOS 14.5")
        let active = PermissionManager(infoPlist: { _ in "why" }, resolver: resolver, applicationIsActive: { true })
        let granted = await active.request("att")
        XCTAssertTrue(granted, "the fake answers authorized (3)")
        XCTAssertEqual(PermissionCallLog.calls, ["att.request"])
        XCTAssertEqual(resolver.lookups.last, "AppTrackingTransparency/ATTrackingManager")

        PermissionCallLog.reset()
        FakeTrackingManager.status = 3
        let inactive = PermissionManager(infoPlist: { _ in "why" }, resolver: resolver, applicationIsActive: { false })
        let grantedInactive = await inactive.request("att")
        XCTAssertTrue(grantedInactive, "inactive: the current status (authorized) is reported")
        XCTAssertEqual(PermissionCallLog.calls, ["att.status"], "no prompt while inactive")
    }

    func testPhotosForwarded() async {
        let m = manager(keys: true)
        FakePhotoLibrary.status = 4
        let s = await m.status("photos")
        XCTAssertEqual(s, .granted, "limited (4) counts as granted")
        XCTAssertEqual(PermissionCallLog.args["photos.level"] as? Int, 2, "readWrite access level")
        let granted = await m.request("photos")
        XCTAssertTrue(granted)
        XCTAssertEqual(PermissionCallLog.args["photos.request.level"] as? Int, 2)
    }

    func testCameraAndMicrophoneForwardedWithMediaTypes() async {
        let m = manager(keys: true)
        FakeCaptureDevice.status = 3
        let cam = await m.status("camera")
        XCTAssertEqual(cam, .granted)
        XCTAssertEqual(PermissionCallLog.args["capture.media"] as? String, AVMediaType.video.rawValue)
        let mic = await m.request("microphone")
        XCTAssertTrue(mic)
        XCTAssertEqual(PermissionCallLog.args["capture.request.media"] as? String, AVMediaType.audio.rawValue)
    }

    // MARK: key absent → unavailable, class untouched

    func testMissingKeyNeverTouchesTheClass() async {
        let m = manager(keys: false)
        for type in ["contacts", "calendar", "att", "photos", "camera", "microphone"] {
            let s = await m.status(type)
            XCTAssertEqual(s, .unavailable, type)
            let granted = await m.request(type)
            XCTAssertFalse(granted, type)
        }
        XCTAssertTrue(PermissionCallLog.calls.isEmpty)
        XCTAssertTrue(resolver.lookups.isEmpty)
    }

    // MARK: class absent → unavailable

    func testMissingClassIsUnavailable() async {
        resolver.missing = ["CNContactStore", "EKEventStore", "ATTrackingManager", "PHPhotoLibrary", "AVCaptureDevice"]
        let m = manager(keys: true)
        for type in ["contacts", "calendar", "att", "photos", "camera", "microphone"] {
            let s = await m.status(type)
            XCTAssertEqual(s, .unavailable, type)
        }
        let granted = await m.request("contacts")
        XCTAssertFalse(granted)
    }

    // MARK: raw mappings

    func testRawStatusMappings() {
        XCTAssertEqual(PermissionManager.mapContacts(0), .undetermined)
        XCTAssertEqual(PermissionManager.mapContacts(2), .denied)
        XCTAssertEqual(PermissionManager.mapContacts(4), .granted)
        XCTAssertEqual(PermissionManager.mapCalendar(3), .granted)
        XCTAssertEqual(PermissionManager.mapCalendar(1), .denied)
        XCTAssertEqual(PermissionManager.mapTracking(3), .granted)
        XCTAssertEqual(PermissionManager.mapTracking(0), .undetermined)
        XCTAssertEqual(PermissionManager.mapPhotos(1), .denied)
    }

    // MARK: the real system classes, read-only

    func testSystemResolverFindsTheRealClasses() {
        let system = SystemPermissionClassResolver()
        XCTAssertNotNil(system.resolveClass(named: "CNContactStore", framework: "Contacts"))
        XCTAssertNotNil(system.resolveClass(named: "EKEventStore", framework: "EventKit"))
        XCTAssertNotNil(system.resolveClass(named: "PHPhotoLibrary", framework: "Photos"))
        XCTAssertNotNil(system.resolveClass(named: "AVCaptureDevice", framework: "AVFoundation"))
        XCTAssertNotNil(system.resolveClass(named: "ATTrackingManager", framework: "AppTrackingTransparency"))
        let runtime = PermissionRuntime()
        XCTAssertNotNil(runtime.contactsStatus())
        XCTAssertNotNil(runtime.calendarStatus())
        XCTAssertNotNil(runtime.photosStatus())
        XCTAssertNotNil(runtime.trackingStatus())
        XCTAssertNotNil(runtime.captureStatus(mediaType: AVMediaType.video.rawValue))
    }
}
