// SharedFixtureDrivers+PaywallImageAlt.swift
//
//   resolve_paywall_image_alt  REAL: `PaywallConfig` decoding of a paywall with one image section →
//                              `PaywallImageAccessibility.label(_:)`, the value `imageSectionView` hands
//                              VoiceOver as the image's `.accessibilityLabel`.
//   resolve_onboarding_image_alt REAL: the lenient `[ContentBlock]` decode a step runs →
//                              `ContentBlock.imageAccessibilityLabel`, the label every image branch of
//                              `ContentBlockRendererView` uses.
//   resolve_screen_image_alt   REAL: `ScreenConfig` decoding → `ScreenImageAccessibility.label(_:)`.
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

    // resolve_paywall_trial_badge_color REAL: `PaywallConfig` decoding of a paywall with one social-proof section
    // and a cta → `PaywallAccent.trialBadgeHex` (the badge) and `PaywallAccent.ctaHex` (the paywall's accent).
    func runPaywallTrialBadgeColor(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_trial_badge_color needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let section = obj["section"]?.foundation as? [String: Any],
                  let cta = obj["cta"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "id": "pw_badge_\(name)", "cta": cta,
                      "layout": ["type": "stack", "sections": [["id": "s1", "type": "social_proof", "config": section]]],
                  ] as [String: Any]) else {
                XCTFail("[\(f.id)] case \(name): needs section and cta")
                return NSNull()
            }
            let decoded: PaywallConfig
            do {
                decoded = try JSONDecoder().decode(PaywallConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode: \(error)")
                return NSNull()
            }
            let proof = decoded.sections.first(where: { $0.type == "social_proof" })
            return [
                "badge": PaywallAccent.trialBadgeHex(proof?.data, cta: decoded.cta).map { $0 as Any } ?? NSNull(),
                "accent": PaywallAccent.ctaHex(decoded.cta).map { $0 as Any } ?? NSNull(),
            ] as [String: Any]
        }
    }

    // resolve_paywall_comparison_table_style REAL: `PaywallConfig` decoding of a paywall with one comparison_table
    // section → `PaywallComparisonTableStyle.resolve(section, page)`, and `cellKind` per `cell_values` entry.
    func runPaywallComparisonTableStyle(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_comparison_table_style needs action.cases")
            return
        }
        let orNull: (String?) -> Any = { $0.map { $0 as Any } ?? NSNull() }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let section = obj["section"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "id": "pw_table_\(name)",
                      "layout": ["type": "stack", "sections": [["id": "s1", "type": "comparison_table", "config": section]]],
                  ] as [String: Any]) else {
                XCTFail("[\(f.id)] case \(name): needs section")
                return NSNull()
            }
            let decoded: PaywallConfig
            do {
                decoded = try JSONDecoder().decode(PaywallConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode: \(error)")
                return NSNull()
            }
            let table = decoded.sections.first(where: { $0.type == "comparison_table" })
            let t = PaywallComparisonTableStyle.resolve(table?.data, pageBackground: obj["page_background"]?.stringValue)
            return [
                "feature_header": t.featureHeader, "header_bg": orNull(t.headerBgHex), "header_text": t.headerTextHex,
                "header_font_size": t.headerFontSize, "header_font_weight": t.headerFontWeight,
                "cell_text": t.cellTextHex, "feature_text_alpha": t.featureTextAlpha,
                "cell_font_size": t.cellFontSize, "cell_font_weight": t.cellFontWeight,
                "row_alt_bg": orNull(t.rowAltBgHex), "cross": t.crossHex, "partial": t.partialHex, "border": t.borderHex,
                "highlight": orNull(t.highlightHex), "corner_radius": t.cornerRadius,
                "columns": t.columns.map { ["label": $0.label, "highlighted": $0.highlighted, "header_text": $0.headerTextHex, "check": $0.checkHex] as [String: Any] },
            ] as [String: Any]
        }
        h.state["cell_kinds"] = (f.action.raw["cell_values"]?.arrayValue ?? []).map { PaywallComparisonTableStyle.cellKind($0.stringValue ?? "") }
    }

    // resolve_paywall_badge_fill REAL: `PaywallConfig` decoding of a paywall with one plans section →
    // `PaywallBadgeFill.resolve(bgColor:gradient:accent:)` with the case's accent as the brand accent.
    func runPaywallBadgeFill(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_badge_fill needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let section = obj["section"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "id": "pw_badge_fill_\(name)",
                      "layout": ["type": "stack", "sections": [["id": "s1", "type": "plans", "config": section]]],
                  ] as [String: Any]) else {
                XCTFail("[\(f.id)] case \(name): needs section")
                return NSNull()
            }
            let decoded: PaywallConfig
            do {
                decoded = try JSONDecoder().decode(PaywallConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode: \(error)")
                return NSNull()
            }
            let plans = decoded.sections.first(where: { $0.type == "plans" })
            let style = PlanCardStyle(from: plans?.data)
            let r = PaywallBadgeFill.resolve(bgColor: style.badgeBgColor, gradient: style.badgeGradient, accent: obj["accent"]?.stringValue)
            return ["kind": r.kind, "colors": r.colors, "locations": r.locations, "angle": r.angle] as [String: Any]
        }
    }

    // resolve_paywall_plan_badge REAL: `PaywallConfig` decoding of a paywall with one plans section (its plans
    // in the section config) → `PaywallPlanBadge.placement(layout:badgePosition:)` and `PaywallPlanBadge.text(_:)` per plan,
    // the two calls `PaywallRenderer` makes for pill_selector, segmented_toggle and product_as_cta.
    func runPaywallPlanBadge(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_paywall_plan_badge needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let section = obj["section"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "id": "pw_plan_badge_\(name)",
                      "layout": ["type": "stack", "sections": [["id": "s1", "type": "plans", "config": section]]],
                  ] as [String: Any]) else {
                XCTFail("[\(f.id)] case \(name): needs section")
                return NSNull()
            }
            let decoded: PaywallConfig
            do {
                decoded = try JSONDecoder().decode(PaywallConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the paywall did not decode: \(error)")
                return NSNull()
            }
            let plansSection = decoded.sections.first(where: { $0.type == "plans" })
            let style = PlanCardStyle(from: plansSection?.data)
            let placement = PaywallPlanBadge.placement(layout: plansSection?.data?.planDisplayStyle, badgePosition: style.badgePosition)
            let drawn = (plansSection?.data?.plans ?? []).map { PaywallPlanBadge.text($0.badge) != nil }
            return ["placement": placement, "drawn": drawn] as [String: Any]
        }
    }

     // resolve_post_purchase_failure REAL: `PostPurchaseFailureConfig.effective`, the config `PaywallManager` routes a
    // resolve_post_purchase_failure REAL: `PostPurchaseFailureConfig.effective`, the config `PaywallManager` routes a
    // failed purchase with. Each case: an `error_type` and an optional authored `on_failure`; the result is its action.
    func runPostPurchaseFailure(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_post_purchase_failure needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            let authored = o["authored"]?.objectValue.map {
                PostPurchaseFailureConfig(action: $0["action"]?.stringValue ?? "", message: $0["message"]?.stringValue,
                                          retry_text: $0["retry_text"]?.stringValue, allow_dismiss: nil)
            }
            let r = PostPurchaseFailureConfig.effective(authored: authored, errorType: o["error_type"]?.stringValue ?? "")
            return r.map { $0.action as Any } ?? NSNull()
        }
    }

    // resolve_post_purchase_success_absent REAL: `PostPurchaseSuccessPlan.absentOnSuccess`, the plan `PaywallManager`
    // acts on when a purchase succeeds with no authored `on_success` (#2223). Each case: is the paywall still presented.
    func runPostPurchaseSuccessAbsent(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_post_purchase_success_absent needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let presented = c.objectValue?["still_presented"]?.boolValue ?? false
            let plan = PostPurchaseSuccessPlan.absentOnSuccess(paywallStillPresented: presented)
            return plan.closes ? "close@\(plan.delayMs)\(plan.reportsDismissed ? "+dismissed" : "")" : "none"
        }
    }

    // resolve_screen_surface_ink REAL: `ScreenConfig` decoding → `GoogleMapsAttribution.backdrop(ofScreen:)` /
    // `backdrop(ofSection:behind:)` → `surfaceScheme`, the scheme `ScreenRenderer` and `ScreenSectionSurface` set.
    func runScreenSurfaceInk(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_screen_surface_ink needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            let name = o["name"]?.stringValue ?? "?"
            var section: [String: Any] = ["id": "s1", "type": "text_section", "data": ["text": "x"]]
            if let style = o["section_style"]?.foundation { section["style"] = style }
            var screen: [String: Any] = ["id": "scr_ink_\(name)", "sections": [section]]
            if let bg = o["background"]?.foundation { screen["background"] = bg }
            guard let data = try? JSONSerialization.data(withJSONObject: screen),
                  let config = try? JSONDecoder().decode(ScreenConfig.self, from: data) else {
                XCTFail("[\(f.id)] case \(name): the screen did not decode")
                return NSNull()
            }
            let backdrop = GoogleMapsAttribution.backdrop(
                ofSection: config.sections?.first?.style,
                behind: GoogleMapsAttribution.backdrop(ofScreen: config.background))
            let dark = (o["dark_appearance"]?.foundation as? Bool) ?? false
            return GoogleMapsAttribution.surfaceScheme(on: backdrop, darkAppearance: dark) == .dark ? "light_ink" : "dark_ink"
        }
    }

    func runDateWheel(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_date_wheel needs action.cases")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ s: String) -> Date {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
        }
        let wide = date("1800-01-01")...date("2200-12-31")
        h.state["results"] = cases.map { c -> Any in
            let o = c.objectValue ?? [:]
            switch o["op"]?.stringValue {
            case "columns":
                return DateWheelModel.dateColumns(locale: Locale(identifier: o["locale"]?.stringValue ?? "en-US")).map { $0.rawValue }
            case "days":
                let m = DateWheelModel(calendar: calendar, minimum: wide.lowerBound, maximum: wide.upperBound)
                return m.days(inYear: (o["year"]?.foundation as? Int) ?? 0, month: (o["month"]?.foundation as? Int) ?? 1).count
            case "clamp":
                let minimum = o["min"]?.stringValue.map(date) ?? wide.lowerBound
                let maximum = o["max"]?.stringValue.map(date) ?? wide.upperBound
                let m = DateWheelModel(calendar: calendar, minimum: minimum, maximum: maximum)
                let r = m.clamped(year: (o["year"]?.foundation as? Int) ?? 0, month: (o["month"]?.foundation as? Int) ?? 1, day: (o["day"]?.foundation as? Int) ?? 1)
                let p = m.parts(of: r)
                return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
            case "unset_opening":
                // Where an unset wheel opens, through the function its initialiser seeds the selection with.
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = TimeZone(identifier: o["zone"]?.stringValue ?? "UTC")!
                let now = ISO8601.date(from: o["now"]?.stringValue ?? "") ?? Date()
                let p = zoned.dateComponents([.year, .month, .day, .hour, .minute], from: DateWheelPickerBlockView.unsetOpening(now: now, zone: zoned.timeZone))
                return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
            case "store", "read", "read_time", "display", "form_read":
                // The wheel's own calendar in the case's zone: what a phone set to that zone draws and stores.
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = TimeZone(identifier: o["zone"]?.stringValue ?? "UTC")!
                if o["op"]?.stringValue == "store" {
                    let picked = zoned.date(from: DateComponents(year: (o["year"]?.foundation as? Int) ?? 0, month: (o["month"]?.foundation as? Int) ?? 1,
                                                                 day: (o["day"]?.foundation as? Int) ?? 1, hour: (o["hour"]?.foundation as? Int) ?? 0,
                                                                 minute: (o["minute"]?.foundation as? Int) ?? 0))!
                    return DateWheelAnswer.string(for: picked, mode: o["mode"]?.stringValue ?? "date", calendar: zoned)
                }
                if o["op"]?.stringValue == "display" {
                    let now = ISO8601.date(from: o["now"]?.stringValue ?? "") ?? Date()
                    // A date is drawn in the case's locale (the device's in the app), en_US when the case names none.
                    let locale = Locale(identifier: o["locale"]?.stringValue ?? "en_US")
                    return AnswerTime.display(o["text"]?.stringValue ?? "", in: zoned.timeZone, now: now, locale: locale).map { $0 as Any } ?? NSNull()
                }
                if o["op"]?.stringValue == "form_read" {
                    // What `FormInputDateBlock` seeds and shows on return, through the same reader.
                    guard let read = DateWheelAnswer.date(from: o["saved"]?.stringValue ?? "", calendar: zoned) else { return NSNull() }
                    let p = zoned.dateComponents([.year, .month, .day, .hour, .minute], from: read)
                    switch o["mode"]?.stringValue {
                    case "date": return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
                    case "time": return String(format: "%02d:%02d", p.hour ?? 0, p.minute ?? 0)
                    default: return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
                    }
                }
                if o["op"]?.stringValue == "read_time" {
                    guard let read = DateWheelAnswer.date(from: o["saved"]?.stringValue ?? "", calendar: zoned) else { return NSNull() }
                    let p = zoned.dateComponents([.year, .month, .day, .hour, .minute], from: read)
                    return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
                }
                guard let read = DateWheelAnswer.date(from: o["saved"]?.stringValue ?? "", calendar: zoned) else { return NSNull() }
                let p = zoned.dateComponents([.year, .month, .day], from: read)
                return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
            case "zone_unset_opening", "zone_today_bounds", "zone_default_seed", "form_step_answer":
                // The phone in one zone and the app in another: the zone each date rule picks, through the REAL functions.
                let savedDefault = NSTimeZone.default, savedApp = AppDNA.appTimeZone
                NSTimeZone.default = TimeZone(identifier: o["device_zone"]?.stringValue ?? "UTC")!
                AppDNA.appTimeZone = TimeZone(identifier: o["app_zone"]?.stringValue ?? "UTC")!
                defer { NSTimeZone.default = savedDefault; AppDNA.appTimeZone = savedApp }
                let now = ISO8601.date(from: o["now"]?.stringValue ?? "") ?? Date()
                let mode = o["mode"]?.stringValue ?? "date"
                let zone = DateWheelPickerBlockView.wheelZone(mode: mode)
                func day(_ d: Date) -> String { DateRangeCalendarView.dayKey(d, in: zone) }
                switch o["op"]?.stringValue {
                case "zone_unset_opening":
                    var zoned = Calendar(identifier: .gregorian); zoned.timeZone = zone
                    let p = zoned.dateComponents([.year, .month, .day, .hour, .minute], from: DateWheelPickerBlockView.unsetOpening(now: now, zone: zone))
                    return String(format: "%04d-%02d-%02d %02d:%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
                case "zone_today_bounds":
                    let r = DateWheelPickerBlockView.dateRange(minDate: nil, maxDate: nil, allowPast: o["allow_past"]?.foundation as? Bool,
                                                               allowFuture: o["allow_future"]?.foundation as? Bool, now: now, zone: zone)
                    return [day(r.lowerBound), day(r.upperBound)]
                case "zone_default_seed":
                    return DateWheelPickerBlockView.parseDate(o["value"]?.stringValue, zone: zone, now: now).map(day).map { $0 as Any } ?? NSNull()
                default:
                    // The wall time the picker shows in the app zone, as the moment the form step's Date holds.
                    let wall = (o["wall"]?.stringValue ?? "").split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" }).compactMap { Int($0) }
                    var app = Calendar(identifier: .gregorian); app.timeZone = AnswerTime.zone
                    let picked = app.date(from: DateComponents(year: wall[0], month: wall[1], day: wall[2], hour: wall[3], minute: wall[4]))!
                    return FormStepView.formStepAnswer(picked, type: FormFieldType(rawValue: o["type"]?.stringValue ?? ""), zone: AnswerTime.zone)
                }
            default:
                XCTFail("[\(f.id)] unknown op")
                return NSNull()
            }
        }
    }

    func runOptionLabelMarkdown(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_option_label_markdown needs action.cases")
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
                  let option = holder.content_blocks?.first?.field_options?.first else {
                XCTFail("[\(f.id)] case \(name): the option did not decode")
                return NSNull()
            }
            let markdown = option.label_markdown ?? ""
            let target = markdown.components(separatedBy: "](").last?.components(separatedBy: ")").first ?? ""
            return ["label": option.label ?? "", "label_markdown": markdown, "color_hex": MarkdownText.colorRunHex(target) ?? ""] as [String: Any]
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
            return decoded.imageAccessibilityLabel.map { $0 as Any } ?? NSNull()
        }
    }

    // resolve_screen_image_alt REAL: `ScreenConfig` decoding of a screen with one image section →
    // `ScreenImageAccessibility.label(_:)`, the description `ImageSectionRenderer` hands VoiceOver (nil: hidden).
    func runScreenImageAlt(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_screen_image_alt needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let name = obj["name"]?.stringValue ?? "?"
            guard let sectionData = obj["data"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "id": "scr_alt_\(name)", "sections": [["id": "s1", "type": "image_section", "data": sectionData]],
                  ]) else {
                XCTFail("[\(f.id)] case \(name): needs data")
                return NSNull()
            }
            let screen: ScreenConfig
            do {
                screen = try JSONDecoder().decode(ScreenConfig.self, from: data)
            } catch {
                XCTFail("[\(f.id)] case \(name): the screen did not decode: \(error)")
                return NSNull()
            }
            guard let section = screen.sections?.first(where: { $0.type == "image_section" }) else {
                XCTFail("[\(f.id)] case \(name): the image section was dropped")
                return NSNull()
            }
            return ScreenImageAccessibility.label(section).map { $0 as Any } ?? NSNull()
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

    // resolve_rating_answer REAL: the lenient `[ContentBlock]` decode → `RatingAnswer` (key, initial, afterTap),
    // the calls `RatingBlockView` makes on each tap.
    func runRatingAnswer(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] resolve_rating_answer needs action.cases")
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
            guard let raw = obj["block"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [raw]]),
                  let block = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks?.first else {
                XCTFail("[\(f.id)] case \(name): the block did not decode")
                return NSNull()
            }
            let key = RatingAnswer.key(block)
            var values: [String: Any] = [:]
            if let s = obj["stored"]?.doubleValue { values[key] = s }
            var current = RatingAnswer.initial(block, stored: values[key])
            var written: Any = NSNull()
            for t in (obj["taps"]?.arrayValue ?? []).compactMap(\.doubleValue) {
                current = RatingAnswer.afterTap(current: current, tapped: Int(t), allowHalf: block.allow_half ?? false)
                written = current
            }
            return ["key": key, "stored": written] as [String: Any]
        }
    }

    // resolve_loading_variant REAL: the lenient `[ContentBlock]` decode → `AnimatedLoadingVariant.resolve`.
    /// `spinner: true` is `resolve_loading_spinner_colour`: the same decode, then `AnimatedLoadingVariant.spinnerHex`.
    func runLoadingVariant(_ f: Fixture, _ h: Harness, spinner: Bool = false) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] \(f.action.kind) needs action.cases")
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
            guard let raw = obj["block"]?.foundation as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["content_blocks": [raw]]),
                  let block = (try? JSONDecoder().decode(Holder.self, from: data))?.content_blocks?.first else {
                XCTFail("[\(f.id)] a case did not decode")
                return NSNull()
            }
            return spinner ? AnimatedLoadingVariant.spinnerHex(block) : AnimatedLoadingVariant.resolve(block)
        }
    }
}
