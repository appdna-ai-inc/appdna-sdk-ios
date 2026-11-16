import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

extension SharedFixtureTests {
    // measure_badge_placement REAL: the lenient `[ContentBlock]` decode → the REAL `ContentBlockRendererView`, drawn in a
    // key window `column_width` points wide, with every entrance animation allowed to settle. The badge is found by its
    // fill (#FF00FF in the fixture) in the rendered pixels, and classified by the gaps either side of it. The control
    // in every case: the fill IS found, so a "leading" can never come from a harness that drew nothing.
    @MainActor
    func runBadgePlacement(_ f: Fixture, _ h: Harness) async {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] measure_badge_placement needs action.cases")
            return
        }
        let width = CGFloat(f.action.raw["column_width"]?.doubleValue ?? 393)
        struct Holder: Decodable {
            let content_blocks: [ContentBlock]?
            enum CodingKeys: String, CodingKey { case content_blocks }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "fixture")
            }
        }
        func measure(_ c: AnyJSON) async -> Any {
            let name = c.objectValue?["name"]?.foundation as? String ?? "?"
            guard let raw = c.objectValue?["content_blocks"]?.foundation,
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": raw]),
                  let blocks = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks, !blocks.isEmpty else {
                XCTFail("[\(f.id)] case \(name) did not decode")
                return NSNull()
            }
            let size = CGSize(width: width, height: 300)
            let view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
                // Placement rules: the flow's placement rules, as `settings.placement_rules` sets them (absent = 1).
                .environment(\.appdnaPlacementRules, Int(f.action.raw["placement_rules"]?.doubleValue ?? 1))
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.white)
                // An entrance animation lands at once on its end state: a captured layer shows model values, and a
                // test host has no display refresh to step a SwiftUI animation. The wrapper is still in the tree,
                // which is what the placement depends on.
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            // Yield the main actor (a run-loop spin inside this async test cannot run main-queue work, and an entrance
            // animation starts from a main-queue block), then let layout settle.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
            guard let cg = image.cgImage else {
                XCTFail("[\(f.id)] case \(name): nothing rendered")
                return NSNull()
            }
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            _ = px.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var minX = Int.max, maxX = -1
            for y in 0..<cg.height { for x in 0..<cg.width {
                let i = y * cg.width * 4 + x * 4
                if px[i] > 240, px[i + 1] < 20, px[i + 2] > 240 { minX = min(minX, x); maxX = max(maxX, x) }
            } }
            guard maxX >= 0 else {
                XCTFail("[\(f.id)] case \(name): control failed — the badge's fill was not found in the render")
                return NSNull()
            }
            let scale = CGFloat(cg.width) / size.width
            let left = CGFloat(minX) / scale, right = size.width - CGFloat(maxX + 1) / scale
            NSLog("[badge-placement] \(name) left=\(left) right=\(right)")
            if abs(left - right) <= 4 { return "center" }
            return left < right ? "leading" : "trailing"
        }

        var results: [Any] = []
        for c in cases { results.append(await measure(c)) }
        h.state["results"] = results
    }
}
