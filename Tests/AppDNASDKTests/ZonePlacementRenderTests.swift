import XCTest
import SwiftUI
@testable import AppDNASDK

/// Where a step's top zone puts its blocks when EVERY block in it hugs its content (a badge and an `auto` button, no
/// full-width sibling), drawn by the REAL `ThreeZoneStepLayout` in a 393-point key window and measured by the pixels
/// of the magenta badge.
///
/// The zone's column is framed full width; under placement rules 1 (a flow published before the flow carried
/// `settings.placement_rules`) that frame starts its content at the leading edge, as it always has. Under rules 2 an
/// unaligned block narrower than its row is centred, so the zone centres the pair, as it does any narrow block that
/// has a full-width sibling.
///
/// RED CONTROLS: the same badge authored `horizontal_align: left` must read leading under rules 2 (a probe that only
/// ever reports "center" cannot pass), and the rules-1 case must read leading (a zone frame that ignores the flow's
/// rules cannot pass both).
@MainActor
final class ZonePlacementRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 700)

    private func blocks(_ badgeExtra: String = "") -> [ContentBlock] {
        let json = """
        [{"id":"b","type":"badge","badge_text":"Narrow badge","badge_bg_color":"#FF00FF","badge_text_color":"#FFFFFF"\(badgeExtra)},
         {"id":"k","type":"button","text":"Auto","action":"none","element_width":"auto"}]
        """
        return try! JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
    }

    /// The magenta pixels' left and right gaps, in points.
    private func measure(_ blocks: [ContentBlock], rules: Int) -> (left: CGFloat, right: CGFloat)? {
        let view = ThreeZoneStepLayout(
            blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:])
        )
        .environment(\.appdnaPlacementRules, rules)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        window.isHidden = true
        guard let cg = image.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var minX = Int.max, maxX = -1
        for y in 0..<cg.height { for x in 0..<cg.width {
            let i = (y * cg.width + x) * 4
            if px[i] > 240, px[i + 1] < 20, px[i + 2] > 240 { minX = min(minX, x); maxX = max(maxX, x) }
        } }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(cg.width) / size.width
        return (CGFloat(minX) / scale, size.width - CGFloat(maxX + 1) / scale)
    }

    private func place(_ g: (left: CGFloat, right: CGFloat)) -> String {
        abs(g.left - g.right) <= 4 ? "center" : (g.left < g.right ? "leading" : "trailing")
    }

    func testAnAllHuggingTopZoneIsLeadingUnderRules1AndCentredUnderRules2() throws {
        let r1 = try XCTUnwrap(measure(blocks(), rules: 1), "rules 1: the magenta badge was not found in the pixels")
        let r2 = try XCTUnwrap(measure(blocks(), rules: 2), "rules 2: the magenta badge was not found in the pixels")
        NSLog("[zone-placement] rules1 left=%.1f right=%.1f rules2 left=%.1f right=%.1f", r1.left, r1.right, r2.left, r2.right)
        XCTAssertEqual(place(r1), "leading", "a flow published before the stamp keeps the leading edge the zone always had")
        XCTAssertEqual(place(r2), "center", "under rules 2 an all-hugging zone is centred, as every narrow block is")
    }

    func testControlAnAuthoredLeftBadgeStaysLeadingUnderRules2() throws {
        let g = try XCTUnwrap(measure(blocks(#","horizontal_align":"left""#), rules: 2))
        NSLog("[zone-placement] control left=%.1f right=%.1f", g.left, g.right)
        XCTAssertEqual(place(g), "leading", "an authored alignment wins over the rule")
    }
}
