// SharedFixtureDrivers+Style.swift
//
// iOS driver for the styling fixture kinds. Dispatched from `SharedFixtureTests.drive`'s default
// branch. Every value asserted is produced by a REAL SDK symbol:
//
//   unfold_blockquotes  REAL: `ContentBlockRendererView.normaliseMarkdown`, the rich_text
//                       renderer's blockquote pass.
//   parse_colour   REAL: `Color(hex:)` in Paywalls/PaywallHelperViews.swift — the SDK's only colour
//                  parser on this platform, read back through UIColor so the fixture can compare
//                  0-255 channels against Android's.
//
// The pairing this fixture exists for: Android's `StyleEngine.parseColor` and this
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
    @MainActor
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
        case "resolve_banner_icon": runBannerIcon(f, h)
        case "resolve_celebration_palette": runCelebrationPalette(f, h)
        case "resolve_google_mark_chip": runGoogleMarkChip(f, h)
        case "resolve_survey_sentiment": runSurveySentiment(f, h)
        case "resolve_likert_bounds": runLikertBounds(f, h)
        case "resolve_compact_picker_height": runCompactPickerHeight(f, h)
        case "resolve_in_step_visibility": runVisibilityInStepScope(f, h)
        case "resolve_field_input_style": runFieldInputStyle(f, h)
        case "resolve_plan_order": runPlanOrder(f, h)
        case "resolve_progress_skip_target": runProgressSkipTarget(f, h)
        case "resolve_countdown_progress": runCountdownProgress(f, h)
        case "resolve_countdown_variant": runCountdownVariant(f, h)
        case "resolve_named_icon_library": runNamedIconLibrary(f, h)
        case "resolve_segmented_presentation": runSegmentedPresentation(f, h)
        case "resolve_rive_input_kind": runRiveInputKind(f, h)
        case "track_events_with_observer": runEventObserver(f, h)
        default:
            return false
        }
        return true
    }


    // MARK: resolve_field_input_style

    /**
     The three `field_style` keys both natives DECODED, neither drew, and no console
     control wrote, through the resolvers the renderers actually call.

     🔴 The font size is a ladder of THREE spellings of one pixel. The console's two sliders write
     `field_config.input_text_size` and `field_config.font_size`, both renderers read that pair, and
     `field_style.font_size` — which both DTOs declare — was the one nothing read. A document
     carrying it rendered at 14 with no sign an authored value had been dropped.

     Each case answers `[size, weight-or-null, border when clean, border when in error]`, so the
     error swap is measured against its own non-error control in the same row — "the error colour
     appeared" proves nothing unless the clean border is known not to be it.
     */
    private func runFieldInputStyle(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_field_input_style needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let dict = c.objectValue?["value"]?.foundation as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
                XCTFail("[\(f.id)] a block did not decode")
                return NSNull()
            }
            return [
                Double(fieldInputFontSize(block)),
                SharedFixtureTests.orNull(Self.weightName(fieldInputFontWeight(block))),
                Self.hex(fieldBorderColor(block, hasError: false), block),
                Self.hex(fieldBorderColor(block, hasError: true), block),
            ] as [Any]
        }
    }

    /**
     The authored name for a resolved weight, so the fixture reads in the author's vocabulary rather
     than in `UIFont.Weight`'s raw values — and so Android can assert the SAME strings.
     */
    private static func weightName(_ weight: UIFont.Weight?) -> String? {
        guard let weight else { return nil }
        switch weight {
        case .thin: return "thin"
        case .light: return "light"
        case .regular: return "regular"
        case .medium: return "medium"
        case .semibold: return "semibold"
        case .bold: return "bold"
        case .heavy: return "heavy"
        case .black: return "black"
        default: return nil
        }
    }

    /**
     Which authored string the resolver's colour actually IS.

     🔴 MATCHED against the resolver's return value, not re-derived from the block. The first
     version of this helper reproduced `fieldBorderColor`'s own ladder from the authored keys — and
     a test that re-implements the thing under test can only ever agree with it. It would have
     reported the right hex for a resolver that always returned the default.

     A SwiftUI `Color` has no portable hex accessor, so the resolved colour is compared against each
     candidate instead; `Color` is `Equatable`, and both sides are built by the same `Color(hex:)`,
     so the comparison asks exactly "which of these did it pick".
     */
    private static func hex(_ resolved: Color, _ block: ContentBlock) -> Any {
        let fallback = "#D1D5DB"
        var candidates: [String] = [fallback]
        if let b = block.field_style?.border_color { candidates.append(b) }
        if let e = block.field_style?.error_border_color { candidates.append(e) }
        for candidate in candidates where resolved == Color(hex: candidate) { return candidate }
        // Not one of the colours it was allowed to choose — report it rather than guessing, so the
        // fixture names the row instead of passing on a near-miss.
        return NSNull()
    }


    // MARK: resolve_plan_order

    /**
     The order a paywall's plans draw in, through the REAL `PaywallPlanOrder`.

     🔴 `sort_order` was DECODED by both platforms and read by NEITHER, so order came from the
     array's own order and a document carrying an explicit rank drew its plans in whatever order
     they happened to be serialised in.

     🔴 WHAT THIS DRIVER DOES NOT PROVE, stated because it previously claimed otherwise. It called
     the sorter "the renderer calls on both of its plan-resolution sites" — and a driver that calls
     `PaywallPlanOrder.sorted` directly can see that the SORTER sorts and nothing about whether any
     renderer calls it. That blind spot let a real defect through: the sort was wired into the two sites that look a
     plan up BY ID, never into the one that draws, and this fixture stayed green throughout. The
     render-order claim is `PlanOrderRenderTests` (iOS) and `PlanOrderRenderTest` (Android), which
     compare what was DRAWN; this one pins the ordering rule itself, which is still worth pinning.

     Each case is a plain array of plans — the shape a published document carries — decoded through
     `PaywallPlan` so the rank arrives as the DTO coerces it, not as a literal the driver chose.
     */
    private func runPlanOrder(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_plan_order needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let array = c.objectValue?["value"]?.foundation as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: array),
                  let plans = try? JSONDecoder().decode([PaywallPlan].self, from: data) else {
                XCTFail("[\(f.id)] a plan array did not decode")
                return NSNull()
            }
            return PaywallPlanOrder.sorted(plans).map { SharedFixtureTests.orNull($0.id) }
        }
    }


    // MARK: resolve_progress_skip_target

    /**
     Where the progress bar's "Skip" link goes, through the REAL `ProgressSkipTarget` both
     renderers call.

     The three `nil` reasons are the point: no target, an empty/whitespace target, and a target
     naming a step that is not in the flow. Each must behave the same on both platforms, and a
     stale id must degrade to advancing rather than leaving Skip doing nothing.
     */
    private func runProgressSkipTarget(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_progress_skip_target needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let value = c.objectValue?["value"]?.objectValue
            let target = value?["skip_to_step"]?.foundation as? String
            let ids = (value?["step_ids"]?.foundation as? [Any])?.compactMap { $0 as? String } ?? []
            return SharedFixtureTests.orNull(ProgressSkipTarget.resolve(target, stepIds: ids))
        }
    }


    // MARK: resolve_countdown_progress

    /**
     How far a countdown has run, through the REAL `CountdownProgress` both indicators read.

     The ring was frozen at 0.75 on BOTH platforms — the preview's mock in two renderers — so the
     cases that matter are the ones a frozen value gets wrong: full, half, expired, and the clamps.
     */
    private func runCountdownProgress(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_countdown_progress needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            let remaining = (v?["remaining"]?.foundation as? NSNumber)?.intValue ?? 0
            let initial = (v?["initial"]?.foundation as? NSNumber)?.intValue ?? 0
            return CountdownProgress.remainingFraction(remainingSeconds: remaining, initialSeconds: initial)
        }
    }


    // MARK: resolve_countdown_variant

    /**
     Which variant a paywall countdown draws, through the REAL `PaywallCountdownVariant` the
     renderer dispatches on. The fallback is the part that would diverge between platforms, so the
     off-list and empty-string cases carry as much weight as the four real values.
     */
    private func runCountdownVariant(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_countdown_variant needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return PaywallCountdownVariant.resolve(
                v?["variant"]?.foundation as? String,
                timerVariant: v?["timer_variant"]?.foundation as? String
            )
        }
    }


    // MARK: resolve_named_icon_library

    /**
     Which library a BARE icon string belongs to, through the REAL `NamedIcon` both feature
     renderers call.

     The unknown-name case is the one that matters: it must answer `lucide` and never `emoji`,
     because the emoji arm prints the name as prose — which is the defect this fixes.
     */
    private func runNamedIconLibrary(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_named_icon_library needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let raw = c.objectValue?["value"]?.objectValue?["icon"]?.foundation as? String
            return SharedFixtureTests.orNull(NamedIcon.reference(raw)?.library)
        }
    }

    // MARK: resolve_element_container

    /**
     The per-element container style, through the REAL DTO: the entry decodes as
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
     A plan's billing period, through the REAL `PaywallPlan` decode.

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
             A case may carry a `store_period` BESIDE its `value`, because the store's ISO
             period is filled in by the presenter and is never part of a published document, so it
             cannot live inside the plan the decoder reads.

             `displayPeriod` rather than `period`: for every case without a `store_period` the two
             are identical, which is why the assertions written before store periods existed still stand unchanged.
            */
            plan.resolvedStorePeriod = c.objectValue?["store_period"]?.stringValue
            guard let period = plan.displayPeriod, !period.isEmpty else { return NSNull() }
            return period
        }
    }

    // MARK: resolve_location_search

    /**
     The Console's four location settings, resolved for the surface that offers them.

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
     A wrongly-typed field must not delete its block, and an undecodable element must not
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
                enabled: v?["enabled"]?.boolValue ?? false,
                scrollOffset: v?["scroll"]?.doubleValue ?? 0,
                threshold: v?["threshold"]?.doubleValue,
            )
        }
    }


    // MARK: resolve_google_mark_chip

    /**
     WHETHER Google's mark needs a white chip, through the REAL `GoogleMarkChip` both renderers
     call.

     The unreadable-background cases are the ones that earn their place: an absent, empty or
     malformed hex means the brand DEFAULT is what gets drawn, and that is `#4285F4` — so the
     answer has to be "chip", not "leave the mark illegible on a colour nobody can measure".
     */
    private func runGoogleMarkChip(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_google_mark_chip needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return GoogleMarkChip.isNeeded(
                buttonStyle: v?["style"]?.stringValue,
                backgroundHex: v?["bg"]?.stringValue,
                iconStyle: v?["icon_style"]?.stringValue,
            )
        }
    }


    // MARK: resolve_celebration_palette

    /**
     WHICH colours a celebration draws and whether it draws a glyph, through the REAL
     `CelebrationPalette` both overlays call.

     One string per case — the colours joined, then `|`, then the glyph — so the two platforms are
     compared on the WHOLE answer. A run that got the palette right and the shape wrong would
     otherwise pass half a fixture, and the shape is exactly where the unknown-type case diverged.
     */
    private func runCelebrationPalette(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_celebration_palette needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            let type = v?["type"]?.stringValue
            let authored = v?["colors"]?.arrayValue?.compactMap { $0.stringValue }
            let colors = CelebrationPalette.colors(type: type, authored: authored)
            return colors.joined(separator: ",") + "|" + CelebrationPalette.glyph(type: type)
        }
    }


    // MARK: resolve_banner_icon

    /**
     WHICH mark a banner draws and at what size, through the REAL `BannerIconResolution` both
     renderers call.

     Flattened to one string per case so the two platforms are compared on the WHOLE answer at
     once: a run that got the mark right and the size wrong would otherwise pass half a fixture.
     The whitespace-only URL is the case that matters — an author who clears an upload can leave a
     space behind, and " " is not an address, so the glyph has to come back.
     */
    private func runBannerIcon(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_banner_icon needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            let mark = BannerIconResolution.mark(
                hidden: v?["hidden"]?.boolValue ?? false,
                iconURL: v?["icon_url"]?.stringValue,
                glyph: v?["glyph"]?.stringValue,
                variantDefault: v?["variant_default"]?.stringValue ?? "",
            )
            let size = BannerIconResolution.size(v?["size"]?.doubleValue)
            let described: String
            switch mark {
            case .none: described = "none:"
            case .image(let url): described = "image:\(url)"
            case .glyph(let text): described = "glyph:\(text)"
            }
            return "\(described)@\(Int(size))"
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

    // MARK: resolve_compact_picker_height

    /**
     How tall a compact date pill is, through the REAL `CompactPickerHeight` the renderer
     calls.

     🔴 Driven through the production rule, never re-stated: the whole point is that this platform
     and Android now agree, and a driver computing its own answer could only ever agree with
     itself (Rule 25).
     */
    private func runCompactPickerHeight(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_compact_picker_height needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return Double(CompactPickerHeight.resolve(
                numeric: v?["numeric"]?.doubleValue,
                token: v?["token"]?.stringValue,
            ))
        }
    }

    // MARK: visibility_in_step_scope

    /**
     Whether a block is drawn, through the REAL `evaluateVisibilityCondition` the renderer
     calls, with the step's live inputs in scope.

     🔴 Driven through the production evaluator, never re-stated: the whole point is that this
     platform and Android now agree on when an in-step condition flips, and a driver computing its
     own answer could only ever agree with itself (Rule 25).
     */
    private func runVisibilityInStepScope(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] visibility_in_step_scope needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue
            // The condition is decoded through the production DTO, so a shape the SDK cannot read
            // fails here rather than being quietly re-typed by the driver.
            var condition: VisibilityCondition?
            if let raw = obj?["condition"]?.foundation as? [String: Any],
               JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw) {
                condition = try? JSONDecoder().decode(VisibilityCondition.self, from: data)
                if condition == nil { XCTFail("[\(f.id)] a condition did not decode") }
            }
            let responses = (obj?["responses"]?.foundation as? [String: Any]) ?? [:]
            let stepInputs = obj?["step_inputs"]?.foundation as? [String: Any]
            return evaluateVisibilityCondition(
                condition,
                responses: responses,
                hookData: nil,
                stepId: obj?["step_id"]?.stringValue,
                stepInputs: stepInputs
            )
        }
    }

    // MARK: segmented_presentation

    /**
     Whether a Segmented input draws a segmented control, through the REAL
     `SegmentedPresentation` the renderer calls.
     */
    private func runSegmentedPresentation(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] segmented_presentation needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            return SegmentedPresentation.drawsSegmentedControl(displayStyle: v?["display_style"]?.stringValue)
        }
    }

    // MARK: track_events_with_observer

    /**
     `onEventTracked` fires for every event, through the REAL `EventTracker.track` and the
     REAL `AppDNA.lifecycleDelegate`.

     🔴 Driven through the production chokepoint, never re-stated: the claim is that a host sees
     what the SDK queues, and a driver that called the delegate itself would prove only that the
     driver can call a delegate.
     */
    private func runEventObserver(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] track_events_with_observer needs action.cases")
            return
        }
        final class Observer: AppDNALifecycleDelegate {
            var names: [String] = []
            var props: [[String: Any]] = []
            var throwOn: Set<String> = []
            func onEventTracked(name: String, properties: [String: Any]) {
                names.append(name)
                props.append(properties)
                /*
                 🔴 A Swift protocol method that is not `throws` CANNOT throw, which is this
                 platform's half of the observer guarantee. The fixture's `observer_throws` is
                 modelled here as the nearest thing a host can actually do wrong — a handler that
                 does work and returns — so the case still asserts that the NEXT event arrives.
                 */
                _ = throwOn.contains(name)
            }
        }
        let observer = Observer()
        observer.throwOn = Set(cases.compactMap { c -> String? in
            guard c.objectValue?["observer_throws"]?.boolValue == true else { return nil }
            return c.objectValue?["event"]?.stringValue
        })

        let previous = AppDNA.lifecycleDelegate
        AppDNA.lifecycleDelegate = observer
        defer { AppDNA.lifecycleDelegate = previous }

        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "fx.\(UUID())")))
        var queued = 0
        tracker.eventSink = { _ in queued += 1 }
        for c in cases {
            guard let event = c.objectValue?["event"]?.stringValue else { continue }
            let props = (c.objectValue?["properties"]?.foundation as? [String: Any]) ?? [:]
            tracker.track(event: event, properties: props)
        }

        h.state["observed"] = observer.names
        h.state["observed_properties"] = observer.props.map { dict in
            dict.mapValues { "\($0)" }
        }
        h.state["queued"] = queued
    }

    // MARK: resolve_rive_input_kind

    /**
     Which kind of Rive input an authored value means, through the REAL `RiveInputKind`
     the renderer calls.

     🔴 The cases come out of the fixture's JSON through `AnyCodable`, which is the SAME path a
     published document takes — so a bool that this platform's JSON decoder hands back as an
     `NSNumber` is tested as it really arrives, not as a Swift literal the driver chose.
     */
    private func runRiveInputKind(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_rive_input_kind needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let raw = c.objectValue?["value"]
            // An absent key and an explicit null are the same instruction: none.
            guard let raw, !(raw.foundation is NSNull) else { return NSNull() }
            return RiveInputKind.of(raw.foundation).map { $0.rawValue } ?? NSNull()
        }
    }

    // MARK: resolve_likert_bounds

    /**
     A likert scale's bounds and anchor visibility, through the REAL `LikertScaleRule` the
     renderer calls.

     🔴 Driven through the production rule, never re-stated: the clamp exists because a reversed
     range TRAPS on this platform and draws nothing on the other, and a driver that computed its
     own bounds could only ever agree with itself (Rule 25).
     */
    private func runLikertBounds(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_likert_bounds needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let v = c.objectValue?["value"]?.objectValue
            let mn = v?["min"]?.doubleValue.map { Int($0) }
            let mx = v?["max"]?.doubleValue.map { Int($0) }
            let b = LikertScaleRule.bounds(min: mn, max: mx)
            let n = LikertScaleRule.count(min: mn, max: mx)
            let anchors = LikertScaleRule.showsAnchors(
                low: v?["low_label"]?.stringValue,
                high: v?["high_label"]?.stringValue,
            )
            return "\(b.lo)-\(b.hi) n=\(n) anchors=\(anchors)"
        }
    }

    // MARK: resolve_store_price

    /**
     Whether a plan shows the STORE's price or the one an author typed, through the REAL
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
     Whether a step advances by itself, through the REAL `OnboardingStep` DECODE and the
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
     Whether a pinned bottom zone is too tall to stay pinned, through the REAL
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
     The colour a paywall gives text nobody authored, through the REAL
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
     The header's reserved footprint, through the REAL `PaywallHeaderInset.resolve`.

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
     The four values a shadow draws with, through the REAL `StyleEngine.resolveShadow`.

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
     A blockquote becomes the italic syntax both parsers already render.

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
