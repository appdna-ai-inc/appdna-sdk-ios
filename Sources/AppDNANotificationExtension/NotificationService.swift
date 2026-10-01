import Foundation
import UserNotifications

/// UNNotificationServiceExtension for rich push content: downloads the image attachment and registers
/// the push's action-button category before the notification is shown (without it, buttons of a button
/// set the app has not seen yet do not appear). Add a Notification Service Extension target whose
/// principal class subclasses this one, and link the extension-safe `AppDNANotificationExtension` library
/// (SwiftPM product / CocoaPods pod) to it — not `AppDNASDK`, which uses API unavailable in an app
/// extension (`UIApplication.shared`) and installs its notification handler at launch. This module builds
/// with application-extension-only API.
open class NotificationService: UNNotificationServiceExtension {
    /// Guards `contentHandler`, `bestAttempt` and `delivered`: the download completes on a URLSession
    /// queue while `serviceExtensionTimeWillExpire` runs on the extension's own thread.
    private let stateLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    /// The content handler may be called once. Both the normal path and the time-out path end in
    /// `deliver()`, and only the first call reaches the handler — the time-out used to hand the content
    /// back and the download, finishing later, handed it back a second time.
    private var delivered = false

    /// Test seam: loads the image attachment (default: `downloadAttachment`).
    var attachmentLoader: ((URL, @escaping (UNNotificationAttachment?) -> Void) -> Void)?

    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        stateLock.lock()
        self.contentHandler = contentHandler
        self.bestAttempt = content
        self.delivered = false
        stateLock.unlock()
        let userInfo = content.userInfo

        // SPEC-497 §17 item 28 — register the action buttons' category BEFORE the notification is shown:
        // iOS displays buttons only for a category that is already registered, and this extension is the
        // one place that runs before display while the app is not running. The server marks every push
        // with buttons `mutable-content`, so this runs for them.
        Self.registerActionCategory(from: userInfo, slot: SystemNotificationCenterSlot()) {
            if let category = PushActionCategories.category(from: userInfo) {
                self.updateBestAttempt { $0.categoryIdentifier = category.identifier }
            }
            // Download image attachment if present
            if let imageUrlString = userInfo["image_url"] as? String,
               let url = URL(string: imageUrlString) {
                let load = self.attachmentLoader ?? { [weak self] url, done in
                    guard let self else { return done(nil) }
                    self.downloadAttachment(url: url, completion: done)
                }
                load(url) { attachment in
                    if let attachment = attachment {
                        self.updateBestAttempt { $0.attachments = [attachment] }
                    }
                    self.deliver()
                }
            } else {
                self.deliver()
            }
        }
    }

    /// Mutates the best attempt under the lock; a no-op once the content was handed back.
    private func updateBestAttempt(_ change: (UNMutableNotificationContent) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !delivered, let bestAttempt else { return }
        change(bestAttempt)
    }

    /// Hands the best attempt to the content handler — once (see `delivered`).
    private func deliver() {
        stateLock.lock()
        guard !delivered, let handler = contentHandler, let bestAttempt else {
            stateLock.unlock()
            return
        }
        delivered = true
        contentHandler = nil
        let content = bestAttempt.copy() as? UNNotificationContent ?? bestAttempt
        stateLock.unlock()
        handler(content)
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
        // Deliver the best attempt before time runs out (once; a later download completion is ignored).
        deliver()
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
