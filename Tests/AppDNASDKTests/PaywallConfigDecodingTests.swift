import XCTest
@testable import AppDNASDK

final class PaywallConfigDecodingTests: XCTestCase {

    // MARK: - Full config decoding

    func testDecodeFullPaywallConfig() throws {
        let json = """
        {
            "id": "annual_promo",
            "name": "Annual Promotion",
            "layout": {
                "type": "stack",
                "spacing": 16,
                "padding": 20
            },
            "sections": [
                {
                    "type": "header",
                    "data": {
                        "title": "Unlock Premium",
                        "subtitle": "Get access to all features",
                        "image_url": "https://example.com/header.png"
                    }
                },
                {
                    "type": "features",
                    "data": {
                        "features": ["Unlimited access", "No ads", "Priority support"]
                    }
                },
                {
                    "type": "plans",
                    "data": {
                        "plans": [
                            {
                                "id": "annual",
                                "product_id": "com.app.annual",
                                "name": "Annual",
                                "price": "$49.99",
                                "period": "year",
                                "badge": "Best Value",
                                "trial_duration": "7 days",
                                "is_default": true
                            },
                            {
                                "id": "monthly",
                                "product_id": "com.app.monthly",
                                "name": "Monthly",
                                "price": "$9.99",
                                "period": "month",
                                "is_default": false
                            }
                        ]
                    }
                },
                {
                    "type": "cta",
                    "data": {
                        "cta": {
                            "text": "Start Free Trial",
                            "style": "primary"
                        }
                    }
                },
                {
                    "type": "social_proof",
                    "data": {
                        "rating": 4.8,
                        "review_count": 12500,
                        "testimonial": "Best app I've ever used!"
                    }
                }
            ],
            "dismiss": {
                "type": "x_button",
                "delay_seconds": 3
            },
            "background": {
                "type": "gradient",
                "colors": ["#1a1a2e", "#16213e"]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PaywallConfig.self, from: json)

        XCTAssertEqual(config.id, "annual_promo")
        XCTAssertEqual(config.name, "Annual Promotion")
        XCTAssertEqual(config.layout?.type, "stack")
        XCTAssertEqual(config.layout?.spacing, 16)
        XCTAssertEqual(config.sections.count, 5)
    }

    // MARK: - Section types

    func testDecodeHeaderSection() throws {
        let json = """
        {
            "type": "header",
            "data": {
                "title": "Welcome",
                "subtitle": "Choose your plan",
                "image_url": "https://example.com/img.png"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "header")
        XCTAssertEqual(section.data?.title, "Welcome")
        XCTAssertEqual(section.data?.subtitle, "Choose your plan")
        XCTAssertEqual(section.data?.imageUrl, "https://example.com/img.png")
    }

    func testDecodeFeaturesSection() throws {
        let json = """
        {
            "type": "features",
            "data": {
                "features": ["Feature A", "Feature B", "Feature C"]
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "features")
        XCTAssertEqual(section.data?.features?.count, 3)
        XCTAssertEqual(section.data?.features?.first, "Feature A")
    }

    func testDecodePlansSection() throws {
        let json = """
        {
            "type": "plans",
            "data": {
                "plans": [
                    {
                        "id": "plan_1",
                        "product_id": "com.app.plan1",
                        "name": "Basic",
                        "price": "$4.99",
                        "period": "month"
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.data?.plans?.count, 1)
        XCTAssertEqual(section.data?.plans?.first?.productId, "com.app.plan1")
        XCTAssertEqual(section.data?.plans?.first?.price, "$4.99")
    }

    func testDecodeSocialProofSection() throws {
        let json = """
        {
            "type": "social_proof",
            "data": {
                "rating": 4.7,
                "review_count": 5000,
                "testimonial": "Amazing app!"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.data?.rating, 4.7)
        XCTAssertEqual(section.data?.reviewCount, 5000)
        XCTAssertEqual(section.data?.testimonial, "Amazing app!")
    }

    // MARK: - Optional fields

    func testDecodeWithMissingOptionalFields() throws {
        let json = """
        {
            "id": "minimal",
            "name": "Minimal Paywall",
            "layout": { "type": "stack" },
            "sections": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PaywallConfig.self, from: json)
        XCTAssertEqual(config.id, "minimal")
        XCTAssertNil(config.dismiss)
        XCTAssertNil(config.background)
        XCTAssertNil(config.layout?.spacing)
        XCTAssertTrue(config.sections.isEmpty)
    }

    func testDecodePlanWithMissingOptionalFields() throws {
        let json = """
        {
            "id": "plan_basic",
            "product_id": "com.app.basic",
            "name": "Basic",
            "price": "$0.99"
        }
        """.data(using: .utf8)!

        let plan = try JSONDecoder().decode(PaywallPlan.self, from: json)
        XCTAssertEqual(plan.id, "plan_basic")
        XCTAssertNil(plan.period)
        XCTAssertNil(plan.badge)
        XCTAssertNil(plan.trialLabel)
        XCTAssertNil(plan.isDefault)
    }

    // MARK: - Dismiss config

    func testDecodeDismissWithDelay() throws {
        let json = """
        {
            "type": "x_button",
            "delay_seconds": 5,
            "text": "Close"
        }
        """.data(using: .utf8)!

        let dismiss = try JSONDecoder().decode(PaywallDismiss.self, from: json)
        XCTAssertEqual(dismiss.style, "x_button")
        XCTAssertEqual(dismiss.delaySeconds, 5)
        XCTAssertEqual(dismiss.text, "Close")
        XCTAssertTrue(dismiss.isAllowed) // defaults to true when not present
    }

    // MARK: - Background config

    func testDecodeGradientBackground() throws {
        let json = """
        {
            "type": "gradient",
            "colors": ["#FF0000", "#0000FF"]
        }
        """.data(using: .utf8)!

        let bg = try JSONDecoder().decode(PaywallBackground.self, from: json)
        XCTAssertEqual(bg.type, "gradient")
        XCTAssertEqual(bg.colors?.count, 2)
    }

    func testDecodeColorBackground() throws {
        let json = """
        {
            "type": "color",
            "value": "#1a1a2e"
        }
        """.data(using: .utf8)!

        let bg = try JSONDecoder().decode(PaywallBackground.self, from: json)
        XCTAssertEqual(bg.type, "color")
        XCTAssertEqual(bg.value, "#1a1a2e")
    }

    // MARK: - Section Types

    // 1. Guarantee section
    func testDecodeGuaranteeSection() throws {
        let json = """
        {
            "type": "guarantee",
            "data": {
                "guarantee_text": "30-day money-back guarantee"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "guarantee")
        XCTAssertEqual(section.data?.guaranteeText, "30-day money-back guarantee")
    }

    // 2. Image section
    func testDecodeImageSection() throws {
        let json = """
        {
            "type": "image",
            "data": {
                "image_url": "https://example.com/hero.png",
                "height": 200,
                "corner_radius": 12
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "image")
        XCTAssertEqual(section.data?.imageUrl, "https://example.com/hero.png")
        XCTAssertEqual(section.data?.height, 200)
        XCTAssertEqual(section.data?.cornerRadius, 12)
    }

    // 3. Spacer section
    func testDecodeSpacerSection() throws {
        let json = """
        {
            "type": "spacer",
            "data": {
                "spacer_height": 24
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "spacer")
        XCTAssertEqual(section.data?.spacerHeight, 24)
    }

    // 4. Testimonial section
    func testDecodeTestimonialSection() throws {
        let json = """
        {
            "type": "testimonial",
            "data": {
                "quote": "This app changed my life!",
                "author_name": "Jane Doe",
                "author_role": "CEO, Acme Inc.",
                "avatar_url": "https://example.com/avatar.png"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "testimonial")
        XCTAssertEqual(section.data?.quote, "This app changed my life!")
        XCTAssertEqual(section.data?.authorName, "Jane Doe")
        XCTAssertEqual(section.data?.authorRole, "CEO, Acme Inc.")
        XCTAssertEqual(section.data?.avatarUrl, "https://example.com/avatar.png")
    }

    // 5. Lottie section
    func testDecodeLottieSection() throws {
        let json = """
        {
            "type": "lottie",
            "data": {
                "lottie_url": "https://example.com/anim.json",
                "lottie_loop": true,
                "lottie_speed": 1.5,
                "lottie_height": 180
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "lottie")
        XCTAssertEqual(section.data?.lottieUrl, "https://example.com/anim.json")
        XCTAssertEqual(section.data?.lottieLoop, true)
        XCTAssertEqual(section.data?.lottieSpeed, 1.5)
        XCTAssertEqual(section.data?.lottieHeight, 180)
    }

    // 6. Video section
    func testDecodeVideoSection() throws {
        let json = """
        {
            "type": "video",
            "data": {
                "video_url": "https://example.com/promo.mp4",
                "video_thumbnail_url": "https://example.com/thumb.png",
                "video_height": 220
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "video")
        XCTAssertEqual(section.data?.videoUrl, "https://example.com/promo.mp4")
        XCTAssertEqual(section.data?.videoThumbnailUrl, "https://example.com/thumb.png")
        XCTAssertEqual(section.data?.videoHeight, 220)
    }

    // 7. Rive section
    func testDecodeRiveSection() throws {
        let json = """
        {
            "type": "rive",
            "data": {
                "rive_url": "https://example.com/animation.riv",
                "rive_state_machine": "State Machine 1"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "rive")
        XCTAssertEqual(section.data?.riveUrl, "https://example.com/animation.riv")
        XCTAssertEqual(section.data?.riveStateMachine, "State Machine 1")
    }

    // 8. Countdown section (all fields)
    func testDecodeCountdownSection() throws {
        let json = """
        {
            "type": "countdown",
            "data": {
                "variant": "digital",
                "duration_seconds": 900,
                "target_datetime": "2026-04-01T00:00:00Z",
                "show_days": false,
                "show_hours": true,
                "show_minutes": true,
                "show_seconds": true,
                "labels": {
                    "hours": "hrs",
                    "minutes": "min",
                    "seconds": "sec"
                },
                "on_expire_action": "show_expired_text",
                "expired_text": "Offer expired!",
                "accent_color": "#FF6B35",
                "background_color": "#1A1A2E",
                "font_size": 28,
                "alignment": "center"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "countdown")
        XCTAssertEqual(section.data?.variant, "digital")
        XCTAssertEqual(section.data?.durationSeconds, 900)
        XCTAssertEqual(section.data?.targetDatetime, "2026-04-01T00:00:00Z")
        XCTAssertEqual(section.data?.showDays, false)
        XCTAssertEqual(section.data?.showHours, true)
        XCTAssertEqual(section.data?.showMinutes, true)
        XCTAssertEqual(section.data?.showSeconds, true)
        XCTAssertEqual(section.data?.labels?["hours"], "hrs")
        XCTAssertEqual(section.data?.labels?["minutes"], "min")
        XCTAssertEqual(section.data?.labels?["seconds"], "sec")
        XCTAssertEqual(section.data?.onExpireAction, "show_expired_text")
        XCTAssertEqual(section.data?.expiredText, "Offer expired!")
        XCTAssertEqual(section.data?.accentColor, "#FF6B35")
        XCTAssertEqual(section.data?.backgroundColor, "#1A1A2E")
        XCTAssertEqual(section.data?.fontSize, 28)
        XCTAssertEqual(section.data?.alignment, "center")
    }

    // 9. Countdown circular variant
    func testDecodeCountdownCircularVariant() throws {
        let json = """
        {
            "type": "countdown",
            "data": {
                "variant": "circular",
                "duration_seconds": 3600,
                "show_hours": true,
                "show_minutes": true,
                "show_seconds": false,
                "accent_color": "#00C853"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "countdown")
        XCTAssertEqual(section.data?.variant, "circular")
        XCTAssertEqual(section.data?.durationSeconds, 3600)
        XCTAssertEqual(section.data?.showSeconds, false)
    }

    // 10. Legal section
    func testDecodeLegalSection() throws {
        let json = """
        {
            "type": "legal",
            "data": {
                "color": "#888888",
                "links": [
                    { "label": "Terms of Service", "url": "https://example.com/tos" },
                    { "label": "Privacy Policy", "url": "https://example.com/privacy" }
                ]
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "legal")
        XCTAssertEqual(section.data?.color, "#888888")
        XCTAssertEqual(section.data?.links?.count, 2)
        XCTAssertEqual(section.data?.links?[0].label, "Terms of Service")
        XCTAssertEqual(section.data?.links?[0].url, "https://example.com/tos")
        XCTAssertEqual(section.data?.links?[1].label, "Privacy Policy")
        XCTAssertEqual(section.data?.links?[1].url, "https://example.com/privacy")
    }

    // 11. Divider section (all fields) — NOTE: lineStyle maps to JSON "style"
    func testDecodeDividerSectionAllFields() throws {
        let json = """
        {
            "type": "divider",
            "data": {
                "thickness": 2,
                "style": "dashed",
                "margin_top": 16,
                "margin_bottom": 16,
                "margin_horizontal": 20,
                "label_text": "OR",
                "label_color": "#FFFFFF",
                "label_bg_color": "#333333",
                "label_font_size": 12
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "divider")
        XCTAssertEqual(section.data?.thickness, 2)
        XCTAssertEqual(section.data?.lineStyle, "dashed")
        XCTAssertEqual(section.data?.marginTop, 16)
        XCTAssertEqual(section.data?.marginBottom, 16)
        XCTAssertEqual(section.data?.marginHorizontal, 20)
        XCTAssertEqual(section.data?.labelText, "OR")
        XCTAssertEqual(section.data?.labelColor, "#FFFFFF")
        XCTAssertEqual(section.data?.labelBgColor, "#333333")
        XCTAssertEqual(section.data?.labelFontSize, 12)
    }

    // 12. Divider minimal
    func testDecodeDividerMinimal() throws {
        let json = """
        {
            "type": "divider",
            "data": {
                "thickness": 1
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "divider")
        XCTAssertEqual(section.data?.thickness, 1)
        XCTAssertNil(section.data?.lineStyle)
        XCTAssertNil(section.data?.labelText)
        XCTAssertNil(section.data?.marginTop)
    }

    // 13. Sticky footer section (all fields)
    func testDecodeStickyFooterSection() throws {
        let json = """
        {
            "type": "sticky_footer",
            "data": {
                "cta_text": "Subscribe Now",
                "cta_bg_color": "#FF6B35",
                "cta_text_color": "#FFFFFF",
                "cta_corner_radius": 12,
                "secondary_text": "Restore Purchases",
                "secondary_action": "restore",
                "secondary_url": "https://example.com/restore",
                "legal_text": "Cancel anytime. Recurring billing.",
                "blur_background": true,
                "padding": 16
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "sticky_footer")
        XCTAssertEqual(section.data?.ctaText, "Subscribe Now")
        XCTAssertEqual(section.data?.ctaBgColor, "#FF6B35")
        XCTAssertEqual(section.data?.ctaTextColor, "#FFFFFF")
        XCTAssertEqual(section.data?.ctaCornerRadius, 12)
        XCTAssertEqual(section.data?.secondaryText, "Restore Purchases")
        XCTAssertEqual(section.data?.secondaryAction, "restore")
        XCTAssertEqual(section.data?.secondaryUrl, "https://example.com/restore")
        XCTAssertEqual(section.data?.legalText, "Cancel anytime. Recurring billing.")
        XCTAssertEqual(section.data?.blurBackground, true)
        XCTAssertEqual(section.data?.padding, 16)
    }

    // 14. Carousel section (all fields)
    func testDecodeCarouselSection() throws {
        let json = """
        {
            "type": "carousel",
            "data": {
                "pages": [
                    {
                        "id": "page_1",
                        "children": [
                            {
                                "type": "header",
                                "data": { "title": "Slide 1" }
                            }
                        ]
                    },
                    {
                        "id": "page_2",
                        "children": [
                            {
                                "type": "features",
                                "data": { "features": ["A", "B"] }
                            }
                        ]
                    }
                ],
                "auto_scroll": true,
                "auto_scroll_interval_ms": 3000,
                "show_indicators": true,
                "indicator_color": "#CCCCCC",
                "indicator_active_color": "#FF6B35"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "carousel")
        XCTAssertEqual(section.data?.pages?.count, 2)
        XCTAssertEqual(section.data?.pages?[0].id, "page_1")
        XCTAssertEqual(section.data?.pages?[1].id, "page_2")
        XCTAssertEqual(section.data?.autoScroll, true)
        XCTAssertEqual(section.data?.autoScrollIntervalMs, 3000)
        XCTAssertEqual(section.data?.showIndicators, true)
        XCTAssertEqual(section.data?.indicatorColor, "#CCCCCC")
        XCTAssertEqual(section.data?.indicatorActiveColor, "#FF6B35")
    }

    // 15. Timeline section (all fields)
    func testDecodeTimelineSection() throws {
        let json = """
        {
            "type": "timeline",
            "data": {
                "items": [
                    { "id": "step_1", "title": "Sign Up", "subtitle": "Create your account", "icon": "person.fill", "status": "completed" },
                    { "id": "step_2", "title": "Choose Plan", "subtitle": "Select a subscription", "icon": "creditcard.fill", "status": "current" },
                    { "id": "step_3", "title": "Enjoy", "subtitle": "Unlock all features", "icon": "star.fill", "status": "upcoming" }
                ],
                "line_color": "#DDDDDD",
                "completed_color": "#00C853",
                "current_color": "#FF6B35",
                "upcoming_color": "#999999",
                "show_line": true,
                "compact": false
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "timeline")
        XCTAssertEqual(section.data?.items?.count, 3)
        XCTAssertEqual(section.data?.items?[0].id, "step_1")
        XCTAssertEqual(section.data?.items?[0].title, "Sign Up")
        XCTAssertEqual(section.data?.items?[0].subtitle, "Create your account")
        XCTAssertEqual(section.data?.items?[0].icon, "person.fill")
        XCTAssertEqual(section.data?.items?[0].status, "completed")
        XCTAssertEqual(section.data?.items?[1].status, "current")
        XCTAssertEqual(section.data?.items?[2].status, "upcoming")
        XCTAssertEqual(section.data?.lineColor, "#DDDDDD")
        XCTAssertEqual(section.data?.completedColor, "#00C853")
        XCTAssertEqual(section.data?.currentColor, "#FF6B35")
        XCTAssertEqual(section.data?.upcomingColor, "#999999")
        XCTAssertEqual(section.data?.showLine, true)
        XCTAssertEqual(section.data?.compact, false)
    }

    // 16. Icon grid section
    func testDecodeIconGridSection() throws {
        let json = """
        {
            "type": "icon_grid",
            "data": {
                "items": [
                    { "icon": "bolt.fill", "label": "Fast", "description": "Lightning-fast performance" },
                    { "icon": "lock.fill", "label": "Secure", "description": "Bank-level encryption" },
                    { "icon": "cloud.fill", "label": "Cloud", "description": "Sync everywhere" },
                    { "icon": "sparkles", "label": "AI", "description": "Smart suggestions" }
                ],
                "columns": 2,
                "icon_size": 32,
                "icon_color": "#FF6B35",
                "spacing": 12
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "icon_grid")
        XCTAssertEqual(section.data?.items?.count, 4)
        XCTAssertEqual(section.data?.items?[0].icon, "bolt.fill")
        XCTAssertEqual(section.data?.items?[0].label, "Fast")
        XCTAssertEqual(section.data?.items?[0].description, "Lightning-fast performance")
        XCTAssertEqual(section.data?.columns?.value as? Int, 2)
        XCTAssertEqual(section.data?.iconSize, 32)
        XCTAssertEqual(section.data?.iconColor, "#FF6B35")
        XCTAssertEqual(section.data?.spacing, 12)
    }

    // 17. Comparison table section — NOTE: tableColumns maps to "table_columns", tableRows maps to "rows"
    func testDecodeComparisonTableSection() throws {
        let json = """
        {
            "type": "comparison_table",
            "data": {
                "table_columns": [
                    { "label": "Free", "highlighted": false },
                    { "label": "Pro", "highlighted": true }
                ],
                "rows": [
                    { "feature": "Basic features", "values": ["check", "check"] },
                    { "feature": "Advanced AI", "values": ["cross", "check"] },
                    { "feature": "Priority support", "values": ["cross", "check"] }
                ],
                "check_color": "#00C853",
                "cross_color": "#FF1744",
                "highlight_color": "#FF6B35",
                "border_color": "#333333"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "comparison_table")
        XCTAssertEqual(section.data?.tableColumns?.count, 2)
        XCTAssertEqual(section.data?.tableColumns?[0].label, "Free")
        XCTAssertEqual(section.data?.tableColumns?[0].highlighted, false)
        XCTAssertEqual(section.data?.tableColumns?[1].label, "Pro")
        XCTAssertEqual(section.data?.tableColumns?[1].highlighted, true)
        XCTAssertEqual(section.data?.tableRows?.count, 3)
        XCTAssertEqual(section.data?.tableRows?[0].feature, "Basic features")
        XCTAssertEqual(section.data?.tableRows?[0].values, ["check", "check"])
        XCTAssertEqual(section.data?.tableRows?[1].feature, "Advanced AI")
        XCTAssertEqual(section.data?.tableRows?[1].values, ["cross", "check"])
        XCTAssertEqual(section.data?.checkColor, "#00C853")
        XCTAssertEqual(section.data?.crossColor, "#FF1744")
        XCTAssertEqual(section.data?.highlightColor, "#FF6B35")
        XCTAssertEqual(section.data?.borderColor, "#333333")
    }

    // 18. Promo input section
    func testDecodePromoInputSection() throws {
        let json = """
        {
            "type": "promo_input",
            "data": {
                "placeholder": "Enter promo code",
                "button_text": "Apply",
                "success_text": "Code applied!",
                "error_text": "Invalid code"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "promo_input")
        XCTAssertEqual(section.data?.placeholder, "Enter promo code")
        XCTAssertEqual(section.data?.buttonText, "Apply")
        XCTAssertEqual(section.data?.successText, "Code applied!")
        XCTAssertEqual(section.data?.errorText, "Invalid code")
    }

    // 19. Toggle section (all fields) — NOTE: labelColorVal maps to JSON "toggle_label_color"
    func testDecodeToggleSectionAllFields() throws {
        let json = """
        {
            "type": "toggle",
            "data": {
                "label": "Annual billing",
                "description": "Save 40% with annual plan",
                "default_value": true,
                "on_color": "#00C853",
                "off_color": "#999999",
                "toggle_label_color": "#FFFFFF",
                "description_color": "#AAAAAA",
                "icon": "calendar",
                "affects_price": true
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "toggle")
        XCTAssertEqual(section.data?.label, "Annual billing")
        XCTAssertEqual(section.data?.description, "Save 40% with annual plan")
        XCTAssertEqual(section.data?.defaultValue, true)
        XCTAssertEqual(section.data?.onColor, "#00C853")
        XCTAssertEqual(section.data?.offColor, "#999999")
        XCTAssertEqual(section.data?.labelColorVal, "#FFFFFF")
        XCTAssertEqual(section.data?.descriptionColor, "#AAAAAA")
        XCTAssertEqual(section.data?.icon, "calendar")
        XCTAssertEqual(section.data?.affectsPrice, true)
    }

    // 20. Reviews carousel section
    func testDecodeReviewsCarouselSection() throws {
        let json = """
        {
            "type": "reviews_carousel",
            "data": {
                "reviews": [
                    {
                        "text": "Best app ever!",
                        "author": "John D.",
                        "rating": 5.0,
                        "avatar_url": "https://example.com/john.png",
                        "date": "2026-03-01"
                    },
                    {
                        "text": "Worth every penny.",
                        "author": "Sarah M.",
                        "rating": 4.5,
                        "avatar_url": "https://example.com/sarah.png",
                        "date": "2026-02-28"
                    }
                ],
                "show_rating_stars": true,
                "star_color": "#FFD700"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "reviews_carousel")
        XCTAssertEqual(section.data?.reviews?.count, 2)
        XCTAssertEqual(section.data?.reviews?[0].text, "Best app ever!")
        XCTAssertEqual(section.data?.reviews?[0].author, "John D.")
        XCTAssertEqual(section.data?.reviews?[0].rating, 5.0)
        XCTAssertEqual(section.data?.reviews?[0].avatarUrl, "https://example.com/john.png")
        XCTAssertEqual(section.data?.reviews?[0].date, "2026-03-01")
        XCTAssertEqual(section.data?.reviews?[1].author, "Sarah M.")
        XCTAssertEqual(section.data?.showRatingStars, true)
        XCTAssertEqual(section.data?.starColor, "#FFD700")
    }

    // 21. CTA section
    func testDecodeCTASection() throws {
        let json = """
        {
            "type": "cta",
            "data": {
                "cta": {
                    "text": "Start Free Trial",
                    "style": "primary"
                }
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "cta")
        XCTAssertEqual(section.data?.cta?.text, "Start Free Trial")
        // "style": "primary" is a legacy string value — styleObj is nil (only objects decode)
        XCTAssertNil(section.data?.cta?.styleObj)
    }

    // 21b. CTA with style object (console format)
    func testDecodeCTAWithStyleObject() throws {
        let json = """
        {
            "text": "Subscribe Now",
            "style": {
                "bg_color": "#6366f1",
                "text_color": "#ffffff",
                "corner_radius": 14
            }
        }
        """.data(using: .utf8)!

        let cta = try JSONDecoder().decode(PaywallCTA.self, from: json)
        XCTAssertEqual(cta.text, "Subscribe Now")
        XCTAssertEqual(cta.styleObj?.bg_color, "#6366f1")
        XCTAssertEqual(cta.styleObj?.text_color, "#ffffff")
        XCTAssertEqual(cta.styleObj?.corner_radius, 14)
        XCTAssertEqual(cta.resolvedBgColor, "#6366f1")
        XCTAssertEqual(cta.resolvedTextColor, "#ffffff")
        XCTAssertEqual(cta.resolvedCornerRadius, 14)
    }

    // 21c. CTA with direct color fields (fallback)
    func testDecodeCTAWithDirectFields() throws {
        let json = """
        {
            "text": "Buy",
            "bg_color": "#FF0000",
            "text_color": "#000000",
            "corner_radius": 8
        }
        """.data(using: .utf8)!

        let cta = try JSONDecoder().decode(PaywallCTA.self, from: json)
        XCTAssertNil(cta.styleObj)
        XCTAssertEqual(cta.resolvedBgColor, "#FF0000")
        XCTAssertEqual(cta.resolvedTextColor, "#000000")
        XCTAssertEqual(cta.resolvedCornerRadius, 8)
    }

    // 21d. Dismiss with allowed=false
    func testDecodeDismissAllowedFalse() throws {
        let json = """
        {
            "allowed": false,
            "style": "x_button",
            "delay_seconds": 0
        }
        """.data(using: .utf8)!

        let dismiss = try JSONDecoder().decode(PaywallDismiss.self, from: json)
        XCTAssertFalse(dismiss.isAllowed)
        XCTAssertEqual(dismiss.style, "x_button")
    }

    // 21e. Plan identity uses product_id
    func testPlanIdFallsBackToProductId() throws {
        let json = """
        {
            "product_id": "com.app.yearly",
            "label": "Yearly",
            "price_display": "$49.99",
            "is_default": true,
            "sort_order": 0
        }
        """.data(using: .utf8)!

        let plan = try JSONDecoder().decode(PaywallPlan.self, from: json)
        XCTAssertEqual(plan.id, "com.app.yearly")
        XCTAssertEqual(plan.displayName, "Yearly")
        XCTAssertEqual(plan.displayPrice, "$49.99")
    }

    // 21f. Plan trial object format
    func testDecodePlanTrialObject() throws {
        let json = """
        {
            "product_id": "com.app.monthly",
            "label": "Monthly",
            "price_display": "$9.99",
            "is_default": false,
            "sort_order": 1,
            "trial": { "duration_days": 7, "label": "7-day free trial" }
        }
        """.data(using: .utf8)!

        let plan = try JSONDecoder().decode(PaywallPlan.self, from: json)
        XCTAssertEqual(plan.trial?.duration_days, 7)
        XCTAssertEqual(plan.trialLabel, "7-day free trial")
    }

    // 22. Unknown section type does not crash
    func testDecodeUnknownSectionType() throws {
        let json = """
        {
            "type": "future_section",
            "data": {
                "title": "Some future content"
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "future_section")
        XCTAssertEqual(section.data?.title, "Some future content")
    }

    // 23. Section with no data (null data)
    func testDecodeSectionWithNullData() throws {
        let json = """
        {
            "type": "spacer"
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "spacer")
        XCTAssertNil(section.data)
    }

    // 24. Carousel with nested sections (header + features children)
    func testDecodeCarouselWithNestedSections() throws {
        let json = """
        {
            "type": "carousel",
            "data": {
                "pages": [
                    {
                        "id": "intro_page",
                        "children": [
                            {
                                "type": "header",
                                "data": {
                                    "title": "Welcome",
                                    "subtitle": "Discover premium features"
                                }
                            },
                            {
                                "type": "features",
                                "data": {
                                    "features": ["Unlimited storage", "No ads", "Offline mode"]
                                }
                            }
                        ]
                    }
                ],
                "show_indicators": true
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "carousel")
        XCTAssertEqual(section.data?.pages?.count, 1)

        let page = section.data?.pages?[0]
        XCTAssertEqual(page?.id, "intro_page")
        XCTAssertEqual(page?.children?.count, 2)
        XCTAssertEqual(page?.children?[0].type, "header")
        XCTAssertEqual(page?.children?[0].data?.title, "Welcome")
        XCTAssertEqual(page?.children?[0].data?.subtitle, "Discover premium features")
        XCTAssertEqual(page?.children?[1].type, "features")
        XCTAssertEqual(page?.children?[1].data?.features, ["Unlimited storage", "No ads", "Offline mode"])
    }

    // 25. PaywallReview decoded individually
    func testDecodePaywallReview() throws {
        let json = """
        {
            "text": "Absolutely incredible app!",
            "author": "Alex K.",
            "rating": 4.8,
            "avatar_url": "https://example.com/alex.png",
            "date": "2026-03-15"
        }
        """.data(using: .utf8)!

        let review = try JSONDecoder().decode(PaywallReview.self, from: json)
        XCTAssertEqual(review.text, "Absolutely incredible app!")
        XCTAssertEqual(review.author, "Alex K.")
        XCTAssertEqual(review.rating, 4.8)
        XCTAssertEqual(review.avatarUrl, "https://example.com/alex.png")
        XCTAssertEqual(review.date, "2026-03-15")
        // Verify computed id
        XCTAssertEqual(review.id, "Alex K.Absolutely incredibl")
    }

    // 26. PaywallTableColumn and PaywallTableRow decoded individually
    func testDecodePaywallTableColumnAndRow() throws {
        let colJson = """
        { "label": "Premium", "highlighted": true }
        """.data(using: .utf8)!

        let column = try JSONDecoder().decode(PaywallTableColumn.self, from: colJson)
        XCTAssertEqual(column.label, "Premium")
        XCTAssertEqual(column.highlighted, true)

        let rowJson = """
        { "feature": "Cloud backup", "values": ["cross", "check", "check"] }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(PaywallTableRow.self, from: rowJson)
        XCTAssertEqual(row.feature, "Cloud backup")
        XCTAssertEqual(row.values, ["cross", "check", "check"])
    }

    // 27. PaywallLink decoded individually
    func testDecodePaywallLink() throws {
        let json = """
        { "label": "Terms of Service", "url": "https://example.com/tos" }
        """.data(using: .utf8)!

        let link = try JSONDecoder().decode(PaywallLink.self, from: json)
        XCTAssertEqual(link.label, "Terms of Service")
        XCTAssertEqual(link.url, "https://example.com/tos")
    }

    // 28. Image background
    func testDecodeImageBackground() throws {
        let json = """
        {
            "type": "image",
            "value": "https://example.com/bg.jpg"
        }
        """.data(using: .utf8)!

        let bg = try JSONDecoder().decode(PaywallBackground.self, from: json)
        XCTAssertEqual(bg.type, "image")
        XCTAssertEqual(bg.value, "https://example.com/bg.jpg")
    }

    // 29. Video background
    func testDecodeVideoBackground() throws {
        let json = """
        {
            "type": "video",
            "video_url": "https://example.com/bg.mp4",
            "video_poster_url": "https://example.com/poster.jpg"
        }
        """.data(using: .utf8)!

        let bg = try JSONDecoder().decode(PaywallBackground.self, from: json)
        XCTAssertEqual(bg.type, "video")
        XCTAssertEqual(bg.video_url, "https://example.com/bg.mp4")
        XCTAssertEqual(bg.video_poster_url, "https://example.com/poster.jpg")
    }

    // 30. Full config with sections
    func testDecodeFullConfigWithSpec089dSections() throws {
        let json = """
        {
            "id": "premium_v2",
            "name": "Premium with 089d sections",
            "layout": { "type": "stack", "spacing": 12, "padding": 16 },
            "sections": [
                {
                    "type": "header",
                    "data": {
                        "title": "Go Premium",
                        "subtitle": "Limited time offer"
                    }
                },
                {
                    "type": "countdown",
                    "data": {
                        "variant": "digital",
                        "duration_seconds": 600,
                        "show_hours": false,
                        "show_minutes": true,
                        "show_seconds": true,
                        "accent_color": "#FF3D00"
                    }
                },
                {
                    "type": "plans",
                    "data": {
                        "plans": [
                            {
                                "id": "annual",
                                "product_id": "com.app.annual",
                                "name": "Annual",
                                "price": "$39.99",
                                "period": "year",
                                "is_default": true
                            }
                        ]
                    }
                },
                {
                    "type": "toggle",
                    "data": {
                        "label": "Family plan",
                        "default_value": false,
                        "affects_price": true
                    }
                },
                {
                    "type": "legal",
                    "data": {
                        "color": "#666666",
                        "links": [
                            { "label": "Terms", "url": "https://example.com/terms" }
                        ]
                    }
                },
                {
                    "type": "sticky_footer",
                    "data": {
                        "cta_text": "Subscribe",
                        "cta_bg_color": "#FF3D00",
                        "cta_text_color": "#FFFFFF",
                        "blur_background": true
                    }
                }
            ],
            "dismiss": {
                "type": "x_button",
                "delay_seconds": 5
            },
            "background": {
                "type": "gradient",
                "colors": ["#0D0D1A", "#1A1A3E"]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PaywallConfig.self, from: json)
        XCTAssertEqual(config.id, "premium_v2")
        XCTAssertEqual(config.name, "Premium with 089d sections")
        XCTAssertEqual(config.sections.count, 6)

        // Verify each section type
        XCTAssertEqual(config.sections[0].type, "header")
        XCTAssertEqual(config.sections[1].type, "countdown")
        XCTAssertEqual(config.sections[1].data?.variant, "digital")
        XCTAssertEqual(config.sections[1].data?.durationSeconds, 600)
        XCTAssertEqual(config.sections[2].type, "plans")
        XCTAssertEqual(config.sections[3].type, "toggle")
        XCTAssertEqual(config.sections[3].data?.label, "Family plan")
        XCTAssertEqual(config.sections[3].data?.affectsPrice, true)
        XCTAssertEqual(config.sections[4].type, "legal")
        XCTAssertEqual(config.sections[4].data?.links?.count, 1)
        XCTAssertEqual(config.sections[5].type, "sticky_footer")
        XCTAssertEqual(config.sections[5].data?.ctaText, "Subscribe")
        XCTAssertEqual(config.sections[5].data?.blurBackground, true)

        // Verify dismiss and background still decode
        XCTAssertEqual(config.dismiss?.style, "x_button")
        XCTAssertEqual(config.dismiss?.delaySeconds, 5)
        XCTAssertEqual(config.background?.type, "gradient")
        XCTAssertEqual(config.background?.colors?.count, 2)
    }

    // 31. Per-section style (SectionStyleConfig with container + elements)
    func testDecodePerSectionStyle() throws {
        let json = """
        {
            "type": "header",
            "data": {
                "title": "Styled Header"
            },
            "style": {
                "container": {
                    "corner_radius": 16,
                    "opacity": 0.95
                },
                "elements": {
                    "title": {
                        "opacity": 1.0
                    },
                    "subtitle": {
                        "corner_radius": 8,
                        "opacity": 0.7
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let section = try JSONDecoder().decode(PaywallSection.self, from: json)
        XCTAssertEqual(section.type, "header")
        XCTAssertEqual(section.data?.title, "Styled Header")
        XCTAssertNotNil(section.style)
        XCTAssertEqual(section.style?.container?.corner_radius, 16)
        XCTAssertEqual(section.style?.container?.opacity, 0.95)
        XCTAssertNotNil(section.style?.elements?["title"])
        XCTAssertEqual(section.style?.elements?["title"]?.opacity, 1.0)
        XCTAssertEqual(section.style?.elements?["subtitle"]?.corner_radius, 8)
        XCTAssertEqual(section.style?.elements?["subtitle"]?.opacity, 0.7)
    }
}
