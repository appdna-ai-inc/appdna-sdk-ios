// SharedFixtureDrivers+Messages.swift
//
// iOS drivers for the in-app message fixture kinds. Dispatched from `SharedFixtureTests.drive`'s
// default branch. Every value asserted is produced by a REAL SDK symbol:
//
//   decode_message_cta   REAL: `MessageConfig` decoding (the same `JSONDecoder` decode the config and
//                        pending-message paths run) → `content.cta_action`, and `CTAAction.linkToOpen`,
//                        the link both tap handlers (`MessageManager`, `PendingMessageListener`) open.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    @MainActor
    func driveMessageFixtures(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "decode_message_cta": runDecodeMessageCta(f, h)
        default: return false
        }
        return true
    }

    // MARK: decode_message_cta

    /**
     A whole message is decoded, not a bare `CTAAction`: a CTA the decoder cannot read used to fail the
     ENCLOSING `MessageContent` (a bare-string `cta_action` dropped the message), and only decoding the
     message shows that.
     */
    private func runDecodeMessageCta(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] decode_message_cta needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            var content: [String: Any] = ["title": "t", "cta_text": "Open"]
            if let raw = obj["cta_action"] { content["cta_action"] = raw.foundation }
            let message: [String: Any] = ["name": name, "message_type": "modal", "content": content]
            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                XCTFail("[\(f.id)] case \(name): not serialisable")
                return NSNull()
            }
            let decoded: MessageConfig
            do {
                decoded = try JSONDecoder().decode(MessageConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the message did not decode: \(error)")
                return NSNull()
            }
            guard let cta = decoded.content?.cta_action else { return NSNull() }
            return [
                // A missing type is reported as the tap handlers' analytics report it.
                "type": cta.type?.rawValue ?? "dismiss",
                "url": SharedFixtureTests.orNull(cta.url),
                "opens": SharedFixtureTests.orNull(cta.linkToOpen),
            ] as [String: Any]
        }
    }
}
