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
        case "resolve_plan_period": runPlanPeriod(f, h)
        case "resolve_location_search": runLocationSearch(f, h)
        case "resolve_step_auto_advance": runStepAutoAdvance(f, h)
        case "resolve_store_price": runStorePrice(f, h)
        case "parse_blocks_leniently": runLenientBlocks(f, h)
        case "resolve_survey_choice_options": runSurveyChoiceOptions(f, h)
        case "resolve_button_label_colour": runButtonLabelColour(f, h)
        case "resolve_onboarding_celebration": runOnboardingCelebration(f, h)
        case "resolve_block_collapse": runBlockCollapse(f, h)
        case "resolve_survey_sentiment": runSurveySentiment(f, h)
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

    // MARK: resolve_plan_period

    /**
     #913 — a plan's billing period, through the REAL `PaywallPlan` decode.

     The field was on both DTOs and readable by neither surface that matters: this platform
     declared `periodTextStyle` and never drew it, so a period authored anywhere showed on Android
     and nowhere here. An empty string resolves to nil, because both renderers treat it as absent
     rather than drawing a blank label against the price.
     */
    private func runPlanPeriod(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_plan_period needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let dict = c.objectValue?["value"]?.foundation as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  var plan = try? JSONDecoder().decode(PaywallPlan.self, from: data) else {
                XCTFail("[\(f.id)] a plan did not decode")
                return NSNull()
            }
            /*
             #933 — a case may carry a `store_period` BESIDE its `value`, because the store's ISO
             period is filled in by the presenter and is never part of a published document, so it
             cannot live inside the plan the decoder reads.

             `displayPeriod` rather than `period`: for every case without a `store_period` the two
             are identical, which is why the assertions written before #933 still stand unchanged.
            */
            plan.resolvedStorePeriod = c.objectValue?["store_period"]?.stringValue
            guard let period = plan.displayPeriod, !period.isEmpty else { return NSNull() }
            return period
        }
    }

    // MARK: resolve_location_search

    /**
     #963 — the Console's four location settings, resolved for the surface that offers them.

     🔴 FOUR SURFACES, NOT TWO. A form-step Location field takes its config as a typed
     `FormFieldConfig`; an `input_location` content block takes a free-form `field_config` map. The
     field read all four settings and the block read NONE, because the block had grown its own copy
     of the search call that took only the query — so Type = "city" returned street addresses and an
     authored Min characters did nothing, silently, on both platforms.

     Both shapes go through the REAL `LocationSearchSettings`, and the typed one through the REAL
     `FormFieldConfig` decode, because a driver that builds the config by hand can only ever agree
     with itself.

     The two `defaultMinChars` are deliberate: 2 for a form-step field, 3 for a content block (what
     the Console seeds), preserved per surface so no published flow changes.
     */
    private func runLocationSearch(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_location_search needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let obj = c.objectValue,
                  let surface = obj["surface"]?.stringValue,
                  let raw = obj["value"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] a case needs {surface, value}")
                return NSNull()
            }
            let resolved: LocationSearchSettings
            switch surface {
            case "content_block":
                resolved = LocationSearchSettings.from(
                    blockConfig: raw.mapValues { AnyCodable($0) }, defaultMinChars: 3)
            case "form_field":
                guard JSONSerialization.isValidJSONObject(raw),
                      let data = try? JSONSerialization.data(withJSONObject: raw),
                      let typed = try? JSONDecoder().decode(FormFieldConfig.self, from: data) else {
                    XCTFail("[\(f.id)] a form field config did not decode")
                    return NSNull()
                }
                resolved = LocationSearchSettings.from(fieldConfig: typed, defaultMinChars: 2)
            default:
                XCTFail("[\(f.id)] unknown surface \(surface)")
                return NSNull()
            }
            let parts = [resolved.type ?? "-", resolved.biasCountry ?? "-", resolved.language ?? "-",
                         String(resolved.minChars)]
            return parts.joined(separator: "|")
        }
    }

    // MARK: parse_blocks_leniently

    /**
     #919 — a wrongly-typed field must not delete its block, and an undecodable element must not
     truncate the ones after it. Through the REAL `[ContentBlock]` decode, the lenient one.

     Before this the array decode THREW on the first bad element, which failed the step, then the
     flow, and the SDK dropped the whole document — so the honest assertion is the surviving ids,
     because "it did not throw" is only half of what changed.
     */
    private func runLenientBlocks(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] parse_blocks_leniently needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let raw = c.objectValue?["value"]?.foundation as? [Any] else {
                XCTFail("[\(f.id)] a case had no value array")
                return [] as [Any]
            }
            // Wrapped in a container keyed exactly as a step is, so the path under test is the one
            // production takes — not a bare array decode that happens to behave the same.
            let wrapper: [String: Any] = ["content_blocks": raw]
            guard JSONSerialization.isValidJSONObject(wrapper),
                  let data = try? JSONSerialization.data(withJSONObject: wrapper) else {
                XCTFail("[\(f.id)] a case did not serialise")
                return [] as [Any]
            }
            struct Holder: Decodable {
                let content_blocks: [ContentBlock]?
                enum CodingKeys: String, CodingKey { case content_blocks }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "fixture")
                }
            }
            guard let holder = try? JSONDecoder().decode(Holder.self, from: data) else {
                XCTFail("[\(f.id)] the lenient decode THREW — which is the defect itself")
                return [] as [Any]
            }
            return (holder.content_blocks ?? []).map { $0.id ?? "" } as [Any]
        }
    }


    // MARK: resolve_survey_choice_options

    /**
     A survey choice option's icon, through the REAL `ChoiceConfig` decode and `resolvedIcon`.

     🔴 The assertion is the SURVIVING OPTIONS as well as their icons, because the defect deleted
     options. `icon` was declared `String?` inside a lenient array, so the object form `IconRefSchema`
     accepts made that element fail to decode and the respondent saw one fewer choice — silently.
     An option with no icon resolves to `id|`, so a dropped option can never be read as an
     icon-less one.
     */
    private func runSurveyChoiceOptions(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_survey_choice_options needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let raw = c.objectValue?["value"]?.foundation as? [Any] else {
                XCTFail("[\(f.id)] a case had no value array")
                return [] as [Any]
            }
            // Through `choice_config`, keyed exactly as Firestore sends it, so the path under test
            // is production's — including the lenient array that did the dropping.
            let wrapper: [String: Any] = ["options": raw]
            guard JSONSerialization.isValidJSONObject(wrapper),
                  let data = try? JSONSerialization.data(withJSONObject: wrapper),
                  let cfg = try? JSONDecoder().decode(ChoiceConfig.self, from: data) else {
                XCTFail("[\(f.id)] choice_config did not decode at all")
                return [] as [Any]
            }
            return (cfg.options ?? []).map { opt -> Any in
                let icon = opt.resolvedIcon
                let parts = [opt.id ?? "", icon?.library ?? "", icon?.name ?? ""]
                // "id|" for no icon; "id|library|name" otherwise.
                return icon == nil ? "\(parts[0])|" : parts.joined(separator: "|")
            } as [Any]
        }
    }


    // MARK: resolve_button_label_colour

    /**
     WHICH authored colour a button's label draws in, through the REAL `ButtonLabelColour.resolve`
     both the renderer and the Kotlin now call.

     🔴 It is driven through the production function rather than re-stated here, because the two
     platforms had OPPOSITE rules and a test that re-implements the rule can only agree with
     whichever side wrote it (Rule 25). `""` for "neither authored", so the nil case is asserted
     rather than skipped.
     */
    private func runButtonLabelColour(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_button_label_colour needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return ButtonLabelColour.resolve(
                textColor: v?["text_color"]?.stringValue,
                styleColor: v?["style_color"]?.stringValue,
            ) ?? ""
        }
    }


    // MARK: resolve_block_collapse

    /**
     HOW FAR a block authored `collapse_on_scroll` has collapsed, through the REAL
     `BlockCollapseOnScroll` both renderers call.

     The negative cases carry the weight: a non-positive threshold must fall back rather than
     divide by zero, and a negative scroll offset (a rubber-band bounce at the top) must not read
     as "collapsed".
     */
    private func runBlockCollapse(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_block_collapse needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return BlockCollapseOnScroll.progress(
                enabled: (v?["enabled"]?.value as? Bool) ?? false,
                scrollOffset: v?["scroll"]?.doubleValue ?? 0,
                threshold: v?["threshold"]?.doubleValue,
            )
        }
    }


    // MARK: resolve_onboarding_celebration

    /**
     WHEN a flow's authored celebration fires, through the REAL `OnboardingCelebration` both
     renderers call.

     `""` for "no celebration at this index", so the nil case is asserted rather than skipped — the
     defect being guarded is an effect that fires at the WRONG moment, which a test that only
     checks the positive cases cannot see.
     */
    private func runOnboardingCelebration(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_onboarding_celebration needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return OnboardingCelebration.celebratedMoment(
                trigger: v?["trigger"]?.stringValue,
                stepIndex: Int(v?["step_index"]?.doubleValue ?? 0),
            ) ?? ""
        }
    }


    // MARK: resolve_survey_sentiment

    /**
     WHICH follow-up branch a completed survey takes, through the REAL `SurveySentimentRule` the
     renderer calls.

     🔴 Driven through the production function, not re-stated: the defect was a hard-coded emoji
     scale, and a test that hard-codes its own would agree with it (Rule 25). The authored scale is
     passed exactly as `determineSentiment` passes it — off the ANSWERED question.
     */
    private func runSurveySentiment(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_survey_sentiment needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            let scale = v?["emoji_scale"]?.arrayValue?.compactMap { $0.stringValue }
            return SurveySentimentRule.resolve(
                surveyType: v?["survey_type"]?.stringValue,
                answer: v?["answer"]?.foundation,
                emojiScale: scale,
            ).analyticsName
        }
    }

    // MARK: resolve_store_price

    /**
     #923 — whether a plan shows the STORE's price or the one an author typed, through the REAL
     policy both renderers call.

     The authored string is the FALLBACK on every failure path, so most cases here are failures:
     an absent `store_price` stands for a lookup that threw, timed out, or returned no such
     product, and the renderer cannot tell those apart — nor should it, since the answer is the
     same.
     */
    private func runStorePrice(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_store_price needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let v = c.objectValue?["value"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] a case had no value object")
                return NSNull()
            }
            let out = StorePriceSubstitution.resolve(
                authoredPrice: v["authored_price"] as? String,
                productId: v["product_id"] as? String,
                useStorePrice: v["use_store_price"] as? Bool,
                storePrice: v["store_price"] as? String
            )
            return [out.priceDisplay, out.source] as [Any]
        }
    }

    // MARK: resolve_step_auto_advance

    /**
     #921 — whether a step advances by itself, through the REAL `OnboardingStep` DECODE and the
     real policy, not the policy alone.

     Decoding the step is the load-bearing half: the console writes these two fields inside the
     step's `layout`, so a reader that takes the policy a hand-built struct and skips the decode
     would pass while every authored splash screen sat there forever. The cases feed the step JSON
     exactly as published.
     */
    private func runStepAutoAdvance(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_step_auto_advance needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard var dict = c.objectValue?["value"]?.foundation as? [String: Any] else {
                XCTFail("[\(f.id)] a case had no value object")
                return NSNull()
            }
            dict["id"] = dict["id"] ?? "fixture_step"
            dict["type"] = dict["type"] ?? "splash"
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let step = try? JSONDecoder().decode(OnboardingStep.self, from: data) else {
                XCTFail("[\(f.id)] a step did not decode")
                return NSNull()
            }
            guard let delay = StepAutoAdvance.delaySeconds(for: step) else { return NSNull() }
            return delay
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
