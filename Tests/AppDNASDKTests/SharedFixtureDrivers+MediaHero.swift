// Shared-fixture drivers for animation and video media.
//
//   resolve_paywall_media_section  REAL: `PaywallConfig` decoding of a paywall with one lottie / video section →
//                                  `PaywallMediaSection.lottieBlock` / `videoBlock`, the block `PaywallRenderer` draws.
//   resolve_message_hero_media     REAL: `MessageConfig` decoding → `MessageContent.resolved(for: .light)` →
//                                  `MessageHeroMedia.of`, the hero ModalView / FullscreenView draw.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    func runPaywallMediaSection(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_media_section needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let type = obj["type"]?.stringValue, let config = obj["config"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] case \(name): needs type and config")
                return NSNull()
            }
            let paywall: [String: Any] = [
                "id": "pw_media_\(name)",
                "layout": ["type": "stack", "sections": [["id": "s1", "type": type, "config": config]]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: paywall),
                  let decoded = try? JSONDecoder().decode(PaywallConfig.self, from: data),
                  let section = decoded.sections.first(where: { $0.type == type }) else {
                XCTFail("[\(f.id)] case \(name): the paywall or its section did not decode")
                return NSNull()
            }
            if type == "lottie" {
                guard let b = PaywallMediaSection.lottieBlock(section.data) else { return NSNull() }
                return ["url": b.lottie_url ?? "", "loop": b.loop, "speed": b.speed, "height": b.height] as [String: Any]
            }
            guard let b = PaywallMediaSection.videoBlock(section.data) else { return NSNull() }
            return [
                "url": b.video_url, "autoplay": b.autoplay ?? false, "loop": b.loop ?? false, "muted": b.muted ?? true,
                "controls": b.controls ?? true, "height": b.video_height,
                "thumbnail": SharedFixtureTests.orNull(b.video_thumbnail_url),
            ] as [String: Any]
        }
    }

    func runMessageHeroMedia(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_message_hero_media needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let content = obj["content"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] case \(name): needs content")
                return NSNull()
            }
            let message: [String: Any] = ["name": name, "message_type": "modal", "content": content]
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let decoded = try? JSONDecoder().decode(MessageConfig.self, from: data),
                  let decodedContent = decoded.content else {
                XCTFail("[\(f.id)] case \(name): the message did not decode")
                return NSNull()
            }
            guard let hero = MessageHeroMedia.of(decodedContent.resolved(for: .light)) else { return NSNull() }
            return ["kind": hero.kind, "url": hero.url] as [String: Any]
        }
    }
}
