// SelectionResyncRenderTests.swift
//
// When a Select's or a chips field's stored value changes from OUTSIDE the view (a host's
// `inputValuePatches`), the view draws what the field now holds. The real views are rendered in a real
// key window. After an outside change to X, the view must draw exactly what a fresh view whose stored
// value is X draws.
//
// Two renders are compared rather than the view's private state, because the state is the view's own.
// The negative control in each test proves the harness can SEE a selection: a fresh view holding the
// earlier pick must draw differently from one holding X.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SelectionResyncRenderTests: XCTestCase {

    /// The step's answers, as the step holds them; the test writes to it from outside the view.
    @MainActor
    private final class Answers: ObservableObject {
        @Published var values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }
    }

    private struct Field: View {
        @ObservedObject var answers: Answers
        let block: ContentBlock
        var body: some View {
            Group {
                if block.type == .input_chips {
                    FormInputChipsBlock(block: block, inputValues: $answers.values)
                } else {
                    FormInputSelectBlock(block: block, inputValues: $answers.values)
                }
            }
            .padding(16)
            .frame(width: 360, alignment: .topLeading)
            .background(Color.white)
        }
    }

    @MainActor
    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow

        static let size = CGSize(width: 393, height: 400)

        init(_ view: AnyView) {
            host = UIHostingController(rootView: AnyView(view.environment(\.colorScheme, .light)))
            host.overrideUserInterfaceStyle = .light
            host.view.bounds = CGRect(origin: .zero, size: Self.size)
            window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spin(0.8)
        }

        func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

        /// The RGBA bytes the live host draws now.
        func pixels() -> [UInt8] {
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { ctx in
                host.view.layer.render(in: ctx.cgContext)
            }
            guard let cg = image.cgImage else { return [] }
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return px
        }

        func close() { window.isHidden = true }
    }

    private func block(_ json: String) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    /// What a fresh view draws for `stored`.
    private func fresh(_ block: ContentBlock, _ stored: [String: Any]) -> [UInt8] {
        let h = Hosted(AnyView(Field(answers: Answers(stored), block: block)))
        defer { h.close() }
        return h.pixels()
    }

    /// What a view that first held `before` draws after `after` is written into the field from outside.
    private func patched(_ block: ContentBlock, from before: [String: Any], field: String, to after: Any) -> [UInt8] {
        let answers = Answers(before)
        let h = Hosted(AnyView(Field(answers: answers, block: block)))
        defer { h.close() }
        answers.values[field] = after
        h.spin(0.8)
        return h.pixels()
    }

    /// How many bytes two renders differ in (an unequal size counts as every byte).
    private func differ(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return max(a.count, b.count, 1) }
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    private let options = #"[{"id":"a","value":"a","label":"Alpha"},{"id":"b","value":"b","label":"Bravo"}]"#

    func testSingleSelectPatchedWithANumberDrawsNoRowChecked() throws {
        let select = try block(#"{"id":"s","type":"input_select","field_id":"plan","field_config":{"display_style":"list"},"field_options":"# + options + "}")
        let freshPicked = fresh(select, ["plan": "a"])
        let freshNumber = fresh(select, ["plan": 2])
        XCTAssertGreaterThan(differ(freshPicked, freshNumber), 0, "control: the harness must see a checked row")
        let afterPatch = patched(select, from: ["plan": "a"], field: "plan", to: 2)
        XCTAssertEqual(differ(afterPatch, freshNumber), 0, "a Select patched with 2 must draw no row checked, as a fresh one holding 2 does")
    }

    func testChipsPatchedWithANumberListDrawNoChip() throws {
        let chips = try block(#"{"id":"c","type":"input_chips","field_id":"tags","field_options":"# + options + "}")
        let freshPicked = fresh(chips, ["tags": ["a"]])
        let freshNumbers = fresh(chips, ["tags": [1]])
        XCTAssertGreaterThan(differ(freshPicked, freshNumbers), 0, "control: the harness must see a selected chip")
        XCTAssertEqual(differ(patched(chips, from: ["tags": ["a"]], field: "tags", to: [1]), freshNumbers), 0,
                       "chips patched with [1] must draw no chip, as fresh ones holding [1] do")
    }

    func testChipsPatchedWithAMixedListDrawNoChip() throws {
        let chips = try block(#"{"id":"c","type":"input_chips","field_id":"tags","field_options":"# + options + "}")
        let freshNone = fresh(chips, [:])
        XCTAssertGreaterThan(differ(fresh(chips, ["tags": ["b"]]), freshNone), 0, "control: the harness must see a selected chip")
        // A mixed list is no selection: it draws as nothing selected does.
        XCTAssertEqual(differ(fresh(chips, ["tags": ["a", 2] as [Any]]), freshNone), 0)
        XCTAssertEqual(differ(patched(chips, from: ["tags": ["b"]], field: "tags", to: ["a", 2] as [Any]), freshNone), 0,
                       "chips patched with [\"a\", 2] must draw no chip")
    }
}
