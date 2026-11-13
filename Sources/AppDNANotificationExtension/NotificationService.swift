import Foundation
import UserNotifications

/// UNNotificationServiceExtension for AppDNA pushes: confirms delivery to AppDNA (the only way iOS lets a
/// push that arrives while the app is not running be counted as delivered), downloads the image attachment and
/// registers the push's action-button category before the notification is shown (without it, buttons of a button
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

    /// Test seam: sends the delivery receipt and calls back when it is done, whatever the outcome
    /// (default: `URLSession.shared`).
    var receiptSender: ((URLRequest, @escaping () -> Void) -> Void)?

    /// Whether this extension confirms delivery to AppDNA. On by default: iOS draws a push to an app that is
    /// not running without running any app code, so this extension is the only code that can report that the push
    /// arrived. Override to return `false` to opt out; AppDNA then counts that device's pushes as sent, never delivered.
    open var reportsDelivery: Bool { true }

    /// Where the extension hands its confirmed deliveries to the app for the `push_delivered` event: the App Group
    /// named under `AppDNAAppGroup` in the extension's Info.plist. Nil (no App Group): nothing is handed over, and only
    /// the server-side delivery from the receipt is counted. (Test seam: replace the provider.)
    var deliveryHandoff: () -> PushDeliveryHandoff? = { PushDeliveryHandoff(bundle: .main) }

    /// The delivery receipt allows this long before the content is handed back without waiting for it.
    static let receiptTimeout: TimeInterval = 8

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

        // The app's SDK tracks `push_delivered` for this delivery when it next runs (App Group hand-off; nothing without one).
        if reportsDelivery, (userInfo["appdna"] as? String) == "1",
           let deliveryId = userInfo["delivery_id"] as? String, !deliveryId.isEmpty {
            deliveryHandoff()?.record(pushId: userInfo["push_id"] as? String ?? "", deliveryId: deliveryId)
        }

        // With a receipt to send, the content is handed back once BOTH the content work (category + attachment) and the
        // receipt are done — the extension may be suspended as soon as the handler is called, so a receipt still in
        // flight then could be lost. `serviceExtensionTimeWillExpire` still hands the best attempt back if either runs
        // long. Without one, the content is handed back the moment it is ready, as before.
        let contentDone: () -> Void
        if reportsDelivery, let receipt = Self.deliveryReceiptRequest(from: userInfo) {
            let work = DispatchGroup()
            work.enter() // the content
            work.enter() // the receipt
            work.notify(queue: .global(qos: .userInitiated)) { self.deliver() }
            let send = receiptSender ?? Self.sendReceipt
            send(receipt) { work.leave() }
            contentDone = { work.leave() }
        } else {
            contentDone = { self.deliver() }
        }

        // Register the action buttons' category BEFORE the notification is shown:
        // iOS displays buttons only for a category that is already registered, and this extension is the
        // one place that runs before display while the app is not running. The server marks every push
        // `mutable-content`, so this runs for every AppDNA push.
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
                    contentDone()
                }
            } else {
                contentDone()
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
        // BUTTONS, not "has a category": every AppDNA push has one now. This extension
        // exists to register a BUTTON category before display; the button-less default belongs to
        // the app's configure, once per launch.
        guard PushActionCategories.hasActionButtons(userInfo) else { return completion() }
        PushActionCategories.register(from: userInfo, slot: slot) {
            slot.getCategories { _ in completion() }
        }
    }

    /// the delivery receipt the push carries, as a request, or nil when there is none to send.
    ///
    /// Every AppDNA push is `mutable-content`, so this extension runs for it while the app is not running, and the push
    /// carries what the extension needs to confirm delivery without the SDK's configuration (no API key, no app group):
    /// `receipt_url` and `receipt_sig`, a signature over `delivery_id` that only the AppDNA server can produce. Nil for a
    /// push that is not AppDNA's (no `appdna: "1"`), one from a server that sends no receipt, and any URL that is not
    /// HTTPS.
    public static func deliveryReceiptRequest(from userInfo: [AnyHashable: Any]) -> URLRequest? {
        guard (userInfo["appdna"] as? String) == "1",
              let deliveryId = userInfo["delivery_id"] as? String, !deliveryId.isEmpty,
              let sig = userInfo["receipt_sig"] as? String, !sig.isEmpty,
              let urlString = userInfo["receipt_url"] as? String,
              let url = URL(string: urlString), url.scheme?.lowercased() == "https", url.host != nil,
              let body = try? JSONSerialization.data(withJSONObject: ["delivery_id": deliveryId, "receipt_sig": sig], options: [.sortedKeys])
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: receiptTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func sendReceipt(_ request: URLRequest, done: @escaping () -> Void) {
        URLSession.shared.dataTask(with: request) { _, _, _ in done() }.resume()
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
            // Only a successful response whose body is media is attached. An error page (an expired signed URL's
            // 403, a 404, a proxy's HTML) attaches nothing, and the push shows as text.
            if let http = response as? HTTPURLResponse {
                let mime = http.mimeType?.lowercased() ?? ""
                let isMedia = mime.isEmpty || mime.hasPrefix("image/") || mime.hasPrefix("video/")
                    || mime == "application/octet-stream" || mime == "binary/octet-stream"
                guard (200...299).contains(http.statusCode), isMedia else {
                    completion(nil)
                    return
                }
            }

            // Determine file extension from MIME type or URL
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
