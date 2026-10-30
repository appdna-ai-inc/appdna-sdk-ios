// PaywallCacheRoundTripTests.swift
//
// `StepCacheRoundTripTests` round-trips an `OnboardingStep` through its cache and said plainly what it did not cover:
// `PaywallConfig`, and the root-then-`layout` ladder. This is that half.
//
// 🔴 IT DRIVES THE PRODUCTION WRITER, NOT A COPY OF IT. `RemoteConfigManager.cacheAllFetchedConfigs()`
// is the encoder every cached paywall really goes through, and a second manager built on the same
// `ConfigCache` runs the real `parsePaywalls` on the way back — sanitiser, decoder and all. A test
// that built its own `JSONEncoder` would prove that encoder correct and say nothing about the one
// that ships. (That writer was `private` until this test, which is why the encoder behind an earlier
// production defect had no test that could reach it at all.)
//
// What the cache-key SYNTAX gate cannot see and this does:
//   · a field encoded under the WRONG key — the keys still appear in the source;
//   · a field read back through a DIFFERENT LADDER than it was written to;
//   · a field transformed on the way out and not on the way back;
//   · a property WRAPPER (`@LenientArray`, `@LenientScalar`) that flattens what it wraps;
//   · a runtime-only value that must NOT be cached — `resolvedStorePrice`.
import XCTest
@testable import AppDNASDK

final class PaywallCacheRoundTripTests: XCTestCase {

    // MARK: - The document

    /**
     A paywall written the way a real one is, with every branch the renderer reads populated.

     🔴 PLANS LIVE IN THREE PLACES and the renderer takes whichever is present — root `plans`,
     top-level `sections[].config.plans`, and `layout.sections[].data.plans`. The store-price substitution proved that
     covering one of them is the same as covering none on a document that used another, so the
     round trip has to carry all three.

     Every value is distinguishable on purpose, for the reason `StepCacheRoundTripTests` gives: `true`/`1` collide
     across fields, so a swap between two of them would round-trip "correctly" and prove nothing.

     `__cache_marker` is a key no DTO knows. The typed encode therefore CANNOT reproduce it, which
     is how the test detects that the asynchronous re-cache has landed — instead of sleeping and
     hoping, which is the other way this test could have been written and the way it would lie.
     */
    private func serverDocument() -> [String: Any] {
        [
            "__cache_marker": "raw",
            "id": "p_round_trip",
            "name": "Round trip",
            "placement": "post_onboarding",
            "placement_label": "After onboarding",
            "version": 7,
            "default_locale": "en",
            // Root plans. `price` is a JSON NUMBER on the annual plan, which `looseString` coerces —
            // a transform, so the round trip has to be stable across it and not re-coerce.
            "plans": [
                [
                    "id": "plan_month", "product_id": "com.example.monthly",
                    "name": "Monthly", "price_display": "$9.99", "period": "month",
                    "sort_order": 1, "is_default": false, "badge": "Flexible",
                    "features": ["One", "Two"], "savings_text": "",
                    "price_color": "#112233", "display_mode": "text_only",
                    "text_only_font_size": 13.5,
                ],
                [
                    "id": "plan_year", "product_id": "com.example.annual",
                    "name": "Annual", "price": 49.99, "period": "year",
                    "sort_order": 2, "is_default": true, "use_store_price": false,
                    "trial": ["duration_days": 7, "label": "7-day free trial"],
                    "original_price_display": "$119.88",
                    "price_total_display": "$49.99 / year",
                    "description": "Best value",
                    "description_badge": ["enabled": true, "bg_color": "#00FF00",
                                          "text_color": "#000000", "corner_radius": 8],
                ],
            ],
            // Top-level sections — the `_sections` key.
            "sections": [
                [
                    "type": "header", "id": "sec_header", "zone": "body",
                    "collapse_on_scroll": true,
                    "config": ["title": "Top level header", "subtitle": "Sub"],
                ],
                [
                    "type": "plans", "id": "sec_plans_top",
                    "config": ["plans": [[
                        "id": "top_plan", "product_id": "com.example.top",
                        "price_display": "$1.11", "period": "week", "sort_order": 9,
                    ]]],
                ],
            ],
            "layout": [
                "type": "stack", "spacing": 12, "padding": 20, "footer_padding": 6,
                "plan_display_style": "radio_list",
                "sections": [
                    [
                        "type": "plans", "id": "sec_plans_layout", "zone": "bottom",
                        // `data`, not `config` — the OTHER of the two keys `PaywallSection`
                        // accepts, so the round trip has to keep them apart.
                        "data": ["plans": [[
                            "id": "layout_plan", "product_id": "com.example.layout",
                            "price_display": "$2.22", "period": "month", "sort_order": 3,
                        ]]],
                    ],
                    [
                        "type": "divider", "id": "sec_divider",
                        "config": ["style": "dashed", "thickness": 2, "color": "#CCCCCC"],
                    ],
                    [
                        // 🔴 A known bad shape: `config.style` written as a per-element MAP where the
                        // DTO declares a String. `@LenientScalar` keeps the section and drops the
                        // field; what matters here is that the cache does not RESURRECT it.
                        "type": "features", "id": "sec_features",
                        "config": ["title": "Features", "style": ["title": ["color": "#FFF"]]],
                    ],
                ],
            ],
            "cta": ["text": "Continue", "action": "purchase", "bg_color": "#FF0000"],
            "dismiss": ["allowed": true, "style": "x_button", "delay_seconds": 3,
                        "position": "top_left", "color": "#EEEEEE", "size": 18,
                        "back": ["enabled": true]],
            "background": [
                "type": "gradient",
                "color": "#000000",
                "gradient": ["type": "linear", "angle": 45, "stops": [
                    ["color": "#111111", "position": 0], ["color": "#222222", "position": 1],
                ]],
            ],
            "localizations": ["pl": ["cta": "Kontynuuj"]],
            "audience_rules": ["all": [["trait": "country", "op": "in", "value": ["US", "PL"]]]],
            "post_purchase": [
                "on_success": ["action": "show_message", "message": "Thanks", "confetti": true],
                "on_failure": ["action": "show_error", "message": "Sorry", "allow_dismiss": false],
            ],
        ]
    }

    // MARK: - The round trip

    private func makeManager(_ cache: ConfigCache) -> RemoteConfigManager {
        RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
    }

    /// Seed the raw document, parse it, run the REAL re-cache, and read it back with a second manager.
    private func roundTrip() throws -> (before: PaywallConfig, after: PaywallConfig, cached: Data) {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let raw = try JSONSerialization.data(withJSONObject: ["paywalls": ["p1": serverDocument()]])
        cache.storePaywalls(raw)

        let first = makeManager(cache)
        let before = try XCTUnwrap(first.getPaywallConfig(id: "p1"), "the seeded paywall did not parse")

        first.cacheAllFetchedConfigs()

        /*
         🔴 ASSERT THE HARNESS BEFORE ASSERTING THE SUBJECT. The write is dispatched onto the
         manager's own queue, so "the fields match" and "the re-cache never ran, and we compared the
         raw document with itself" are the same green. The marker is the discriminator: the typed
         encode cannot carry a key no DTO declares.
         */
        let deadline = Date().addingTimeInterval(5)
        var rewritten: Data?
        while Date() < deadline {
            if let d = cache.loadPaywalls(),
               !String(decoding: d, as: UTF8.self).contains("__cache_marker") {
                rewritten = d
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let cached = try XCTUnwrap(rewritten, "the production re-cache never wrote — nothing below is a round trip")

        let second = makeManager(cache)
        let after = try XCTUnwrap(second.getPaywallConfig(id: "p1"), "the re-cached paywall did not parse back")
        return (before, after, cached)
    }

    // MARK: - Tests

    func testTheDocumentLevelFieldsSurviveTheCache() throws {
        let (before, after, _) = try roundTrip()

        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.placement, before.placement, "placement")
        XCTAssertEqual(after.placement_label, before.placement_label, "placement_label")
        XCTAssertEqual(after.version, before.version, "version")
        XCTAssertEqual(after.default_locale, before.default_locale, "default_locale")
        XCTAssertEqual(after.localizations?["pl"]?["cta"], "Kontynuuj", "localizations")
        XCTAssertEqual(after.cta?.text, before.cta?.text, "cta.text")
        XCTAssertEqual(after.dismiss?.allowed, before.dismiss?.allowed, "dismiss.allowed")
        XCTAssertEqual(after.dismiss?.style, before.dismiss?.style, "dismiss.style")
        XCTAssertEqual(after.dismiss?.delaySeconds, before.dismiss?.delaySeconds, "delay_seconds")
        XCTAssertEqual(after.dismiss?.position, "top_left", "the dismiss placement")
        XCTAssertEqual(after.dismiss?.back?.enabled, before.dismiss?.back?.enabled, "the back button")
        XCTAssertEqual(after.background?.color, before.background?.color, "background.color")
        XCTAssertEqual(
            after.background?.gradient?.stops?.map(\.color),
            before.background?.gradient?.stops?.map(\.color),
            "the gradient stops",
        )
        XCTAssertEqual(after.post_purchase?.on_success?.action, before.post_purchase?.on_success?.action)
        XCTAssertEqual(after.post_purchase?.on_success?.message, "Thanks", "post_purchase.on_success")
        XCTAssertEqual(after.post_purchase?.on_success?.confetti, true)
        XCTAssertEqual(after.post_purchase?.on_failure?.allow_dismiss, false, "post_purchase.on_failure")
    }

    func testTheLayoutAndItsWrappedSectionsSurviveTheCache() throws {
        let (before, after, _) = try roundTrip()

        XCTAssertEqual(after.layout?.type, before.layout?.type, "layout.type")
        XCTAssertEqual(after.layout?.spacing, before.layout?.spacing, "layout.spacing")
        XCTAssertEqual(after.layout?.padding, before.layout?.padding, "layout.padding")
        XCTAssertEqual(after.layout?.footer_padding, before.layout?.footer_padding, "footer_padding")
        XCTAssertEqual(after.layout?.plan_display_style, before.layout?.plan_display_style)

        // `@LenientArray var sections` — a wrapper that flattened what it wraps would show here.
        XCTAssertEqual(after.layout?.sections?.count, before.layout?.sections?.count, "layout.sections count")
        XCTAssertEqual(after.layout?.sections?.map(\.type), before.layout?.sections?.map(\.type))
        XCTAssertEqual(after.layout?.sections?.map { $0.zone }, before.layout?.sections?.map { $0.zone }, "zone")

        // `@LenientScalar var lineStyle` — the divider's own `style` is a String and must survive.
        let dividerBefore = before.layout?.sections?.first { $0.type == "divider" }
        let dividerAfter = after.layout?.sections?.first { $0.type == "divider" }
        XCTAssertEqual(dividerBefore?.data?.lineStyle, "dashed", "the fixture's divider style")
        XCTAssertEqual(dividerAfter?.data?.lineStyle, dividerBefore?.data?.lineStyle, "divider style")
        XCTAssertEqual(dividerAfter?.data?.thickness, dividerBefore?.data?.thickness, "divider thickness")

        // And the map-shaped `style` stays dropped rather than coming back as something.
        let featuresAfter = after.layout?.sections?.first { $0.type == "features" }
        XCTAssertEqual(featuresAfter?.data?.title, "Features", "the section itself must survive")
        XCTAssertNil(featuresAfter?.data?.lineStyle, "a map-shaped style must not be resurrected as a String")
    }

    /// 🔴 The three places plans live, each read back from the key it was written to.
    func testPlansSurviveInAllTHREEPlacesTheRendererReadsThem() throws {
        let (before, after, _) = try roundTrip()

        // 1 — the document root.
        XCTAssertEqual(after.plans?.count, 2, "root plans count")
        XCTAssertEqual(after.plans?.map(\.id), before.plans?.map(\.id), "root plan ids")
        let monthBefore = try XCTUnwrap(before.plans?.first { $0.id == "plan_month" })
        let monthAfter = try XCTUnwrap(after.plans?.first { $0.id == "plan_month" })
        XCTAssertEqual(monthAfter.price_display, monthBefore.price_display)
        XCTAssertEqual(monthAfter.period, monthBefore.period)
        XCTAssertEqual(monthAfter.badge, monthBefore.badge)
        XCTAssertEqual(monthAfter.features, monthBefore.features)
        XCTAssertEqual(monthAfter.sort_order, monthBefore.sort_order)
        XCTAssertEqual(monthAfter.price_color, monthBefore.price_color, "the per-plan price colour")
        XCTAssertEqual(monthAfter.display_mode, monthBefore.display_mode)
        XCTAssertEqual(monthAfter.text_only_font_size, monthBefore.text_only_font_size)

        let yearBefore = try XCTUnwrap(before.plans?.first { $0.id == "plan_year" })
        let yearAfter = try XCTUnwrap(after.plans?.first { $0.id == "plan_year" })
        // A JSON NUMBER coerced to a String on the way in. The cache stores the STRING, so the
        // second decode must return the same thing rather than coercing again differently.
        XCTAssertEqual(yearBefore.price, "49.99", "the fixture's numeric price was coerced")
        XCTAssertEqual(yearAfter.price, yearBefore.price, "a coerced price must be stable across the cache")
        XCTAssertEqual(yearAfter.use_store_price, false, "the store-price opt-OUT must survive — nil would mean 'ask'")
        XCTAssertEqual(yearAfter.trialLabel, yearBefore.trialLabel, "the trial label")
        XCTAssertEqual(yearAfter.isDefault, true, "is_default")
        XCTAssertEqual(yearAfter.original_price_display, yearBefore.original_price_display)
        XCTAssertEqual(yearAfter.price_total_display, yearBefore.price_total_display)
        XCTAssertEqual(yearAfter.description, yearBefore.description)
        XCTAssertEqual(yearAfter.description_badge?.enabled, yearBefore.description_badge?.enabled)
        XCTAssertEqual(yearAfter.description_badge?.bg_color, yearBefore.description_badge?.bg_color)
        XCTAssertEqual(yearAfter.description_badge?.corner_radius, yearBefore.description_badge?.corner_radius)

        // 2 — a top-level `sections` entry, under its `config` key.
        let topPlans = after.sections.first { $0.type == "plans" && $0.id == "sec_plans_top" }?.data?.plans
        XCTAssertEqual(topPlans?.count, 1, "the top-level section's plans")
        XCTAssertEqual(topPlans?.first?.price_display, "$1.11")
        XCTAssertEqual(topPlans?.first?.period, "week")

        // 3 — a `layout.sections` entry, under its `data` key.
        let layoutPlans = after.layout?.sections?.first { $0.id == "sec_plans_layout" }?.data?.plans
        XCTAssertEqual(layoutPlans?.count, 1, "layout.sections' plans — where a real paywall keeps them")
        XCTAssertEqual(layoutPlans?.first?.price_display, "$2.22")
        XCTAssertEqual(layoutPlans?.first?.product_id_forTest, "com.example.layout")
    }

    /**
     🔴 THE CONTROL THAT MAKES THE ONES ABOVE MEAN SOMETHING.

     A round trip that returned an EMPTY paywall would satisfy every `XCTAssertEqual(after.x, before.x)`
     where `before.x` happened to be nil too — the false green the accessibility-tree read once gave
     a store-price test. So the decoded paywall must differ from a bare one in every field the fixture set.
     */
    func testTheRoundTrippedPaywallIsNotJustAnEmptyPaywall() throws {
        let (_, after, _) = try roundTrip()
        let bare = try JSONDecoder().decode(
            PaywallConfig.self, from: Data(#"{ "id": "bare" }"#.utf8))

        XCTAssertNil(bare.plans)
        XCTAssertNotNil(after.plans)
        XCTAssertNotEqual(after.version, bare.version)
        XCTAssertNotEqual(after.placement, bare.placement)
        XCTAssertNil(bare.layout)
        XCTAssertNotNil(after.layout?.sections)
        XCTAssertTrue(bare.sections.isEmpty)
        XCTAssertFalse(after.sections.isEmpty)
        XCTAssertNil(bare.cta)
        XCTAssertNotNil(after.cta)
    }

    /// `audience_rules` is `AnyCodable` — a nested array of dictionaries that the cache has to carry
    /// verbatim, because the SDK evaluates it and a lost operand changes who sees the paywall.
    func testTheAnyCodableAudienceRulesSurviveTheCache() throws {
        let (before, after, _) = try roundTrip()
        // 🔴 `.sortedKeys`, because a Swift dictionary has no order and the first version of this
        // test failed on `{"op","trait","value"}` vs `{"value","trait","op"}` — identical content,
        // different iteration. A comparison that is sensitive to something the subject does not
        // control is a flaky test, not a strict one.
        func normalised(_ v: AnyCodable?) throws -> String {
            let e = JSONEncoder()
            e.outputFormatting = .sortedKeys
            return String(decoding: try e.encode(try XCTUnwrap(v)), as: UTF8.self)
        }
        XCTAssertTrue(try normalised(before.audience_rules).contains("country"), "the fixture really set rules")
        XCTAssertEqual(try normalised(after.audience_rules), try normalised(before.audience_rules))
    }

    /**
     🔴 `resolvedStorePrice` IS A RUNTIME LOOKUP AND MUST NOT BE CACHED.

     It is filled in by the presenter from a live StoreKit query. A cache that persisted it
     would show YESTERDAY'S price on a cold start with no lookup at all — which is the stale-price defect
     already fixed, reintroduced through the cache. The guarantee is structural (the field is deliberately
     absent from `CodingKeys`, so the encoder cannot write it), and this is the test that says so
     out loud — and would fail the moment someone "completed" that enum.

     The encoder here is a plain `JSONEncoder`, which is exactly the one `cacheAllFetchedConfigs`
     constructs; the priced copy is a value the manager never holds, so it cannot be seeded through it.
     */
    func testAStorePriceIsNEVERWrittenIntoTheCache() throws {
        let (before, _, cachedBytes) = try roundTrip()
        let priced = before.applyingStorePrices([
            "com.example.monthly": "PLN 39,99",
            "com.example.layout": "PLN 9,99",
        ])
        // The fixture must really be priced, or the assertion below is vacuous.
        XCTAssertEqual(priced.plans?.first { $0.id == "plan_month" }?.resolvedStorePrice, "PLN 39,99")
        XCTAssertEqual(
            priced.layout?.sections?.first { $0.id == "sec_plans_layout" }?.data?.plans?.first?.resolvedStorePrice,
            "PLN 9,99", "and in layout.sections too — where real paywalls keep their plans")

        let data = try JSONEncoder().encode(priced)
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("PLN"),
            "a store price reached the encoded cache — a cold start would then serve a stale price")

        let back = try JSONDecoder().decode(PaywallConfig.self, from: data)
        XCTAssertNil(back.plans?.first { $0.id == "plan_month" }?.resolvedStorePrice,
                     "the store price must come back nil so the presenter asks again")
        XCTAssertNil(
            back.layout?.sections?.first { $0.id == "sec_plans_layout" }?.data?.plans?.first?.resolvedStorePrice)
        // Everything else on the priced copy still survives — the exclusion is one field, not a hole.
        XCTAssertEqual(back.plans?.first { $0.id == "plan_month" }?.price_display, "$9.99")

        // And the production-written cache never carried one either.
        XCTAssertFalse(String(decoding: cachedBytes, as: UTF8.self).contains("resolvedStorePrice"))
    }
}

/// `product_id` is `private`-free but reads better named at the call site above.
private extension PaywallPlan {
    var product_id_forTest: String? { productId }
}
