import UserNotifications

/// UNNotificationServiceExtension for rich push content: downloads the image attachment and registers
/// the push's action-button category before the notification is shown (without it, buttons of a button
/// set the app has not seen yet do not appear). Add as a separate target:
/// AppDNANotificationServiceExtension, whose principal class subclasses this one.
open class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttempt = bestAttempt

        // SPEC-497 §17 item 28 — register the action buttons' category BEFORE the notification is shown:
        // iOS displays buttons only for a category that is already registered, and this extension is the
        // one place that runs before display while the app is not running. The server marks every push
        // with buttons `mutable-content`, so this runs for them.
        Self.registerActionCategory(from: bestAttempt.userInfo, slot: SystemNotificationCenterSlot()) {
            if let category = PushActionCategories.category(from: bestAttempt.userInfo) {
                bestAttempt.categoryIdentifier = category.identifier
            }
            // Download image attachment if present
            if let imageUrlString = bestAttempt.userInfo["image_url"] as? String,
               let url = URL(string: imageUrlString) {
                self.downloadAttachment(url: url) { attachment in
                    if let attachment = attachment {
                        bestAttempt.attachments = [attachment]
                    }
                    contentHandler(bestAttempt)
                }
            } else {
                contentHandler(bestAttempt)
            }
        }
    }

    /// Registers the payload's button category and calls `completion` once the centre holds it: the set
    /// is written asynchronously, and reading the categories back waits for that write — without it the
    /// notification can be shown before its category exists. A payload without buttons completes at once.
    static func registerActionCategory(
        from userInfo: [AnyHashable: Any],
        slot: NotificationCenterSlot,
        completion: @escaping () -> Void
    ) {
        guard PushActionCategories.category(from: userInfo) != nil else { return completion() }
        PushActionCategories.register(from: userInfo, slot: slot) {
            slot.getCategories { _ in completion() }
        }
    }

    override open func serviceExtensionTimeWillExpire() {
        // Deliver best attempt before time runs out
        if let contentHandler = contentHandler, let bestAttempt = bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    private func downloadAttachment(url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL, error == nil else {
                completion(nil)
                return
            }

            // SPEC-085: Determine file extension from MIME type or URL
            let ext: String
            if let mimeType = (response as? HTTPURLResponse)?.mimeType {
                switch mimeType {
                case "image/jpeg": ext = "jpg"
                case "image/png": ext = "png"
                case "image/gif": ext = "gif"
                case "video/mp4": ext = "mp4"
                default: ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                }
            } else {
                ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            }

            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)

            do {
                try FileManager.default.moveItem(at: localURL, to: tempFile)
                let attachment = try UNNotificationAttachment(
                    identifier: "appdna-media",
                    url: tempFile,
                    options: nil
                )
                completion(attachment)
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }
}
