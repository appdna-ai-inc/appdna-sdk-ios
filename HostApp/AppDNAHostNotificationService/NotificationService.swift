import AppDNANotificationExtension

/// The host's Notification Service Extension, exactly as the docs give it: it confirms each AppDNA push's
/// delivery, downloads its image and registers its buttons, while the host app is not running.
final class NotificationService: AppDNANotificationExtension.NotificationService {}
