import XCTest
import UserNotifications
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

/// The Notification Service Extension confirms delivery: delivered counts only what the device confirms. iOS draws a push to an app that is not running without running app code, so the extension — which runs for
/// every AppDNA push now that the server marks every push `mutable-content` — is the only code that can report it.
final class NotificationServiceReceiptTests: XCTestCase {
    private let delivery = "3f1c2b1e-8d7a-4c6b-9e2f-5a4b3c2d1e0f"

    private func plainPush(receiptURL: String? = "https://api.example.test/api/v1/push/receipt") -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"], "mutable-content": 1],
            "appdna": "1", "push_id": "p1", "delivery_id": delivery, "receipt_sig": "c2lnbmF0dXJl",
        ]
        if let receiptURL { info["receipt_url"] = receiptURL }
        return info
    }

    private func receive(_ service: NotificationService, _ userInfo: [AnyHashable: Any], handed: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        service.didReceive(UNNotificationRequest(identifier: "r", content: content, trigger: nil)) { _ in handed() }
    }

    func testAPlainPushSendsOneReceiptThenHandsTheContentBack() {
        let service = NotificationService()
        var sent: [URLRequest] = []
        service.receiptSender = { request, done in sent.append(request); done() }
        let back = expectation(description: "handed back")
        receive(service, plainPush()) { back.fulfill() }
        wait(for: [back], timeout: 5)
        XCTAssertEqual(sent.count, 1)
        let request = try! XCTUnwrap(sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/v1/push/receipt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try! JSONSerialization.jsonObject(with: try! XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["delivery_id": delivery, "receipt_sig": "c2lnbmF0dXJl"])
    }

    /// The content waits for the receipt (the extension may be suspended once it is handed back), and the time-out
    /// still hands it back once if the receipt never finishes.
    func testTheContentWaitsForTheReceiptAndTheTimeoutStillHandsItBackOnce() {
        let service = NotificationService()
        var finishReceipt: (() -> Void)?
        service.receiptSender = { _, done in finishReceipt = done }
        var handed = 0
        receive(service, plainPush()) { handed += 1 }
        // Give the (empty) content work a moment: it is done, but the receipt is not.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(handed, 0, "waiting for the receipt")
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(handed, 1)
        finishReceipt?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(handed, 1, "the content handler runs once")
    }

    /// Red controls: nothing is sent for a push from an older server (no receipt keys), a host's own push (no marker),
    /// a non-HTTPS receipt URL, or an extension that opts out — and the content is still handed back.
    func testNoReceiptWithoutAValidAppDNAReceipt() {
        XCTAssertNotNil(NotificationService.deliveryReceiptRequest(from: plainPush()), "the control: a valid receipt IS built")
        XCTAssertNil(NotificationService.deliveryReceiptRequest(from: plainPush(receiptURL: nil)))
        XCTAssertNil(NotificationService.deliveryReceiptRequest(from: plainPush(receiptURL: "http://api.example.test/r")))
        var foreign = plainPush()
        foreign["appdna"] = nil
        XCTAssertNil(NotificationService.deliveryReceiptRequest(from: foreign))

        final class OptedOut: NotificationService { override var reportsDelivery: Bool { false } }
        for (service, info) in [(NotificationService(), plainPush(receiptURL: nil)), (OptedOut(), plainPush())] {
            var sent = 0
            service.receiptSender = { _, done in sent += 1; done() }
            var handed = 0
            receive(service, info) { handed += 1 }
            XCTAssertEqual(handed, 1, "handed back at once, as before")
            XCTAssertEqual(sent, 0)
        }
    }
}
