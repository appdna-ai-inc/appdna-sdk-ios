import Foundation
import ObjectiveC

/// The permission APIs, reached at RUNTIME instead of linked.
///
/// The pod is a static framework, so every class the SDK references by symbol lands in the HOST's
/// binary — and App Store Connect's static check (ITMS-90683) then asks the host for the Contacts,
/// Calendar, tracking, camera, microphone and photo-library purpose strings even when no permission
/// step is ever authored. So those classes are never named in code: the system framework is
/// `dlopen`ed, the class is looked up with `NSClassFromString`, and each selector is called through
/// its IMP cast to a `@convention(c)` function type (`perform(_:)` cannot pass or return the integer
/// enums). A missing framework, class or selector yields `nil`, which the manager reports as
/// `.unavailable`. Location stays statically linked (CoreLocation), and the image picker is the
/// out-of-process `PhotosPicker`, which needs neither the photo-library API nor a purpose string.
///
/// The status enums are raw integers here and mapped explicitly by `PermissionManager`:
///   CNAuthorizationStatus        0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited
///   EKAuthorizationStatus        0 notDetermined, 1 restricted, 2 denied, 3 fullAccess, 4 writeOnly
///   ATTrackingManager status     0 notDetermined, 1 restricted, 2 denied, 3 authorized
///   PHAuthorizationStatus        0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited
///   AVAuthorizationStatus        mapped typed (`AVAuthorizationStatus(rawValue:)`) — AVFoundation stays linked
struct PermissionRuntime {

    /// Looks a class up by name. Production `dlopen`s the system framework first; tests return a
    /// recording fake.
    let resolver: PermissionClassResolving

    init(resolver: PermissionClassResolving = SystemPermissionClassResolver()) {
        self.resolver = resolver
    }

    // Class names and the frameworks that own them — strings only, never symbols.
    enum Target {
        static let contacts = ("CNContactStore", "Contacts")
        static let calendar = ("EKEventStore", "EventKit")
        static let tracking = ("ATTrackingManager", "AppTrackingTransparency")
        static let photos = ("PHPhotoLibrary", "Photos")
        static let capture = ("AVCaptureDevice", "AVFoundation")
    }

    /// `CNEntityType.contacts`, `EKEntityType.event`, `PHAccessLevel.readWrite`.
    static let contactsEntity = 0
    static let eventEntity = 0
    static let photoAccessReadWrite = 2

    private typealias StatusForInt = @convention(c) (AnyObject, Selector, Int) -> Int
    private typealias StatusForObject = @convention(c) (AnyObject, Selector, AnyObject) -> Int
    private typealias StatusNoArg = @convention(c) (AnyObject, Selector) -> Int
    private typealias BoolErrorBlock = @convention(block) (ObjCBool, NSError?) -> Void
    private typealias BoolBlock = @convention(block) (ObjCBool) -> Void
    private typealias IntBlock = @convention(block) (Int) -> Void
    private typealias RequestIntBoolError = @convention(c) (AnyObject, Selector, Int, BoolErrorBlock) -> Void
    private typealias RequestBoolError = @convention(c) (AnyObject, Selector, BoolErrorBlock) -> Void
    private typealias RequestObjectBool = @convention(c) (AnyObject, Selector, AnyObject, BoolBlock) -> Void
    private typealias RequestIntInt = @convention(c) (AnyObject, Selector, Int, IntBlock) -> Void
    private typealias RequestInt = @convention(c) (AnyObject, Selector, IntBlock) -> Void

    // MARK: - Lookup

    private func cls(_ target: (String, String)) -> AnyClass? {
        resolver.resolveClass(named: target.0, framework: target.1)
    }

    private func classIMP(_ c: AnyClass, _ name: String) -> IMP? {
        guard let m = class_getClassMethod(c, NSSelectorFromString(name)) else { return nil }
        return method_getImplementation(m)
    }

    private func instanceIMP(_ c: AnyClass, _ name: String) -> IMP? {
        guard let m = class_getInstanceMethod(c, NSSelectorFromString(name)) else { return nil }
        return method_getImplementation(m)
    }

    private func newInstance(_ c: AnyClass) -> NSObject? {
        (c as? NSObject.Type)?.init()
    }

    // MARK: - Status (raw integers; nil = framework, class or selector unavailable)

    func contactsStatus() -> Int? {
        statusForInt(Target.contacts, "authorizationStatusForEntityType:", Self.contactsEntity)
    }

    func calendarStatus() -> Int? {
        statusForInt(Target.calendar, "authorizationStatusForEntityType:", Self.eventEntity)
    }

    func trackingStatus() -> Int? {
        guard let c = cls(Target.tracking), let imp = classIMP(c, "trackingAuthorizationStatus") else { return nil }
        return unsafeBitCast(imp, to: StatusNoArg.self)(c, NSSelectorFromString("trackingAuthorizationStatus"))
    }

    func photosStatus() -> Int? {
        statusForInt(Target.photos, "authorizationStatusForAccessLevel:", Self.photoAccessReadWrite)
    }

    /// `mediaType` is `AVMediaType.video.rawValue` / `.audio.rawValue`.
    func captureStatus(mediaType: String) -> Int? {
        let name = "authorizationStatusForMediaType:"
        guard let c = cls(Target.capture), let imp = classIMP(c, name) else { return nil }
        return unsafeBitCast(imp, to: StatusForObject.self)(c, NSSelectorFromString(name), mediaType as NSString)
    }

    private func statusForInt(_ target: (String, String), _ name: String, _ arg: Int) -> Int? {
        guard let c = cls(target), let imp = classIMP(c, name) else { return nil }
        return unsafeBitCast(imp, to: StatusForInt.self)(c, NSSelectorFromString(name), arg)
    }

    // MARK: - Requests (nil = unavailable)

    func requestContacts() async -> Bool? {
        let name = "requestAccessForEntityType:completionHandler:"
        guard let c = cls(Target.contacts), let imp = instanceIMP(c, name), let store = newInstance(c) else { return nil }
        let fn = unsafeBitCast(imp, to: RequestIntBoolError.self)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // The store is captured by the block, so it lives until the completion runs.
            let block: BoolErrorBlock = { granted, error in
                if let error { Log.warning("[Permission] contacts request failed: \(error.localizedDescription)") }
                withExtendedLifetime(store) { cont.resume(returning: granted.boolValue) }
            }
            fn(store, NSSelectorFromString(name), Self.contactsEntity, block)
        }
    }

    func requestCalendar() async -> Bool? {
        guard let c = cls(Target.calendar), let store = newInstance(c) else { return nil }
        let full = "requestFullAccessToEventsWithCompletion:"
        let legacy = "requestAccessToEntityType:completion:"
        if #available(iOS 17.0, *), let imp = instanceIMP(c, full) {
            let fn = unsafeBitCast(imp, to: RequestBoolError.self)
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let block: BoolErrorBlock = { granted, error in
                    if let error { Log.warning("[Permission] calendar request failed: \(error.localizedDescription)") }
                    withExtendedLifetime(store) { cont.resume(returning: granted.boolValue) }
                }
                fn(store, NSSelectorFromString(full), block)
            }
        }
        guard let imp = instanceIMP(c, legacy) else { return nil }
        let fn = unsafeBitCast(imp, to: RequestIntBoolError.self)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let block: BoolErrorBlock = { granted, error in
                if let error { Log.warning("[Permission] calendar request failed: \(error.localizedDescription)") }
                withExtendedLifetime(store) { cont.resume(returning: granted.boolValue) }
            }
            fn(store, NSSelectorFromString(legacy), Self.eventEntity, block)
        }
    }

    /// Returns the raw ATT status the user chose. The request is issued on the main thread, as ATT
    /// requires.
    func requestTracking() async -> Int? {
        let name = "requestTrackingAuthorizationWithCompletionHandler:"
        guard let c = cls(Target.tracking), let imp = classIMP(c, name) else { return nil }
        let fn = unsafeBitCast(imp, to: RequestInt.self)
        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let block: IntBlock = { status in cont.resume(returning: status) }
            let call = { fn(c, NSSelectorFromString(name), block) }
            if Thread.isMainThread { call() } else { DispatchQueue.main.async(execute: call) }
        }
    }

    /// Returns the raw PHAuthorizationStatus the user chose.
    func requestPhotos() async -> Int? {
        let name = "requestAuthorizationForAccessLevel:handler:"
        guard let c = cls(Target.photos), let imp = classIMP(c, name) else { return nil }
        let fn = unsafeBitCast(imp, to: RequestIntInt.self)
        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let block: IntBlock = { status in cont.resume(returning: status) }
            fn(c, NSSelectorFromString(name), Self.photoAccessReadWrite, block)
        }
    }

    func requestCapture(mediaType: String) async -> Bool? {
        let name = "requestAccessForMediaType:completionHandler:"
        guard let c = cls(Target.capture), let imp = classIMP(c, name) else { return nil }
        let fn = unsafeBitCast(imp, to: RequestObjectBool.self)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let block: BoolBlock = { granted in cont.resume(returning: granted.boolValue) }
            fn(c, NSSelectorFromString(name), mediaType as NSString, block)
        }
    }
}

/// Resolves a permission API class by name. Injectable so tests can hand back a recording fake.
protocol PermissionClassResolving {
    func resolveClass(named name: String, framework: String) -> AnyClass?
}

/// Production: load the system framework, then look the class up by name.
struct SystemPermissionClassResolver: PermissionClassResolving {
    func resolveClass(named name: String, framework: String) -> AnyClass? {
        if let existing = NSClassFromString(name) { return existing }
        // The frameworks live in the dyld shared cache on device and simulator; `dlopen` just maps them.
        _ = dlopen("/System/Library/Frameworks/\(framework).framework/\(framework)", RTLD_LAZY)
        return NSClassFromString(name)
    }
}
