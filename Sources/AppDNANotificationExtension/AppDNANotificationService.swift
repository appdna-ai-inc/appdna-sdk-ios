import UserNotifications

/// The older name of the rich-push extension helper, kept so an extension that subclasses it keeps
/// compiling. It is `NotificationService`: it downloads the push's image / GIF / video attachment, registers
/// the push's action-button category before display, and hands the content back ONCE (this class used
/// to hand it back twice when the download finished after `serviceExtensionTimeWillExpire`, and never
/// registered the buttons). It lives in the extension-safe `AppDNANotificationExtension` module now; link
/// that library to the Notification Service Extension, not `AppDNASDK`.
open class AppDNANotificationService: NotificationService {}
