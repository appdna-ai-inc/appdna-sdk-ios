// TextInputBorderRenderTests.swift
//
// A text input strokes `error_border_color` while it is in error, over the focused and resting colours. The REAL
// `FormInputTextBlock` is drawn in a key window and its pixels read. Nothing on a step puts it in error yet (remote validation, when it
// ships, is the first state that will), so the error state is set here directly.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class TextInputBorderRenderTests: XCTestCase {
    private func block() throws -> ContentBlock {
        let json = ##"{"id":"name","type":"input_text","field_id":"name","field_placeholder":"Name","field_style":{"border_color":"#00FF00","focused_border_color":"#0000FF","error_border_color":"#FF00FF","border_width":3}}"##
        return try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    private func counts(hasError: Bool) async throws -> (magenta: Int, green: Int) {
        let size = CGSize(width: 360, height: 120)
        let view = FormInputTextBlock(block: try block(), inputValues: .constant([:]), keyboardType: .default, hasError: hasError)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var magenta = 0, green = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = px[i], g = px[i + 1], b = px[i + 2]
            if r > 220, g < 40, b > 220 { magenta += 1 }
            if r < 40, g > 220, b < 40 { green += 1 }
        }
        return (magenta, green)
    }

    func testAFieldInErrorStrokesTheErrorBorderColour() async throws {
        let resting = try await counts(hasError: false)
        XCTAssertGreaterThan(resting.green, 500, "control: a resting field strokes its border colour")
        XCTAssertEqual(resting.magenta, 0, "control: a resting field draws no error colour")
        let error = try await counts(hasError: true)
        XCTAssertGreaterThan(error.magenta, 500, "a field in error strokes error_border_color")
        XCTAssertEqual(error.green, 0, "and not the resting colour")
    }
}
