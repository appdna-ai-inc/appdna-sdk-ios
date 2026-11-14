// SharedFixtureDrivers+Messages.swift
//
// iOS drivers for the in-app message fixture kinds. Dispatched from `SharedFixtureTests.drive`'s
// default branch. Every value asserted is produced by a REAL SDK symbol:
//
//   decode_message_cta   REAL: `MessageConfig` decoding (the same `JSONDecoder` decode the config and
//                        pending-message paths run) → `content.cta_action`, and `CTAAction.linkToOpen`,
//                        the link both tap handlers (`MessageManager`, `PendingMessageListener`) open.
//   decode_message_hero  REAL: `MessageConfig` decoding → `MessageContent.resolved(for:)` (what
//                        `MessageRenderer` hands the views) → `image_url`, the field ModalView /
//                        FullscreenView draw the hero from.
//   resolve_message_dismiss REAL: `MessageConfig` decoding → `MessageDismissPolicy(content:)`, the rule
//                        all four message views gate the ✕, `dismiss_text` and the backdrop tap on
//   decode_pending_delivery REAL: `PendingMessageListener.decodeDelivery(data:now:)`, the decode the
//                        listener runs on every delivery document (expiry filter, message decode,
//                        degraded fallback).
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
        case "decode_message_hero": runDecodeMessageHero(f, h)
        case "decode_pending_delivery": runDecodePendingDelivery(f, h)
        // The ids the journey in-app message listener follows (SharedFixtureDrivers+PendingFollow.swift).
        case "follow_pending_messages": runFollowPendingMessages(f, h)
        // A config-driven message triggered with no foreground scene (SharedFixtureDrivers+HoldConfigMessages.swift).
        case "hold_config_messages": await runHoldConfigMessages(f, h)
        case "resolve_message_dismiss": runResolveMessageDismiss(f, h)
        // Paywall image alt text (driver in SharedFixtureDrivers+PaywallImageAlt.swift).
        case "resolve_paywall_image_alt": runPaywallImageAlt(f, h)
        // A paywall media section's playback and a message's animation / video hero (SharedFixtureDrivers+MediaHero.swift).
        case "resolve_paywall_media_section": runPaywallMediaSection(f, h)
        case "resolve_message_hero_media": runMessageHeroMedia(f, h)
        case "resolve_onboarding_image_alt": runOnboardingImageAlt(f, h)
        case "resolve_screen_image_alt": runScreenImageAlt(f, h)
        case "resolve_option_label_markdown": runOptionLabelMarkdown(f, h)
        case "resolve_date_wheel": runDateWheel(f, h)
        case "resolve_container_children": runContainerChildren(f, h)
        case "resolve_rating_answer": runRatingAnswer(f, h)
        case "resolve_loading_variant": runLoadingVariant(f, h)
        case "resolve_custom_view_fallback": runCustomViewFallback(f, h)
        case "resolve_warning_banner_ink": runWarningBannerInk(f, h)
        case "resolve_button_label_ink": runButtonLabelInk(f, h)
        case "resolve_row_fill": runRowFill(f, h)
        case "resolve_dropdown_field_ink": runDropdownFieldInk(f, h)
        case "resolve_summary_tile_fit": runSummaryTileFit(f, h)
        case "resolve_gallery_title_ink": runGalleryTitleInk(f, h)
        case "build_push_token_body": runPushTokenBody(f, h)
        case "resolve_block_container_style": runBlockContainerStyle(f, h)
        // Every tracked event (SDK and host) → message / survey triggers (SharedFixtureDrivers+Triggers.swift).
        case "dispatch_triggers": runDispatchTriggers(f, h)
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

    // MARK: decode_message_hero

    private func runDecodeMessageHero(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] decode_message_hero needs action.cases")
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
            return [
                "light": SharedFixtureTests.orNull(decodedContent.resolved(for: .light).image_url),
                "dark": SharedFixtureTests.orNull(decodedContent.resolved(for: .dark).image_url),
            ] as [String: Any]
        }
    }

    // MARK: decode_pending_delivery

    private func runDecodePendingDelivery(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] decode_pending_delivery needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            guard let doc = obj["document"]?.foundation as? [String: Any],
                  let nowMs = obj["now_ms"]?.doubleValue else {
                XCTFail("[\(f.id)] case needs document and now_ms")
                return NSNull()
            }
            guard let config = PendingMessageListener.decodeDelivery(
                data: doc, now: Date(timeIntervalSince1970: nowMs / 1000.0)
            ) else { return NSNull() }
            let content = config.content
            return [
                "message_type": SharedFixtureTests.orNull(config.message_type?.rawValue),
                "title": SharedFixtureTests.orNull(content?.title),
                "cta_type": SharedFixtureTests.orNull(content?.cta_action?.type?.rawValue),
                "cta_opens": SharedFixtureTests.orNull(content?.cta_action?.linkToOpen),
                "image_url": SharedFixtureTests.orNull(content?.image_url),
                "background_color": SharedFixtureTests.orNull(content?.background_color),
            ] as [String: Any]
        }
    }

    // MARK: resolve_message_dismiss

    private func runResolveMessageDismiss(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_message_dismiss needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let content = obj["content"]?.foundation as? [String: Any],
                  let at = obj["at_seconds"]?.arrayValue?.compactMap(\.doubleValue) else {
                XCTFail("[\(f.id)] case \(name): needs content and at_seconds")
                return NSNull()
            }
            let message: [String: Any] = ["name": name, "message_type": "modal", "content": content]
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let decoded = try? JSONDecoder().decode(MessageConfig.self, from: data) else {
                // A wrong-typed field must not lose the message: that is one of the cases.
                XCTFail("[\(f.id)] case \(name): the message did not decode")
                return NSNull()
            }
            let policy = MessageDismissPolicy(content: decoded.content)
            return [
                "dismissable": at.map { policy.userMayDismiss(afterSeconds: $0) },
                "unlock_after": policy.unlockAfterSeconds.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]
        }
    }
}
