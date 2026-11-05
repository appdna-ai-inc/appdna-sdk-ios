// SharedFixtureDrivers+PaywallImageAlt.swift
//
//   resolve_paywall_image_alt  REAL: `PaywallConfig` decoding of a paywall with one image section →
//                              `PaywallImageAccessibility.label(_:)`, the value `imageSectionView` hands
//                              VoiceOver as the image's `.accessibilityLabel`.
//   resolve_onboarding_image_alt REAL: the lenient `[ContentBlock]` decode a step runs →
//                              `ContentBlock.imageAccessibilityLabel`, the label every image branch of
//                              `ContentBlockRendererView` uses.
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

    func runOnboardingImageAlt(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_onboarding_image_alt needs action.cases")
            return
        }
        struct Holder: Decodable {
            let content_blocks: [ContentBlock]?
            enum CodingKeys: String, CodingKey { case content_blocks }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "fixture")
            }
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let block = obj["block"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [block]]),
                  let holder = try? JSONDecoder().decode(Holder.self, from: data),
                  let decoded = holder.content_blocks?.first else {
                XCTFail("[\(f.id)] case \(name): the block did not decode")
                return NSNull()
            }
            return decoded.imageAccessibilityLabel
        }
    }

    // resolve_container_children REAL: the lenient `[ContentBlock]` decode → `OnboardingStepPipeline.visibleChildren`,
    // the filter `containerChildren` (multi-buttons, row, stack, carousel) applies.
    func runContainerChildren(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_container_children needs action.cases")
            return
        }
        struct Holder: Decodable {
            let content_blocks: [ContentBlock]?
            enum CodingKeys: String, CodingKey { case content_blocks }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "fixture")
            }
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            let ids = Set((obj["raw_resolved_ids"]?.arrayValue ?? []).compactMap(\.stringValue))
            guard let container = obj["container"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [container]]),
                  let block = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks?.first else {
                XCTFail("[\(f.id)] case \(name): the container did not decode")
                return NSNull()
            }
            // The raw pass writes the marker after decoding; do the same.
            let markers = obj["empty_state_markers"]?.objectValue ?? [:]
            var marked = block
            func mark(_ list: [ContentBlock]?) -> [ContentBlock]? {
                list?.map { child in
                    guard let es = markers[child.id]?.foundation else { return child }
                    var c = child
                    var fc = c.field_config ?? [:]
                    fc["empty_state"] = AnyCodable(es)
                    c.field_config = fc
                    return c
                }
            }
            marked.children = mark(block.children)
            marked.stack_children = mark(block.stack_children)
            return OnboardingStepPipeline.visibleChildren(of: marked, isRawResolved: { ids.contains($0.id) }).map(\.id)
        }
    }
}
