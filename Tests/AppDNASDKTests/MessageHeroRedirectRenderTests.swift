import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 DOES A GENERATED IN-APP HERO DRAW THROUGH ITS STABLE, REDIRECTING URL?

 A generated hero is published as a stable console URL that answers 302 to a freshly signed storage URL: the signed
 URL itself expires after 7 days, while a config cached on a device lives longer. The modal draws
 `content.image_url` through `BundledAsyncPhaseImage` → `AsyncImage`, which loads with the shared URLSession — so the
 hero draws only if that load follows the redirect.

 A URLProtocol stub plays both hops: the stable URL → 302 → the signed URL → a real PNG. Live renders through the
 REAL `MessageRenderer`, counting pixels of the stub image's colour (red; nothing else on the modal is red):
   - THE CONTROL: the same stable URL answering 404 (an object no asset wrote) draws none, so the harness can tell a
     drawn hero from an empty one;
   - the redirecting URL draws the hero.
*/
final class HeroRedirectStubProtocol: URLProtocol {
    static var mode = "redirect"
    static var requested: [String] = []
    static let png: Data = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        return r.pngData { ctx in UIColor.systemRed.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "hero-redirect.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requested.append(url.path)
        if url.path.hasPrefix("/api/v1/public/message-hero/") {
            if Self.mode == "redirect" {
                let target = URL(string: "https://hero-redirect.test/signed/bucket/hero.png?X-Goog-Signature=fresh")!
                let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: resp)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if url.path.hasPrefix("/signed/") {
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.png)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

@MainActor
final class MessageHeroRedirectRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(HeroRedirectStubProtocol.self)
        HeroRedirectStubProtocol.requested = []
    }
    override func tearDown() {
        URLProtocol.unregisterClass(HeroRedirectStubProtocol.self)
        super.tearDown()
    }

    private func frame(imageURL: String?) throws -> [UInt8] {
        let hero = imageURL.map { #", "image_url": "\#($0)""# } ?? ""
        let json = """
        { "name": "synthetic", "message_type": "modal",
          "content": { "title": "A synthetic title", "body": "Body copy", "cta_text": "Primary action",
                       "background_color": "#FFFFFF", "text_color": "#111111"\(hero) },
          "trigger_rules": { "event": "e" } }
        """
        let config = try JSONDecoder().decode(MessageConfig.self, from: Data(json.utf8))
        let host = UIHostingController(rootView: AnyView(
            MessageRenderer(messageId: "m", config: config, onCTATap: {}, onDismiss: {})
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
        ))
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = bytes.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    /// Pixels of the stub hero's colour (systemRed): only a drawn hero puts any on this white, grey-text modal.
    private func redPixels(_ f: [UInt8]) -> Int {
        var n = 0
        var i = 0
        while i + 3 < f.count {
            if f[i] > 200 && f[i + 1] < 90 && f[i + 2] < 90 { n += 1 }
            i += 4
        }
        return n
    }

    func testAGeneratedHeroDrawsThroughItsRedirectingStableURL() throws {
        HeroRedirectStubProtocol.mode = "missing"
        let missing = try frame(imageURL: "https://hero-redirect.test/api/v1/public/message-hero/bucket/missing-\(UUID().uuidString).png")
        XCTAssertEqual(redPixels(missing), 0, "THE CONTROL: a stable URL that answers 404 must draw no hero pixels")

        HeroRedirectStubProtocol.mode = "redirect"
        HeroRedirectStubProtocol.requested = []
        let drawn = try frame(imageURL: "https://hero-redirect.test/api/v1/public/message-hero/bucket/pending/t/message_hero/2026-10/\(UUID().uuidString).png")
        XCTAssertTrue(HeroRedirectStubProtocol.requested.contains { $0.hasPrefix("/signed/") },
                      "the load never followed the redirect: \(HeroRedirectStubProtocol.requested)")
        XCTAssertGreaterThan(redPixels(drawn), 1000, "the redirecting stable URL drew no hero pixels")
    }
}
