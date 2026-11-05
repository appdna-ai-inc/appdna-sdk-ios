import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 DOES AN IN-APP MESSAGE DRAW ITS AUTHORED TITLE SIZE?

 `MessageRenderer` rebuilds the content to interpolate its text, and that rebuild used to leave out
 `font_family`, `title_font_size` and `body_font_size`, so every view received nil for all three and drew
 its default type — whatever the console set. The views' own font resolution was right; the value never
 reached them.

 Two LIVE renders of the same message through the REAL `MessageRenderer`, one field changed. THE CONTROL:
 the same message rendered twice is pixel-identical, so a difference is the field and not the harness.
*/
@MainActor
final class MessageTypographyRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    private func frame(_ extra: String) throws -> [UInt8] {
        let json = """
        { "name": "synthetic", "message_type": "modal",
          "content": { "title": "A synthetic title", "body": "Body copy", "cta_text": "Primary action",
                       "background_color": "#FFFFFF", "text_color": "#111111"\(extra) },
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
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

    func testAnAuthoredTitleSizeReachesTheView() throws {
        let a = try frame("")
        let b = try frame("")
        XCTAssertEqual(a, b, "THE CONTROL: the same message rendered twice differs — the harness is not deterministic")

        let large = try frame(#", "title_font_size": 40"#)
        XCTAssertNotEqual(a, large, "title_font_size 40 drew the same frame as the default — the size never reached the view")
    }

    func testAnAuthoredBodySizeReachesTheView() throws {
        let a = try frame("")
        let large = try frame(#", "body_font_size": 30"#)
        XCTAssertNotEqual(a, large, "body_font_size 30 drew the same frame as the default — the size never reached the view")
    }
}
