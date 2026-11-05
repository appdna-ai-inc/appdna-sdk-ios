import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 DOES THE MESSAGE DRAW ITS CLOSE CONTROL WHEN, AND ONLY WHEN, THE AUTHOR ALLOWS DISMISSAL?

 The shared fixture `message_dismiss_policy` pins the rule. This is the other half: the REAL
 `MessageRenderer`, given a message decoded from the JSON the server publishes, laid out in a real key
 window and its pixels read — the harness `SurfaceSnapshotTests` and `PaywallFailureBannerRenderTests`
 established (there is no iOS tap verb on the build machine, so the render is the instrument).

 Two LIVE renders of the same message with one field changed, not a golden:
 - allowed vs not allowed must DIFFER, and only inside a small box (the ✕ — `dismiss_text` is unset),
   on every message type;
 - THE CONTROL: the same message rendered twice must be pixel-identical, so a difference cannot come
   from a harness that never draws the same frame twice;
 - a `dismiss_delay` render must match "not allowed" before the delay and "allowed" after it.

 What this does NOT operate: a tap on the backdrop. The gate on it is the same `dismissUnlocked` this
 test reads through the ✕; the tap itself is the owner's device walk (a device walk).
*/
@MainActor
final class MessageDismissRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    private func config(_ type: String, _ extra: String) throws -> MessageConfig {
        let json = """
        { "name": "synthetic", "message_type": "\(type)",
          "content": { "title": "A synthetic title", "body": "Body copy", "cta_text": "Primary action",
                       "background_color": "#FFFFFF", "text_color": "#111111"\(extra) },
          "trigger_rules": { "event": "e" } }
        """
        return try JSONDecoder().decode(MessageConfig.self, from: Data(json.utf8))
    }

    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        init(host: UIHostingController<AnyView>, window: UIWindow) { self.host = host; self.window = window }
    }

    private func present(_ config: MessageConfig) -> Hosted {
        let view = AnyView(
            MessageRenderer(messageId: "m", config: config, onCTATap: {}, onDismiss: {})
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
        )
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return Hosted(host: host, window: window)
    }

    private func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func pixels(_ h: Hosted) throws -> (bytes: [UInt8], w: Int, h: Int, scale: CGFloat) {
        let image = UIGraphicsImageRenderer(size: size).image { ctx in h.host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, hh = cg.height
        var bytes = [UInt8](repeating: 0, count: w * hh * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hh))
            return true
        }
        XCTAssertTrue(ok, "could not read the rendered pixels")
        return (bytes, w, hh, image.scale)
    }

    /// The box (in points) of pixels that differ between two frames, or nil when they are identical.
    private func diffBox(_ a: (bytes: [UInt8], w: Int, h: Int, scale: CGFloat),
                         _ b: (bytes: [UInt8], w: Int, h: Int, scale: CGFloat)) -> CGRect? {
        XCTAssertEqual(a.w, b.w); XCTAssertEqual(a.h, b.h)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<a.h {
            for x in 0..<a.w {
                let i = (y * a.w + x) * 4
                if abs(Int(a.bytes[i]) - Int(b.bytes[i])) > 8
                    || abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])) > 8
                    || abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])) > 8 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard minX != Int.max else { return nil }
        let s = a.scale
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    private func render(_ type: String, _ extra: String, settle: TimeInterval = 1.0) throws -> (bytes: [UInt8], w: Int, h: Int, scale: CGFloat) {
        let h = present(try config(type, extra))
        wait(settle)
        defer { h.window.isHidden = true }
        return try pixels(h)
    }

    func testNotDismissableHidesTheCloseControlOnEveryType() throws {
        for type in ["modal", "fullscreen", "banner", "tooltip"] {
            let allowedA = try render(type, #", "dismiss_allowed": true"#)
            let allowedB = try render(type, #", "dismiss_allowed": true"#)
            XCTAssertNil(diffBox(allowedA, allowedB), "[\(type)] THE CONTROL: the same message rendered twice differs — the harness is not deterministic")

            let blocked = try render(type, #", "dismiss_allowed": false"#)
            let box = diffBox(allowedA, blocked)
            NSLog("[message-dismiss] \(type): allowed vs not-allowed differ in \(box.map { "\($0)" } ?? "nothing")")
            let b = try XCTUnwrap(box, "[\(type)] 'not dismissable' drew the same frame as 'dismissable' — the ✕ was not hidden")
            XCTAssertLessThan(b.width, 60, "[\(type)] more than the ✕ changed: \(b)")
            XCTAssertLessThan(b.height, 60, "[\(type)] more than the ✕ changed: \(b)")
        }
    }

    func testADismissDelayShowsTheCloseControlOnlyAfterIt() throws {
        let allowed = try render("modal", #", "dismiss_allowed": true"#)
        let blocked = try render("modal", #", "dismiss_allowed": false"#)
        XCTAssertNotNil(diffBox(allowed, blocked), "control: the ✕ is visible in this harness at all")

        let h = present(try config("modal", #", "dismiss_allowed": true, "dismiss_delay": 2"#))
        defer { h.window.isHidden = true }
        wait(0.8)
        let early = try pixels(h)
        XCTAssertNil(diffBox(early, blocked), "inside the delay the ✕ is drawn: \(String(describing: diffBox(early, blocked)))")
        wait(2.0) // 2.8 s
        let late = try pixels(h)
        XCTAssertNil(diffBox(late, allowed), "after the delay the frame should be the dismissable one: \(String(describing: diffBox(late, allowed)))")
    }

    func testAbsentFieldsKeepTheCloseControl() throws {
        let absent = try render("modal", "")
        let allowed = try render("modal", #", "dismiss_allowed": true"#)
        XCTAssertNil(diffBox(absent, allowed), "a message without the fields must draw as it did before these fields were read")
    }
}
