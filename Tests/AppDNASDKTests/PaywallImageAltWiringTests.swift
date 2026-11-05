import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 The real paywall image section publishes its Alt Text to the accessibility tree: what VoiceOver is
 handed, read through the `HostedStep` harness (`PaywallRenderer` itself exposes only its close button to
 this harness, so the section is hosted directly). The shared fixture pins the label; this pins that the
 section applies it. THE CONTROL: a sibling label is readable either way, and without alt the text is absent.
*/
@MainActor
final class PaywallImageAltWiringTests: XCTestCase {
    private func labels(alt: String?) throws -> [String] {
        let altJSON = alt.map { #", "alt": "\#($0)""# } ?? ""
        let json = """
        { "id": "pw_alt", "layout": { "type": "stack", "sections": [
          { "type": "image", "config": { "image_url": "https://cdn.example.invalid/hero.png"\(altJSON) } }
        ] } }
        """
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        let section = try XCTUnwrap(config.sections.first { $0.type == "image" })
        let hosted = HostedStep(VStack {
            Text("Sibling label")
            PaywallImageSectionView(data: section.data, style: section.style)
        })
        defer { hosted.close() }
        hosted.spin(0.5)
        return hosted.labels()
    }

    func testTheAuthoredAltReachesTheAccessibilityTree() throws {
        let alt = "A runner crossing a finish line"
        let with = try labels(alt: alt)
        XCTAssertTrue(with.contains(alt), "labels: \(with)")
        let without = try labels(alt: nil)
        XCTAssertFalse(without.contains(alt))
        XCTAssertTrue(without.contains("Sibling label"), "control: this harness reads labels: \(without)")
    }
}
