// CustomViewFallbackRenderTests.swift
//
// #1501 — an UNREGISTERED custom_view never draws its debug key to an end user.
//
// It drew the literal `[view_key]` whenever the block carried no `placeholder_text`. Rendered through the real
// `ContentBlockRendererView` on a white step and the non-white pixels counted:
//   - release build (CustomViewFallback.debugOverride = false), nothing authored → NO ink;
//   - CONTROLS on the same harness: the debug build draws the key, and an authored `placeholder_text` draws in
//     release — so "no ink" is the block collapsing, not a harness that cannot see text.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class CustomViewFallbackRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 200)

    override func tearDown() {
        CustomViewFallback.debugOverride = nil
        super.tearDown()
    }

    /// Non-white pixels drawn by one custom_view block (synthetic key; nothing registers it).
    private func ink(placeholderText: String?, debug: Bool) throws -> Int {
        CustomViewFallback.debugOverride = debug
        let text = placeholderText.map { #", "placeholder_text": "\#($0)""# } ?? ""
        let json = #"[{ "id": "cv", "type": "custom_view", "view_key": "probe_unregistered_chart"\#(text) }]"#
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let host = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16)
            .frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.colorScheme, .light))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 230 || px[i + 1] < 230 || px[i + 2] < 230 { n += 1 }
        return n
    }

    func testAReleaseBuildDrawsNothingForAnUnregisteredViewWithNoFallback() throws {
        let debugKey = try ink(placeholderText: nil, debug: true)
        let authored = try ink(placeholderText: "Chart unavailable", debug: false)
        let release = try ink(placeholderText: nil, debug: false)
        NSLog("[custom-view-fallback] debugKey=\(debugKey) authored=\(authored) release=\(release)")
        XCTAssertGreaterThan(debugKey, 50, "harness control: the debug build's [view_key] is drawn and seen")
        XCTAssertGreaterThan(authored, 50, "harness control: an authored placeholder_text is drawn in release")
        XCTAssertEqual(release, 0, "a release build drew ink for an unregistered custom_view with nothing authored ([view_key] leaked)")
    }
}
