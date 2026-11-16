import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

extension SharedFixtureTests {
    // measure_block_placement REAL, under BOTH placement rules: the lenient `[ContentBlock]` decode → the
    // REAL `ContentBlockRendererView` with `appdnaPlacementRules` set as a flow's `settings.placement_rules` sets it, drawn
    // in a key window `column_width` points wide. The target's own frame is found by its #FF00FF block background in the
    // rendered pixels and classified by `placementClass` (the classification every runner uses). Every case is printed
    // (`r1` / `r2`). A case with `expect` is asserted (`rules_1.ios`, and `rules_2` unless `rules_2_on.ios` names this
    // surface's reason); the authored-alignment controls are asserted in both modes, so a harness that measured the
    // wrong thing cannot pass them.
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
        var asserted = 0
        var failures: [String] = []
        func expected(_ o: [String: AnyJSON], _ rules: Int) -> String? {
            guard let e = o["expect"]?.objectValue else { return nil }
            if rules == 1 { return e["rules_1"]?.objectValue?["ios"]?.stringValue }
            return e["rules_2_on"]?.objectValue?["ios"]?.stringValue ?? e["rules_2"]?.stringValue
        }
        for c in cases { for rules in [1, 2] {
            let o = c.objectValue ?? [:]
            let name = o["name"]?.stringValue ?? "?"
            let nudge = CGFloat(o["nudge"]?.doubleValue ?? 0)
            func check(_ result: String, _ detail: String) {
                if let want = expected(o, rules) {
                    asserted += 1
                    if want != result { failures.append("r\(rules) \(name) expected=\(want) got=\(result) \(detail)") }
                }
            }
            guard let raw = o["content_blocks"]?.foundation,
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": raw]),
                  let blocks = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks, !blocks.isEmpty else {
                NSLog("[block-placement] r\(rules) \(name) undecodable")
                check("undecodable", "")
                results.append(["name": name, "rules": rules, "result": "undecodable"])
                continue
            }
            let size = CGSize(width: width, height: 600)
            let view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
                .environment(\.appdnaPlacementRules, rules)
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
            guard let cg = image.cgImage else { check("unmeasured", ""); results.append(["name": name, "rules": rules, "result": "unmeasured"]); continue }
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
                result = placementClass(left: left, right: right, width: w, column: size.width, nudge: nudge)
            }
            NSLog("[block-placement] r\(rules) \(name) \(result) \(detail)")
            check(result, detail)
            if let control = o["control"]?.stringValue {
                if o["control_strict"]?.boolValue == true, result != "unmeasured" {
                    controlsSeen += 1
                    XCTAssertEqual(result, control, "[\(f.id)] control \(name) (rules \(rules)): an authored alignment must read \(control)")
                } else if result != control {
                    NSLog("[block-placement] CONTROL-MISMATCH r\(rules) \(name) expected=\(control) got=\(result)")
                }
            }
            results.append(["name": name, "rules": rules, "result": result])
        } }
        for f in failures { NSLog("[block-placement] FAIL \(f)") }
        NSLog("[block-placement] SUMMARY ios asserted=\(asserted) failures=\(failures.count) controls=\(controlsSeen)")
        XCTAssertTrue(failures.isEmpty, "[\(f.id)] \(failures.count) case(s) placed differently from the fixture: \(failures.prefix(12))")
        XCTAssertGreaterThanOrEqual(controlsSeen, 6, "[\(f.id)] control: at least six authored-alignment controls were measured and read as authored")
        h.state["results"] = results
    }
}

/// Placement rules: the one classification every placement runner uses (iOS, Android, the preview). `nudge` is the target's
/// authored `horizontal_offset`: the block is placed by the rule and then moved by it.
func placementClass(left: CGFloat, right: CGFloat, width: CGFloat, column: CGFloat, nudge: CGFloat) -> String {
    if width <= 0 { return "unmeasured" }
    if width >= column - 4 - abs(nudge) { return "fill" }
    let l = left - nudge, r = right + nudge
    if abs(l - r) <= 4 { return "center" }
    return l < r ? "leading" : "trailing"
}
