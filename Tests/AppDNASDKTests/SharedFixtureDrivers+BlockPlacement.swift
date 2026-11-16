import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

extension SharedFixtureTests {
    // measure_block_placement REAL (record mode): the lenient `[ContentBlock]` decode → the REAL
    // `ContentBlockRendererView`, drawn in a key window `column_width` points wide. The target's own frame is found by
    // its #FF00FF block background in the rendered pixels and classified by the gaps either side of it. Every case is
    // printed; only the authored-alignment controls are asserted (their `control` value), so a harness that measured
    // the wrong thing cannot pass them.
    @MainActor
    func runBlockPlacement(_ f: Fixture, _ h: Harness) async {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] measure_block_placement needs action.cases")
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
        var results: [Any] = []
        var controlsSeen = 0
        for c in cases {
            let o = c.objectValue ?? [:]
            let name = o["name"]?.stringValue ?? "?"
            guard let raw = o["content_blocks"]?.foundation,
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": raw]),
                  let blocks = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks, !blocks.isEmpty else {
                NSLog("[block-placement] \(name) undecodable")
                results.append(["name": name, "result": "undecodable"])
                continue
            }
            let size = CGSize(width: width, height: 600)
            let view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.white)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
            window.isHidden = true
            guard let cg = image.cgImage else { results.append(["name": name, "result": "unmeasured"]); continue }
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
            let result: String
            var detail = ""
            if maxX < 0 {
                result = "unmeasured"
            } else {
                let scale = CGFloat(cg.width) / size.width
                let left = CGFloat(minX) / scale, right = size.width - CGFloat(maxX + 1) / scale, w = CGFloat(maxX - minX + 1) / scale
                detail = String(format: "left=%.1f right=%.1f width=%.1f column=%.1f", left, right, w, size.width)
                if w >= size.width - 4 { result = "fill" }
                else if abs(left - right) <= 4 { result = "center" }
                else { result = left < right ? "leading" : "trailing" }
            }
            NSLog("[block-placement] \(name) \(result) \(detail)")
            if let control = o["control"]?.stringValue {
                if o["control_strict"]?.boolValue == true, result != "unmeasured" {
                    controlsSeen += 1
                    XCTAssertEqual(result, control, "[\(f.id)] control \(name): an authored alignment must read \(control)")
                } else if result != control {
                    NSLog("[block-placement] CONTROL-MISMATCH \(name) expected=\(control) got=\(result)")
                }
            }
            results.append(["name": name, "result": result])
        }
        XCTAssertGreaterThanOrEqual(controlsSeen, 6, "[\(f.id)] control: at least six authored-alignment controls were measured and read as authored")
        h.state["results"] = results
    }
}
