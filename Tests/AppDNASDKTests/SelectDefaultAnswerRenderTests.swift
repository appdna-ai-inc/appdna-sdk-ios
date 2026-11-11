// SelectDefaultAnswerRenderTests.swift
//
// An author's default answer (`field_config.default_value`) on the real Select and Segmented views, rendered in a real
// key window: drawn preselected AND written as the answer when the question shows, so it is recorded as if chosen, and
// a later screen draws the option's label. A view with a default and no answer must draw exactly what a view holding
// that answer draws. The control in each test proves the harness can SEE a selection.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SelectDefaultAnswerRenderTests: XCTestCase {

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
                if block.type == .input_segmented {
                    FormInputSegmentedBlock(block: block, inputValues: $answers.values)
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

    /// How many bytes two renders differ in (an unequal size counts as every byte).
    private func differ(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return max(a.count, b.count, 1) }
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    /// Renders `block` holding `stored`; returns the drawn pixels and the answers after the view appeared.
    private func render(_ block: ContentBlock, _ stored: [String: Any]) -> ([UInt8], [String: Any]) {
        let answers = Answers(stored)
        let h = Hosted(AnyView(Field(answers: answers, block: block)))
        defer { h.close() }
        return (h.pixels(), answers.values)
    }

    private let options = #"[{"id":"a","value":"a","label":"Alpha"},{"id":"b","value":"b","label":"Bravo"},{"id":"n","value":"2","label":"Two"}]"#

    override func setUp() { super.setUp(); SelectedOptionStore.shared.resetForTesting() }

    func testASingleDefaultIsDrawnAndWrittenAsIfChosen() throws {
        let withDefault = try block(#"{"id":"s","type":"input_select","field_id":"fav","field_config":{"display_style":"list","default_value":"b"},"field_options":"# + options + "}")
        let plain = try block(#"{"id":"s","type":"input_select","field_id":"fav","field_config":{"display_style":"list"},"field_options":"# + options + "}")
        let (drawn, stored) = render(withDefault, [:])
        XCTAssertEqual(stored["fav"] as? String, "b", "the default is the stored answer")
        let picked = (SelectedOptionStore.shared.snapshot["fav"] as? [String: Any])?["label"] as? String
        XCTAssertEqual(picked, "Bravo", "recorded as a tap records it, so a later screen draws the label")
        let (answered, _) = render(plain, ["fav": "b"])
        let (empty, emptyStored) = render(plain, [:])
        XCTAssertNil(emptyStored["fav"], "control: no default writes nothing")
        XCTAssertGreaterThan(differ(answered, empty), 0, "control: the harness must see a checked row")
        XCTAssertEqual(differ(drawn, answered), 0, "a default draws exactly what the same answer draws")
    }

    func testARestoredAnswerWinsOverTheDefault() throws {
        let withDefault = try block(#"{"id":"s","type":"input_select","field_id":"fav","field_config":{"display_style":"list","default_value":"b"},"field_options":"# + options + "}")
        XCTAssertEqual(render(withDefault, ["fav": "a"]).1["fav"] as? String, "a")
    }

    func testANumberDefaultAndAMultiDefault() throws {
        let number = try block(#"{"id":"s","type":"input_select","field_id":"fav","field_config":{"display_style":"list","default_value":2},"field_options":"# + options + "}")
        XCTAssertEqual(render(number, [:]).1["fav"] as? String, "2")
        let multi = try block(#"{"id":"s","type":"input_select","field_id":"fav","field_config":{"display_style":"stacked","multi_select":true,"default_value":["b","missing","a"]},"field_options":"# + options + "}")
        XCTAssertEqual(render(multi, [:]).1["fav"] as? [String], ["b", "a"])
    }

    func testARequiredSegmentedStartsOnItsDefaultAndWithoutOneStartsEmpty() throws {
        let withDefault = try block(#"{"id":"g","type":"input_segmented","field_id":"fav","field_required":true,"field_config":{"default_value":"b"},"field_options":"# + options + "}")
        let plain = try block(#"{"id":"g","type":"input_segmented","field_id":"fav","field_required":true,"field_options":"# + options + "}")
        let (drawn, stored) = render(withDefault, [:])
        XCTAssertEqual(stored["fav"] as? String, "b")
        let (empty, emptyStored) = render(plain, [:])
        XCTAssertNil(emptyStored["fav"], "control: a required segmented question with no default starts empty")
        XCTAssertGreaterThan(differ(drawn, empty), 0, "the default segment is drawn selected")
        XCTAssertEqual(differ(drawn, render(plain, ["fav": "b"]).0), 0, "a default draws exactly what the same answer draws")
    }

    func testAnOptionalSegmentedDefaultBeatsTheFirstOption() throws {
        let seg = try block(#"{"id":"g","type":"input_segmented","field_id":"fav","field_config":{"default_value":"2"},"field_options":"# + options + "}")
        XCTAssertEqual(render(seg, [:]).1["fav"] as? String, "2")
    }
}
