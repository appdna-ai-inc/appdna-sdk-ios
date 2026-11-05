// SharedFixtureDrivers+PaywallImageAlt.swift
//
//   resolve_paywall_image_alt  REAL: `PaywallConfig` decoding of a paywall with one image section →
//                              `PaywallImageAccessibility.label(_:)`, the value `imageSectionView` hands
//                              VoiceOver as the image's `.accessibilityLabel`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    func runPaywallImageAlt(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_image_alt needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let config = obj["config"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] case \(name): needs config")
                return NSNull()
            }
            let paywall: [String: Any] = [
                "id": "pw_alt_\(name)",
                "layout": ["type": "stack", "sections": [["id": "s1", "type": "image", "config": config]]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: paywall) else {
                XCTFail("[\(f.id)] case \(name): not serialisable")
                return NSNull()
            }
            let decoded: PaywallConfig
            do {
                decoded = try JSONDecoder().decode(PaywallConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode: \(error)")
                return NSNull()
            }
            guard let section = decoded.sections.first(where: { $0.type == "image" }) else {
                XCTFail("[\(f.id)] case \(name): the image section was dropped")
                return NSNull()
            }
            return PaywallImageAccessibility.label(section.data).map { $0 as Any } ?? NSNull()
        }
    }
}
