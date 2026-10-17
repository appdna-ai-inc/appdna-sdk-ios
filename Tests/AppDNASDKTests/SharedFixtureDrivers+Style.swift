// SharedFixtureDrivers+Style.swift
//
// iOS driver for the styling fixture kinds. Dispatched from `SharedFixtureTests.drive`'s default
// branch. Every value asserted is produced by a REAL SDK symbol:
//
//   unfold_blockquotes  REAL: `ContentBlockRendererView.normaliseMarkdown`, the rich_text
//                       renderer's blockquote pass (#893).
//   parse_colour   REAL: `Color(hex:)` in Paywalls/PaywallHelperViews.swift — the SDK's only colour
//                  parser on this platform, read back through UIColor so the fixture can compare
//                  0-255 channels against Android's.
//
// #885. The pairing this fixture exists for: Android's `StyleEngine.parseColor` and this
// initialiser must answer the same thing for the same string. They did not. Android's paywall and
// survey renderers each carried a private copy that read 8-char hex as ARGB rather than RGBA and
// fell back to black / white rather than transparent, and this side rendered a six-letter CSS
// colour name as opaque black where Android returned transparent.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveStyle(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "parse_colour": runParseColour(f, h)
        case "unfold_blockquotes": runUnfoldBlockquotes(f, h)
        case "normalise_markdown": runUnfoldBlockquotes(f, h)
        case "resolve_shadow": runResolveShadow(f, h)
        case "resolve_header_inset": runHeaderCloseInset(f, h)
        case "resolve_default_text_colour": runDefaultTextColour(f, h)
        case "bottom_zone_overflows": runBottomZoneOverflows(f, h)
        case "resolve_element_container": runElementContainer(f, h)
        default:
            return false
        }
        return true
    }

    // MARK: resolve_element_container

    /**
     #905 — the per-element container style, through the REAL DTO: the entry decodes as
     `SectionElementConfig` and resolves through `container`, which is what the renderer reads.
     */
    private func runElementContainer(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_element_container needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let dict = c.objectValue?["value"]?.foundation as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let entry = try? JSONDecoder().decode(SectionElementConfig.self, from: data) else {
                XCTFail("[\(f.id)] an element entry did not decode")
                return NSNull()
            }
            guard let container = entry.container else { return NSNull() }
            return [
                SharedFixtureTests.orNull(container.border?.color),
                SharedFixtureTests.orNull(container.border?.width),
                SharedFixtureTests.orNull(container.border?.radius),
                SharedFixtureTests.orNull(container.corner_radius),
                SharedFixtureTests.orNull(container.opacity),
                SharedFixtureTests.orNull(container.padding?.top),
            ] as [Any]
        }
    }

    // MARK: bottom_zone_overflows

    /**
     #903 — whether a pinned bottom zone is too tall to stay pinned, through the REAL
     `PaywallBottomZone.overflows`. Values are `[pinnedPx, viewportPx]`.
     */
    private func runBottomZoneOverflows(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] bottom_zone_overflows needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let pair = c.objectValue?["value"]?.arrayValue, pair.count == 2,
                  let pinned = pair[0].doubleValue, let viewport = pair[1].doubleValue else {
                XCTFail("[\(f.id)] a case is not [pinnedPx, viewportPx]")
                return NSNull()
            }
            return PaywallBottomZone.overflows(pinned: pinned, viewport: viewport)
        }
    }

    // MARK: paywall_default_text_colour

    /**
     #891 — the colour a paywall gives text nobody authored, through the REAL
     `PaywallTextDefaults.readableHex`.
     */
    private func runDefaultTextColour(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_default_text_colour needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let bg = c.objectValue?["value"]?.stringValue
            return PaywallTextDefaults.readableHex(on: bg)
        }
    }

    // MARK: paywall_header_close_inset

    /**
     #895 — the header's reserved footprint, through the REAL `PaywallHeaderInset.resolve`.

     A `null` case means no `dismiss` object at all, which is the common authored shape and the one
     that must still reserve: absent means dismissable.
     */
    private func runHeaderCloseInset(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_header_inset needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let raw = c.objectValue?["value"]
            if raw == nil || raw?.foundation is NSNull {
                return Double(PaywallHeaderInset.resolve(nil))
            }
            guard let dict = raw?.foundation as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let dismiss = try? JSONDecoder().decode(PaywallDismiss.self, from: data) else {
                XCTFail("[\(f.id)] a dismiss case did not decode")
                return NSNull()
            }
            return Double(PaywallHeaderInset.resolve(dismiss))
        }
    }

    // MARK: resolve_shadow

    /**
     #886 — the four values a shadow draws with, through the REAL `StyleEngine.resolveShadow`.

     `[colorArgbHex, radius, dx, dy]`, or null when the shadow does not draw at all.
     */
    private func runResolveShadow(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_shadow needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            // `.foundation`, NOT `.host`: the latter converts to the SDK's HostJSON, and handing
            // that to JSONSerialization raises an Obj-C exception that `try?` cannot catch — the
            // whole test binary died rather than failing one fixture. Decoding is used instead of a
            // memberwise init because `ShadowStyleConfig`'s is internal to the SDK module.
            guard let raw = c.objectValue?["value"]?.foundation as? [String: Any],
                  JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let cfg = try? JSONDecoder().decode(ShadowStyleConfig.self, from: data) else {
                XCTFail("[\(f.id)] resolve_shadow case did not decode")
                return NSNull()
            }
            guard let r = StyleEngine.resolveShadow(cfg) else { return NSNull() }
            return [r.colorArgb, r.radius, r.dx, r.dy] as [Any]
        }
    }

    // MARK: unfold_blockquotes

    /**
     #893 — a blockquote becomes the italic syntax both parsers already render.

     Drives the REAL `normaliseMarkdown` the rich_text renderer calls, so the two platforms are
     held to one answer for a chevron that used to reach the screen verbatim.
     */
    private func runUnfoldBlockquotes(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] unfold_blockquotes needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let value = c.objectValue?["value"]?.stringValue else {
                XCTFail("[\(f.id)] unfold_blockquotes case without a string value")
                return NSNull()
            }
            return ContentBlockRendererView.normaliseMarkdown(value)
        }
    }

    // MARK: parse_colour

    private func runParseColour(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] parse_colour needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let value = c.objectValue?["value"]?.stringValue else {
                XCTFail("[\(f.id)] parse_colour case without a string value")
                return NSNull()
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            // `getRed` returns false only for a colour outside a compatible colour space; every
            // value `Color(hex:)` can produce is sRGB or `.clear`, so a false here is a real defect
            // rather than a quirk to tolerate.
            guard UIColor(Color(hex: value)).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                XCTFail("[\(f.id)] parse_colour: '\(value)' produced a colour with no sRGB components")
                return NSNull()
            }
            return [Int((r * 255).rounded()), Int((g * 255).rounded()),
                    Int((b * 255).rounded()), Int((a * 255).rounded())]
        }
    }
}
