import XCTest
import SwiftUI
@testable import AppDNASDK

/// a paywall page gradient follows CSS angles, as the console draws it (`linear-gradient(<angle>deg, …)`):
/// 180° runs top → bottom, 90° left → right. It used the maths convention, so 180° ran RIGHT → LEFT.
/// The page is red at its first stop and blue at its last, with no sections, so the sampled points are background only.
/// NEGATIVE CONTROL: restoring the `cos`/`sin` mapping in `pageGradientPoints` fails both render tests.
@MainActor
final class PaywallPageGradientAngleTests: XCTestCase {

    private func render(angle: Int) throws -> (Double, Double) -> Int {
        let json = """
        {"id":"pw_angle","name":"Synthetic angle paywall","layout":{"type":"stack","background":{"type":"gradient",
         "gradient":{"type":"linear","angle":\(angle),"stops":[{"color":"#FF0000","position":0},{"color":"#0000FF","position":100}]}},
         "sections":[]},"plans":[]}
        """
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        let host = UIHostingController(rootView: PaywallRenderer(config: config, onPlanSelected: { _, _ in }, onRestore: {}, onDismiss: { _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        guard let cg = image.cgImage else { throw XCTSkip("no frame") }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Red minus blue at a point given as fractions of the frame (y from the top): > 0 is the first stop's side.
        return { fx, fy in
            let x = Int(fx * Double(w - 1)), y = Int(fy * Double(h - 1))
            let i = (y * w + x) * 4
            return Int(px[i]) - Int(px[i + 2])
        }
    }

    func testA180DegreePageRunsFromTheTopToTheBottom() throws {
        let r = try render(angle: 180)
        print("[page-gradient] 180 top=\(r(0.02, 0.15)) bottom=\(r(0.02, 0.85)) left=\(r(0.1, 0.5)) right=\(r(0.9, 0.5))")
        XCTAssertGreaterThan(r(0.02, 0.15), 100, "the first stop (red) is at the top")
        XCTAssertLessThan(r(0.02, 0.85), -100, "the last stop (blue) is at the bottom")
        XCTAssertLessThan(abs(r(0.1, 0.5) - r(0.9, 0.5)), 40, "left and right of one row match")
    }

    func testA90DegreePageRunsFromTheLeftToTheRight() throws {
        let r = try render(angle: 90)
        print("[page-gradient] 90 left=\(r(0.1, 0.5)) right=\(r(0.9, 0.5)) top=\(r(0.02, 0.15)) bottom=\(r(0.02, 0.85))")
        XCTAssertGreaterThan(r(0.1, 0.5), 100, "the first stop (red) is on the left")
        XCTAssertLessThan(r(0.9, 0.5), -100, "the last stop (blue) is on the right")
    }

    func testThePointsAreTheCSSOnes() {
        func round(_ p: UnitPoint) -> [Double] { [Double(p.x), Double(p.y)].map { (($0 * 1000).rounded()) / 1000.0 } }
        let a = PaywallRenderer.pageGradientPoints(angle: 180)
        XCTAssertEqual(round(a.start), [0.5, 0]); XCTAssertEqual(round(a.end), [0.5, 1])
        let b = PaywallRenderer.pageGradientPoints(angle: 90)
        XCTAssertEqual(round(b.start), [0, 0.5]); XCTAssertEqual(round(b.end), [1, 0.5])
    }
}
