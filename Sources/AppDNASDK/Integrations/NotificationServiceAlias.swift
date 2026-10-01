#if SWIFT_PACKAGE
import AppDNANotificationExtension

/// Source compatibility: `NotificationService` and `AppDNANotificationService` moved to the
/// extension-safe `AppDNANotificationExtension` module (a Notification Service Extension links that library
/// alone). An extension written as `class NotificationService: AppDNASDK.NotificationService {}` still
/// compiles, but it links all of AppDNASDK; link `AppDNANotificationExtension` and subclass
/// `AppDNANotificationExtension.NotificationService` instead. (Under CocoaPods both classes are compiled
/// into AppDNASDK itself, so no alias is needed there.)
public typealias NotificationService = AppDNANotificationExtension.NotificationService
public typealias AppDNANotificationService = AppDNANotificationExtension.AppDNANotificationService
#endif
