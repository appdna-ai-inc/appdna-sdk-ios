import XCTest
import UIKit
import UserNotifications
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

/// A push image is published as a stable console URL that answers 302 to a freshly signed storage URL. The
/// Notification Service Extension's own download (`downloadAttachment`, not the test seam) must follow that redirect
/// and attach the image the signed URL serves. A URLProtocol stub plays both hops on `URLSession.shared`, which is the
/// session the extension downloads with.
final class AttachmentRedirectStubProtocol: URLProtocol {
    /// "ok": the signed hop answers a PNG. "expired": the signed hop answers 403 with an XML error body, as an expired
    /// signed URL does.
    static var signedMode = "ok"
    static var requested: [String] = []
    static let png: Data = {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }.pngData()!
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("push-image.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requested.append(url.absoluteString)
        if url.host == "console.push-image.test" {
            let signed = URL(string: "https://storage.push-image.test/bucket/assets/push/obj.png?X-Goog-Signature=abc")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": signed.absoluteString, "Content-Length": "0"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: signed), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let ok = Self.signedMode == "ok"
        let body = ok ? Self.png : Data("<?xml version='1.0'?><Error><Code>ExpiredToken</Code></Error>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: ok ? 200 : 403, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": ok ? "image/png" : "application/xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NotificationServiceAttachmentRedirectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AttachmentRedirectStubProtocol.signedMode = "ok"
        AttachmentRedirectStubProtocol.requested = []
        URLProtocol.registerClass(AttachmentRedirectStubProtocol.self)
    }
    override func tearDown() {
        URLProtocol.unregisterClass(AttachmentRedirectStubProtocol.self)
        super.tearDown()
    }

    private func deliver(imageURL: String) -> UNNotificationContent? {
        let service = NotificationService()
        service.receiptSender = { _, done in done() }
        let content = UNMutableNotificationContent()
        content.title = "T"
        content.userInfo = [
            "aps": ["alert": ["title": "T", "body": "B"], "mutable-content": 1],
            "appdna": "1", "push_id": "p1", "image_url": imageURL,
        ]
        var handed: UNNotificationContent?
        let back = expectation(description: "handed back")
        service.didReceive(UNNotificationRequest(identifier: "r", content: content, trigger: nil)) { c in
            handed = c; back.fulfill()
        }
        wait(for: [back], timeout: 10)
        return handed
    }

    /// The stored form: the stable URL redirects, and the image behind it is what is attached.
    func testTheStableImageUrlIsFollowedThroughItsRedirectAndAttached() throws {
        let url = "https://console.push-image.test/api/v1/public/asset/bucket/assets/push/obj.png"
        let content = try XCTUnwrap(deliver(imageURL: url))
        XCTAssertEqual(AttachmentRedirectStubProtocol.requested.count, 2, "both hops were requested: \(AttachmentRedirectStubProtocol.requested)")
        XCTAssertEqual(content.attachments.count, 1, "the image behind the redirect is attached")
        let attachment = try XCTUnwrap(content.attachments.first)
        XCTAssertEqual(attachment.identifier, "appdna-media")
        XCTAssertEqual(try Data(contentsOf: attachment.url), AttachmentRedirectStubProtocol.png, "the attached file is the signed hop's PNG")
    }

    /// A redirect to an expired signed URL answers 403 with an XML body. That body is not an image, so nothing is
    /// attached and the push still shows as text.
    func testAnExpiredSignedUrlAttachesNothingAndTheTextStillShows() throws {
        AttachmentRedirectStubProtocol.signedMode = "expired"
        let content = try XCTUnwrap(deliver(imageURL: "https://console.push-image.test/api/v1/public/asset/bucket/assets/push/obj.png"))
        XCTAssertEqual(AttachmentRedirectStubProtocol.requested.count, 2)
        XCTAssertEqual(content.attachments.count, 0, "an error page is never attached as the image")
        XCTAssertEqual(content.title, "T")
    }
}
