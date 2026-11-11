import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 What VoiceOver is handed for an authored image, read off the REAL views' accessibility tree (the `HostedStep`
 harness, with accessibility automation on): a described image is one element read as its description with the
 image trait; an image whose description is blank is DECORATIVE and absent from the tree.

 The image is DRAWN, not loading: its bytes are put in the shared URLCache first, which `BundledAsyncPhaseImage`
 reads synchronously — so the drawn branch (the one a user hears) is what is asserted.

 THE CONTROLS, in every case: a sibling text is read (this harness sees labels at all), and the described twin of
 each decorative image IS found (this harness can see that image when it is exposed).
*/
@MainActor
final class AuthoredImageAccessibilityRenderTests: XCTestCase {
    private let imageURL = "https://cdn.example.invalid/authored-image-a11y.png"
    private let described = "A synthetic river valley under a clear sky"

    override func setUp() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let url = URL(string: imageURL)!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: png), for: URLRequest(url: url))
    }

    private struct Seen {
        let labels: [String]
        let imageElements: [String]   // the label of every element carrying the image trait ("" when unlabelled)
    }

    private func read<V: View>(_ view: V) -> Seen {
        let hosted = HostedStep(VStack {
            Text("Sibling label")
            view
        })
        defer { hosted.close() }
        hosted.spin(0.5)
        let els = hosted.elements()
        return Seen(
            labels: els.compactMap(\.accessibilityLabel),
            imageElements: els.filter { $0.isAccessibilityElement && $0.accessibilityTraits.contains(.image) }
                .map { $0.accessibilityLabel ?? "" }
        )
    }

    private func assertDescribed(_ s: Seen, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.imageElements, [described], "described image elements: \(s.imageElements); labels: \(s.labels)", file: file, line: line)
        XCTAssertTrue(s.labels.contains("Sibling label"), "control: this harness reads labels: \(s.labels)", file: file, line: line)
    }

    private func assertDecorative(_ s: Seen, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.imageElements, [], "a decorative image must not be in the tree: \(s.imageElements); labels: \(s.labels)", file: file, line: line)
        XCTAssertFalse(s.labels.contains("Image"), "a decorative image is not announced as \"Image\": \(s.labels)", file: file, line: line)
        XCTAssertTrue(s.labels.contains("Sibling label"), "control: this harness reads labels: \(s.labels)", file: file, line: line)
    }

    // MARK: onboarding image block (plain, framed and phone mockup)

    private func onboarding(alt: String?, frame: String? = nil, type: String = "image") throws -> Seen {
        var raw: [String: Any] = ["id": "img", "type": type, "image_url": imageURL, "height": 120]
        if let alt { raw["alt"] = alt }
        if let frame { raw["image_frame"] = frame }
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return read(ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:])))
    }

    func testOnboardingImageWithAltIsReadAsItsDescription() throws {
        assertDescribed(try onboarding(alt: described))
        assertDescribed(try onboarding(alt: described, frame: "color_frame"))
        assertDescribed(try onboarding(alt: described, frame: "phone"))
    }

    func testOnboardingImageWithBlankAltIsSkipped() throws {
        assertDecorative(try onboarding(alt: "   "))
        assertDecorative(try onboarding(alt: ""))
        assertDecorative(try onboarding(alt: nil))
        assertDecorative(try onboarding(alt: "", frame: "color_frame"))
        assertDecorative(try onboarding(alt: "", frame: "phone"))
    }

    func testOnboardingAnimatedImageFollowsTheSameRule() throws {
        assertDescribed(try onboarding(alt: described, type: "animated_image"))
        assertDecorative(try onboarding(alt: "  ", type: "animated_image"))
    }

    // MARK: paywall image section

    private func paywall(alt: String?) throws -> Seen {
        let altJSON = alt.map { #", "alt": "\#($0)""# } ?? ""
        let json = """
        { "id": "pw_alt", "layout": { "type": "stack", "sections": [
          { "type": "image", "config": { "image_url": "\(imageURL)", "height": 120\(altJSON) } }
        ] } }
        """
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        let section = try XCTUnwrap(config.sections.first { $0.type == "image" })
        return read(PaywallImageSectionView(data: section.data, style: section.style))
    }

    func testPaywallImageSection() throws {
        assertDescribed(try paywall(alt: described))
        assertDecorative(try paywall(alt: "  "))
        assertDecorative(try paywall(alt: nil))
    }

    // MARK: screen image section

    private func screen(alt: String?) throws -> Seen {
        var data: [String: Any] = ["image_url": imageURL, "height": 120]
        if let alt { data["alt"] = alt }
        let json = try JSONSerialization.data(withJSONObject: ["id": "scr", "sections": [["id": "s1", "type": "image_section", "data": data]]])
        let screen = try JSONDecoder().decode(ScreenConfig.self, from: json)
        let section = try XCTUnwrap(screen.sections?.first)
        return read(ImageSectionRenderer.render(section: section, context: SectionContext(screenId: "scr", onAction: { _ in })))
    }

    func testScreenImageSection() throws {
        assertDescribed(try screen(alt: described))
        assertDecorative(try screen(alt: " "))
        assertDecorative(try screen(alt: nil))
    }

    // MARK: in-app message image (no description field: always decorative)

    func testInAppModalImageIsSkipped() throws {
        let json = #"{ "title": "A synthetic title", "body": "A synthetic body", "image_url": "\#(imageURL)" }"#
        let content = try JSONDecoder().decode(MessageContent.self, from: Data(json.utf8))
        let s = read(ModalView(content: content, onCTATap: {}, onDismiss: {}))
        assertDecorative(s)
        XCTAssertTrue(s.labels.contains("A synthetic title"), "control: the message itself is read: \(s.labels)")
    }
}
