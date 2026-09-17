import XCTest
@testable import AppDNASDK

/// Tests that ContentBlock correctly decodes JSON from the editor/Firestore.
/// These tests prevent the #1 production risk: field name mismatches between
/// what the editor writes and what the SDK reads.
final class ContentBlockDecodingTests: XCTestCase {

    // MARK: - Unknown block type doesn't crash (AC-001)

    func testUnknownBlockTypeDecodesToUnknown() throws {
        let json = """
        { "id": "b1", "type": "future_block_type_2030" }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.id, "b1")
        XCTAssertEqual(block.type, .unknown)
    }

    // MARK: - Basic block types

    func testDecodeHeadingBlock() throws {
        let json = """
        {
            "id": "h1",
            "type": "heading",
            "text": "Welcome",
            "level": 1,
            "style": { "font_size": 28, "font_weight": 700, "color": "#ffffff" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .heading)
        XCTAssertEqual(block.text, "Welcome")
        XCTAssertEqual(block.level, 1)
        XCTAssertEqual(block.style?.font_size, 28)
        XCTAssertEqual(block.style?.font_weight, 700)
        XCTAssertEqual(block.style?.color, "#ffffff")
    }

    func testDecodeButtonBlock() throws {
        let json = """
        {
            "id": "btn1",
            "type": "button",
            "text": "Continue",
            "variant": "primary",
            "action": "next",
            "bg_color": "#6366f1",
            "text_color": "#ffffff",
            "button_corner_radius": 12
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .button)
        XCTAssertEqual(block.text, "Continue")
        XCTAssertEqual(block.variant, "primary")
        XCTAssertEqual(block.bg_color, "#6366f1")
        XCTAssertEqual(block.button_corner_radius, 12)
    }

    func testDecodeImageBlock() throws {
        let json = """
        {
            "id": "img1",
            "type": "image",
            "image_url": "https://example.com/photo.jpg",
            "height": 200,
            "corner_radius": 16,
            "alt": "Hero image"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .image)
        XCTAssertEqual(block.image_url, "https://example.com/photo.jpg")
        XCTAssertEqual(block.height, 200)
        XCTAssertEqual(block.corner_radius, 16)
    }

    // MARK: - SPEC-089d new block types

    func testDecodePageIndicator() throws {
        let json = """
        {
            "id": "pi1",
            "type": "page_indicator",
            "dot_count": 5,
            "active_index": 2,
            "active_color": "#6366f1",
            "inactive_color": "#d1d5db",
            "dot_size": 8,
            "dot_spacing": 6,
            "active_dot_width": 24
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .page_indicator)
        XCTAssertEqual(block.dot_count, 5)
        XCTAssertEqual(block.active_index, 2)
        XCTAssertEqual(block.active_color, "#6366f1")
        XCTAssertEqual(block.dot_size, 8)
        XCTAssertEqual(block.active_dot_width, 24)
    }

    func testDecodeSocialLogin() throws {
        let json = """
        {
            "id": "sl1",
            "type": "social_login",
            "providers": [
                { "type": "apple", "enabled": true },
                { "type": "google", "enabled": true },
                { "type": "email", "label": "Continue with Email", "enabled": true }
            ],
            "button_style": "filled",
            "button_height": 52,
            "spacing": 12,
            "show_divider": true,
            "divider_text": "or continue with"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .social_login)
        XCTAssertEqual(block.providers?.count, 3)
        XCTAssertEqual(block.providers?[0].type, "apple")
        XCTAssertEqual(block.providers?[2].label, "Continue with Email")
        XCTAssertEqual(block.button_style, "filled")
        XCTAssertEqual(block.show_divider, true)
    }

    func testDecodeCountdownTimer() throws {
        let json = """
        {
            "id": "ct1",
            "type": "countdown_timer",
            "timer_variant": "digital",
            "duration_seconds": 900,
            "show_hours": true,
            "show_minutes": true,
            "show_seconds": true,
            "on_expire_action": "auto_advance",
            "accent_color": "#ef4444"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .countdown_timer)
        XCTAssertEqual(block.timer_variant, "digital")
        XCTAssertEqual(block.duration_seconds, 900)
        XCTAssertEqual(block.on_expire_action, "auto_advance")
    }

    func testDecodeRating() throws {
        let json = """
        {
            "id": "r1",
            "type": "rating",
            "max_stars": 5,
            "default_rating": 0,
            "star_size": 32,
            "filled_color": "#f59e0b",
            "empty_color": "#d1d5db",
            "allow_half": true,
            "field_id": "satisfaction"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .rating)
        XCTAssertEqual(block.max_stars, 5)
        XCTAssertEqual(block.filled_color, "#f59e0b")
        XCTAssertEqual(block.allow_half, true)
        XCTAssertEqual(block.field_id, "satisfaction")
    }

    func testDecodeTimeline() throws {
        let json = """
        {
            "id": "tl1",
            "type": "timeline",
            "timeline_items": [
                { "id": "s1", "title": "Sign up", "subtitle": "Create account", "status": "completed" },
                { "id": "s2", "title": "Profile", "status": "current" },
                { "id": "s3", "title": "Ready!", "status": "upcoming" }
            ],
            "line_color": "#e5e7eb",
            "completed_color": "#10b981",
            "current_color": "#6366f1",
            "upcoming_color": "#9ca3af",
            "show_line": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .timeline)
        XCTAssertEqual(block.timeline_items?.count, 3)
        XCTAssertEqual(block.timeline_items?[0].status, "completed")
        XCTAssertEqual(block.timeline_items?[1].title, "Profile")
        XCTAssertEqual(block.show_line, true)
    }

    func testDecodeProgressBar() throws {
        let json = """
        {
            "id": "pb1",
            "type": "progress_bar",
            "progress_variant": "segmented",
            "total_segments": 5,
            "filled_segments": 3,
            "bar_height": 6,
            "bar_color": "#6366f1",
            "track_color": "#e5e7eb",
            "show_label": true,
            "segment_gap": 4
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .progress_bar)
        XCTAssertEqual(block.progress_variant, "segmented")
        XCTAssertEqual(block.total_segments, 5)
        XCTAssertEqual(block.filled_segments, 3)
        XCTAssertEqual(block.segment_gap, 4)
    }

    func testDecodePricingCard() throws {
        let json = """
        {
            "id": "pc1",
            "type": "pricing_card",
            "pricing_plans": [
                { "id": "p1", "label": "Monthly", "price": "$9.99", "period": "/month", "is_highlighted": false },
                { "id": "p2", "label": "Annual", "price": "$59.99", "period": "/year", "badge": "BEST VALUE", "is_highlighted": true }
            ],
            "pricing_layout": "stack"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .pricing_card)
        XCTAssertEqual(block.pricing_plans?.count, 2)
        XCTAssertEqual(block.pricing_plans?[1].badge, "BEST VALUE")
        XCTAssertEqual(block.pricing_plans?[1].is_highlighted, true)
        XCTAssertEqual(block.pricing_layout, "stack")
    }

    // MARK: - Block Style Design Tokens (AC-005 through AC-009)

    func testDecodeBlockStyle() throws {
        let json = """
        {
            "id": "styled1",
            "type": "text",
            "text": "Styled block",
            "block_style": {
                "background_color": "#1a1a2e",
                "background_gradient": { "angle": 135, "start": "#6366f1", "end": "#a855f7" },
                "border_color": "#374151",
                "border_width": 1,
                "border_style": "solid",
                "border_radius": 12,
                "shadow": { "x": 0, "y": 4, "blur": 12, "spread": 0, "color": "rgba(0,0,0,0.15)" },
                "padding_top": 16,
                "padding_right": 16,
                "padding_bottom": 16,
                "padding_left": 16,
                "margin_top": 8,
                "margin_bottom": 8,
                "opacity": 0.95
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        let bs = block.block_style
        XCTAssertNotNil(bs)
        XCTAssertEqual(bs?.background_color, "#1a1a2e")
        XCTAssertEqual(bs?.background_gradient?.angle, 135)
        XCTAssertEqual(bs?.border_color, "#374151")
        XCTAssertEqual(bs?.border_width, 1)
        XCTAssertEqual(bs?.border_radius, 12)
        XCTAssertNotNil(bs?.shadow)
        XCTAssertEqual(bs?.shadow?.blur, 12)
        XCTAssertEqual(bs?.padding_top, 16)
        XCTAssertEqual(bs?.margin_top, 8)
        XCTAssertEqual(bs?.opacity, 0.95)
    }

    // MARK: - Visibility Conditions (AC-054 through AC-056)

    func testDecodeVisibilityCondition() throws {
        let json = """
        {
            "id": "vc1",
            "type": "text",
            "text": "Conditional",
            "visibility_condition": {
                "type": "when_equals",
                "variable": "responses.step1.goal",
                "value": "fitness"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.visibility_condition)
        XCTAssertEqual(block.visibility_condition?.type, "when_equals")
        XCTAssertEqual(block.visibility_condition?.variable, "responses.step1.goal")
    }

    // MARK: - Entrance Animations (AC-057 through AC-061)

    func testDecodeEntranceAnimation() throws {
        let json = """
        {
            "id": "ea1",
            "type": "heading",
            "text": "Animated",
            "entrance_animation": {
                "type": "slide_up",
                "duration_ms": 400,
                "delay_ms": 200,
                "easing": "spring"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.entrance_animation)
        XCTAssertEqual(block.entrance_animation?.type, "slide_up")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 400)
        XCTAssertEqual(block.entrance_animation?.delay_ms, 200)
    }

    // MARK: - Dynamic Bindings (AC-064 through AC-066)

    func testDecodeBindings() throws {
        let json = """
        {
            "id": "db1",
            "type": "circular_gauge",
            "gauge_value": 0,
            "bindings": {
                "gauge_value": "hook_data.user_progress",
                "bar_color": "hook_data.status_color"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.bindings?["gauge_value"], "hook_data.user_progress")
        XCTAssertEqual(block.bindings?["bar_color"], "hook_data.status_color")
    }

    // MARK: - Form Input Blocks (AC-040 through AC-053)

    func testDecodeFormInputText() throws {
        let json = """
        {
            "id": "fi1",
            "type": "input_text",
            "field_id": "full_name",
            "field_label": "Your Name",
            "field_placeholder": "Enter your name",
            "field_required": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_text)
        XCTAssertEqual(block.field_id, "full_name")
        XCTAssertEqual(block.field_label, "Your Name")
        XCTAssertEqual(block.field_placeholder, "Enter your name")
        XCTAssertEqual(block.field_required, true)
    }

    func testDecodeFormInputSelect() throws {
        let json = """
        {
            "id": "fi2",
            "type": "input_select",
            "field_id": "gender",
            "field_label": "Gender",
            "field_options": [
                { "id": "m", "label": "Male" },
                { "id": "f", "label": "Female" },
                { "id": "nb", "label": "Non-binary" }
            ]
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_select)
        XCTAssertEqual(block.field_options?.count, 3)
        XCTAssertEqual(block.field_options?[0].id, "m")
        XCTAssertEqual(block.field_options?[1].label, "Female")
    }

    // MARK: - Container Blocks (stack, row)

    func testDecodeStackWithChildren() throws {
        let json = """
        {
            "id": "stack1",
            "type": "stack",
            "children": [
                { "id": "c1", "type": "image", "image_url": "bg.jpg", "z_index": 0 },
                { "id": "c2", "type": "text", "text": "Overlay", "z_index": 1 }
            ]
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .stack)
        XCTAssertEqual(block.children?.count, 2)
        XCTAssertEqual(block.children?[0].type, .image)
        XCTAssertEqual(block.children?[1].z_index, 1)
    }

    // MARK: - 2D Positioning + Relative Sizing

    func testDecodePositioningAndSizing() throws {
        let json = """
        {
            "id": "pos1",
            "type": "button",
            "text": "Centered",
            "vertical_align": "center",
            "horizontal_align": "center",
            "vertical_offset": 10,
            "horizontal_offset": -5,
            "element_width": "80%",
            "element_height": "auto"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.vertical_align, "center")
        XCTAssertEqual(block.horizontal_align, "center")
        XCTAssertEqual(block.vertical_offset, 10)
        XCTAssertEqual(block.horizontal_offset, -5)
        XCTAssertEqual(block.element_width, "80%")
        XCTAssertEqual(block.element_height, "auto")
    }

    // MARK: - Empty/minimal blocks don't crash

    func testDecodeMinimalBlock() throws {
        let json = """
        { "id": "min1", "type": "spacer" }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .spacer)
        XCTAssertNil(block.text)
        XCTAssertNil(block.block_style)
        XCTAssertNil(block.visibility_condition)
    }

    func testDecodeBlockWithExtraUnknownFields() throws {
        let json = """
        {
            "id": "extra1",
            "type": "text",
            "text": "Hello",
            "future_field_2030": "some value",
            "another_unknown": 42
        }
        """.data(using: .utf8)!

        // Should not crash — unknown fields are ignored by Codable
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .text)
        XCTAssertEqual(block.text, "Hello")
    }

    // MARK: - Full customer-style flow step with multiple blocks

    func testDecodeCustomerWelcomeStep() throws {
        let json = """
        {
            "id": "welcome",
            "type": "heading",
            "text": "Welcome to Acme",
            "level": 1,
            "style": { "font_size": 32, "font_weight": 800, "color": "#ffffff", "alignment": "center" },
            "block_style": {
                "margin_top": 40,
                "margin_bottom": 16
            },
            "entrance_animation": {
                "type": "fade_in",
                "duration_ms": 600,
                "delay_ms": 300,
                "easing": "ease_out"
            },
            "vertical_align": "center",
            "horizontal_align": "center"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .heading)
        XCTAssertEqual(block.text, "Welcome to Acme")
        XCTAssertEqual(block.style?.font_size, 32)
        XCTAssertEqual(block.style?.alignment, "center")
        XCTAssertEqual(block.block_style?.margin_top, 40)
        XCTAssertEqual(block.entrance_animation?.type, "fade_in")
        XCTAssertEqual(block.vertical_align, "center")
    }

    // MARK: - Pressed Style

    func testDecodePressedStyle() throws {
        let json = """
        {
            "id": "ps1",
            "type": "button",
            "text": "Tap me",
            "pressed_style": {
                "scale": 0.95,
                "opacity": 0.8,
                "bg_color": "#4f46e5"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.pressed_style)
        XCTAssertEqual(block.pressed_style?.scale, 0.95)
        XCTAssertEqual(block.pressed_style?.opacity, 0.8)
    }

    // MARK: - Missing block types (comprehensive)

    func testDecodeAnimatedLoading() throws {
        let json = """
        {
            "id": "al1",
            "type": "animated_loading",
            "loading_items": [
                {"label": "Analyzing...", "duration_ms": 1500, "icon": "magnifyingglass"},
                {"label": "Almost done", "duration_ms": 1000}
            ],
            "progress_color": "#22c55e",
            "total_duration_ms": 3000,
            "auto_advance": true
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .animated_loading)
        XCTAssertEqual(block.loading_items?.count, 2)
        XCTAssertEqual(block.loading_items?.first?.label, "Analyzing...")
        XCTAssertEqual(block.loading_items?.first?.duration_ms, 1500)
        XCTAssertEqual(block.loading_items?.first?.icon, "magnifyingglass")
        XCTAssertEqual(block.loading_items?[1].icon, nil)
        XCTAssertEqual(block.progress_color, "#22c55e")
        XCTAssertEqual(block.total_duration_ms, 3000)
        XCTAssertEqual(block.auto_advance, true)
    }

    func testDecodeCircularGauge() throws {
        let json = """
        {
            "id": "cg1",
            "type": "circular_gauge",
            "gauge_value": 72.5,
            "max_value": 100,
            "sublabel": "Health Score",
            "stroke_width": 10,
            "bar_color": "#6366f1",
            "track_color": "#e5e7eb",
            "animate": true,
            "animation_duration_ms": 800
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .circular_gauge)
        XCTAssertEqual(block.gauge_value, 72.5)
        XCTAssertEqual(block.max_value, 100)
        XCTAssertEqual(block.sublabel, "Health Score")
        XCTAssertEqual(block.stroke_width, 10)
        XCTAssertEqual(block.bar_color, "#6366f1")
        XCTAssertEqual(block.track_color, "#e5e7eb")
        XCTAssertEqual(block.animate, true)
        XCTAssertEqual(block.animation_duration_ms, 800)
    }

    func testDecodePulsingAvatar() throws {
        let json = """
        {
            "id": "pa1",
            "type": "pulsing_avatar",
            "image_url": "https://example.com/avatar.jpg",
            "height": 80,
            "pulse_color": "#6366f1",
            "pulse_ring_count": 3,
            "pulse_speed": 1.5,
            "border_width": 2,
            "border_color": "#ffffff"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .pulsing_avatar)
        XCTAssertEqual(block.image_url, "https://example.com/avatar.jpg")
        XCTAssertEqual(block.height, 80)
        XCTAssertEqual(block.pulse_color, "#6366f1")
        XCTAssertEqual(block.pulse_ring_count, 3)
        XCTAssertEqual(block.pulse_speed, 1.5)
        XCTAssertEqual(block.border_width, 2)
        XCTAssertEqual(block.border_color, "#ffffff")
    }

    func testDecodeWheelPicker() throws {
        let json = """
        {
            "id": "wp1",
            "type": "wheel_picker",
            "min_value": 18,
            "max_value_picker": 99,
            "step_value": 1,
            "default_picker_value": 25,
            "unit": "years",
            "unit_position": "right",
            "visible_items": 5,
            "field_id": "age"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .wheel_picker)
        XCTAssertEqual(block.min_value, 18)
        XCTAssertEqual(block.max_value_picker, 99)
        XCTAssertEqual(block.step_value, 1)
        XCTAssertEqual(block.default_picker_value, 25)
        XCTAssertEqual(block.unit, "years")
        XCTAssertEqual(block.unit_position, "right")
        XCTAssertEqual(block.visible_items, 5)
        XCTAssertEqual(block.field_id, "age")
    }

    func testDecodeDateWheelPicker() throws {
        let json = """
        {
            "id": "dwp1",
            "type": "date_wheel_picker",
            "columns": [
                {"type": "month", "label": "Month"},
                {"type": "day", "label": "Day"},
                {"type": "year", "label": "Year", "values": ["2020","2021","2022","2023","2024","2025","2026"]}
            ],
            "default_date_value": "2000-01-15",
            "min_date": "1920-01-01",
            "max_date": "2026-12-31",
            "highlight_color": "#6366f1",
            "haptic_on_scroll": true,
            "field_id": "birthdate"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .date_wheel_picker)
        XCTAssertEqual(block.columns?.count, 3)
        XCTAssertEqual(block.columns?[0].type, "month")
        XCTAssertEqual(block.columns?[0].label, "Month")
        XCTAssertEqual(block.columns?[2].values?.count, 7)
        XCTAssertEqual(block.default_date_value, "2000-01-15")
        XCTAssertEqual(block.min_date, "1920-01-01")
        XCTAssertEqual(block.max_date, "2026-12-31")
        XCTAssertEqual(block.highlight_color, "#6366f1")
        XCTAssertEqual(block.haptic_on_scroll, true)
        XCTAssertEqual(block.field_id, "birthdate")
    }

    func testDecodeBadge() throws {
        let json = """
        {
            "id": "badge1",
            "type": "badge",
            "badge_text": "NEW",
            "badge_bg_color": "#ef4444",
            "badge_text_color": "#ffffff",
            "badge_corner_radius": 8
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .badge)
        XCTAssertEqual(block.badge_text, "NEW")
        XCTAssertEqual(block.badge_bg_color, "#ef4444")
        XCTAssertEqual(block.badge_text_color, "#ffffff")
        XCTAssertEqual(block.badge_corner_radius, 8)
    }

    func testDecodeRichText() throws {
        let json = """
        {
            "id": "rt1",
            "type": "rich_text",
            "markdown_content": "By continuing, you agree to our **Terms of Service** and [Privacy Policy](https://example.com/privacy)",
            "rich_text_variant": "legal",
            "link_color": "#6366f1"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .rich_text)
        XCTAssertTrue(block.markdown_content?.contains("Terms of Service") == true)
        XCTAssertEqual(block.rich_text_variant, "legal")
        XCTAssertEqual(block.link_color, "#6366f1")
    }

    func testDecodeToggle() throws {
        let json = """
        {
            "id": "tog1",
            "type": "toggle",
            "toggle_label": "Enable notifications",
            "toggle_description": "Get updates about your progress",
            "toggle_default": false,
            "field_id": "notifications_enabled"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .toggle)
        XCTAssertEqual(block.toggle_label, "Enable notifications")
        XCTAssertEqual(block.toggle_description, "Get updates about your progress")
        XCTAssertEqual(block.toggle_default, false)
        XCTAssertEqual(block.field_id, "notifications_enabled")
    }

    func testDecodeRow() throws {
        let json = """
        {
            "id": "row1",
            "type": "row",
            "children": [
                {"id": "rc1", "type": "icon", "icon_emoji": "star"},
                {"id": "rc2", "type": "text", "text": "Premium"}
            ],
            "gap": 12,
            "wrap": false,
            "justify": "space-between",
            "align_items": "center"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .row)
        XCTAssertEqual(block.children?.count, 2)
        XCTAssertEqual(block.children?[0].type, .icon)
        XCTAssertEqual(block.children?[1].text, "Premium")
        XCTAssertEqual(block.gap, 12)
        XCTAssertEqual(block.wrap, false)
        XCTAssertEqual(block.justify, "space-between")
        XCTAssertEqual(block.align_items, "center")
    }

    func testDecodeCustomView() throws {
        let json = """
        {
            "id": "cv1",
            "type": "custom_view",
            "view_key": "subscription_comparison_table",
            "placeholder_text": "Loading comparison...",
            "placeholder_image_url": "https://example.com/placeholder.png"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .custom_view)
        XCTAssertEqual(block.view_key, "subscription_comparison_table")
        XCTAssertEqual(block.placeholder_text, "Loading comparison...")
        XCTAssertEqual(block.placeholder_image_url, "https://example.com/placeholder.png")
    }

    func testDecodeLottie() throws {
        let json = """
        {
            "id": "lot1",
            "type": "lottie",
            "lottie_url": "https://example.com/celebration.json",
            "autoplay": true,
            "loop": true,
            "lottie_speed": 1.5,
            "lottie_width": 200,
            "lottie_height": 200
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .lottie)
        XCTAssertEqual(block.lottie_url, "https://example.com/celebration.json")
        XCTAssertEqual(block.autoplay, true)
        XCTAssertEqual(block.loop, true)
        XCTAssertEqual(block.lottie_speed, 1.5)
        XCTAssertEqual(block.lottie_width, 200)
        XCTAssertEqual(block.lottie_height, 200)
    }

    func testDecodeRive() throws {
        let json = """
        {
            "id": "riv1",
            "type": "rive",
            "rive_url": "https://example.com/mascot.riv",
            "artboard": "MainArtboard",
            "state_machine": "idle_animation",
            "trigger_on_step_complete": "celebrate",
            "lottie_width": 300,
            "lottie_height": 300
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .rive)
        XCTAssertEqual(block.rive_url, "https://example.com/mascot.riv")
        XCTAssertEqual(block.artboard, "MainArtboard")
        XCTAssertEqual(block.state_machine, "idle_animation")
        XCTAssertEqual(block.trigger_on_step_complete, "celebrate")
    }

    // MARK: - Entrance animation types

    func testDecodeEntranceAnimationFadeIn() throws {
        let json = """
        {
            "id": "ea_fi",
            "type": "text",
            "text": "Fade",
            "entrance_animation": { "type": "fade_in", "duration_ms": 300, "delay_ms": 0, "easing": "ease_out" }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "fade_in")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 300)
        XCTAssertEqual(block.entrance_animation?.easing, "ease_out")
    }

    func testDecodeEntranceAnimationSlideDown() throws {
        let json = """
        {
            "id": "ea_sd",
            "type": "text",
            "text": "Slide",
            "entrance_animation": { "type": "slide_down", "duration_ms": 500, "delay_ms": 100 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "slide_down")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 500)
        XCTAssertEqual(block.entrance_animation?.delay_ms, 100)
    }

    func testDecodeEntranceAnimationScaleUp() throws {
        let json = """
        {
            "id": "ea_su",
            "type": "image",
            "image_url": "hero.jpg",
            "entrance_animation": { "type": "scale_up", "duration_ms": 400, "delay_ms": 200, "easing": "spring", "spring_damping": 0.6 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "scale_up")
        XCTAssertEqual(block.entrance_animation?.easing, "spring")
        XCTAssertEqual(block.entrance_animation?.spring_damping, 0.6)
    }

    func testDecodeEntranceAnimationBounce() throws {
        let json = """
        {
            "id": "ea_b",
            "type": "button",
            "text": "Bounce",
            "entrance_animation": { "type": "bounce", "duration_ms": 600 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "bounce")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 600)
    }

    func testDecodeEntranceAnimationFlip() throws {
        let json = """
        {
            "id": "ea_f",
            "type": "badge",
            "badge_text": "Flip",
            "entrance_animation": { "type": "flip", "duration_ms": 500, "delay_ms": 50 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "flip")
        XCTAssertEqual(block.entrance_animation?.delay_ms, 50)
    }

    func testDecodeEntranceAnimationNone() throws {
        let json = """
        {
            "id": "ea_n",
            "type": "text",
            "text": "No anim",
            "entrance_animation": { "type": "none" }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "none")
        XCTAssertNil(block.entrance_animation?.duration_ms)
        XCTAssertNil(block.entrance_animation?.delay_ms)
    }

    // MARK: - Visibility condition types

    func testDecodeVisibilityConditionWhenNotEquals() throws {
        let json = """
        {
            "id": "vc_ne",
            "type": "text",
            "text": "Not equal",
            "visibility_condition": {
                "type": "when_not_equals",
                "variable": "responses.step2.plan",
                "value": "free"
            }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.visibility_condition)
        XCTAssertEqual(block.visibility_condition?.type, "when_not_equals")
        XCTAssertEqual(block.visibility_condition?.variable, "responses.step2.plan")
    }

    func testDecodeVisibilityConditionWhenGt() throws {
        let json = """
        {
            "id": "vc_gt",
            "type": "text",
            "text": "Greater than",
            "visibility_condition": {
                "type": "when_gt",
                "variable": "responses.step3.age",
                "value": 18
            }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.visibility_condition?.type, "when_gt")
        XCTAssertEqual(block.visibility_condition?.variable, "responses.step3.age")
    }

    func testDecodeVisibilityConditionWhenEmpty() throws {
        let json = """
        {
            "id": "vc_e",
            "type": "button",
            "text": "Fill in profile",
            "visibility_condition": {
                "type": "when_empty",
                "variable": "user.profile_image"
            }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.visibility_condition?.type, "when_empty")
        XCTAssertEqual(block.visibility_condition?.variable, "user.profile_image")
        XCTAssertNil(block.visibility_condition?.value)
    }

    // MARK: - Pressed style variants

    func testDecodePressedStyleScaleOnly() throws {
        let json = """
        {
            "id": "ps_s",
            "type": "button",
            "text": "Tap",
            "pressed_style": { "scale": 0.9 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.pressed_style?.scale, 0.9)
        XCTAssertNil(block.pressed_style?.opacity)
        XCTAssertNil(block.pressed_style?.bg_color)
        XCTAssertNil(block.pressed_style?.text_color)
    }

    func testDecodePressedStyleOpacityOnly() throws {
        let json = """
        {
            "id": "ps_o",
            "type": "button",
            "text": "Tap",
            "pressed_style": { "opacity": 0.6 }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.pressed_style?.opacity, 0.6)
        XCTAssertNil(block.pressed_style?.scale)
    }

    func testDecodePressedStyleTextColor() throws {
        let json = """
        {
            "id": "ps_tc",
            "type": "button",
            "text": "Tap",
            "pressed_style": { "text_color": "#ff0000", "bg_color": "#000000" }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.pressed_style?.text_color, "#ff0000")
        XCTAssertEqual(block.pressed_style?.bg_color, "#000000")
    }

    // MARK: - Bindings with multiple data sources

    func testDecodeMultipleBindings() throws {
        let json = """
        {
            "id": "mb1",
            "type": "heading",
            "text": "Welcome",
            "bindings": {
                "text": "hook_data.welcome_title",
                "bg_color": "user.theme_color",
                "element_width": "session.layout_width"
            }
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.bindings?.count, 3)
        XCTAssertEqual(block.bindings?["text"], "hook_data.welcome_title")
        XCTAssertEqual(block.bindings?["bg_color"], "user.theme_color")
        XCTAssertEqual(block.bindings?["element_width"], "session.layout_width")
    }

    // MARK: - z_index values

    func testDecodePositiveZIndex() throws {
        let json = """
        {
            "id": "zi_pos",
            "type": "text",
            "text": "On top",
            "z_index": 10
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.z_index, 10)
    }

    func testDecodeNegativeZIndex() throws {
        let json = """
        {
            "id": "zi_neg",
            "type": "image",
            "image_url": "bg.jpg",
            "z_index": -1
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.z_index, -1)
    }

    // MARK: - Element sizing variants

    func testDecodeElementSizeFill() throws {
        let json = """
        {
            "id": "sz_fill",
            "type": "button",
            "text": "Full width",
            "element_width": "fill",
            "element_height": "auto"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.element_width, "fill")
        XCTAssertEqual(block.element_height, "auto")
    }

    func testDecodeElementSizePixels() throws {
        let json = """
        {
            "id": "sz_px",
            "type": "spacer",
            "element_width": "100px",
            "element_height": "50px"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.element_width, "100px")
        XCTAssertEqual(block.element_height, "50px")
    }

    func testDecodeElementSizeAuto() throws {
        let json = """
        {
            "id": "sz_auto",
            "type": "image",
            "image_url": "pic.jpg",
            "element_width": "auto",
            "element_height": "auto"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.element_width, "auto")
        XCTAssertEqual(block.element_height, "auto")
    }

    // MARK: - More form input types

    func testDecodeInputEmail() throws {
        let json = """
        {
            "id": "fie1",
            "type": "input_email",
            "field_id": "email_address",
            "field_label": "Email",
            "field_placeholder": "you@example.com",
            "field_required": true
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_email)
        XCTAssertEqual(block.field_id, "email_address")
        XCTAssertEqual(block.field_label, "Email")
        XCTAssertEqual(block.field_placeholder, "you@example.com")
        XCTAssertEqual(block.field_required, true)
    }

    func testDecodeInputNumber() throws {
        let json = """
        {
            "id": "fin1",
            "type": "input_number",
            "field_id": "weight_kg",
            "field_label": "Weight (kg)",
            "field_placeholder": "70"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_number)
        XCTAssertEqual(block.field_id, "weight_kg")
        XCTAssertEqual(block.field_label, "Weight (kg)")
    }

    func testDecodeInputSlider() throws {
        let json = """
        {
            "id": "fis1",
            "type": "input_slider",
            "field_id": "intensity_level",
            "field_label": "Workout Intensity"
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_slider)
        XCTAssertEqual(block.field_id, "intensity_level")
        XCTAssertEqual(block.field_label, "Workout Intensity")
    }

    func testDecodeInputToggle() throws {
        let json = """
        {
            "id": "fit1",
            "type": "input_toggle",
            "field_id": "dark_mode",
            "field_label": "Dark Mode",
            "field_required": false
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_toggle)
        XCTAssertEqual(block.field_id, "dark_mode")
        XCTAssertEqual(block.field_label, "Dark Mode")
        XCTAssertEqual(block.field_required, false)
    }

    func testDecodeInputChipsAsMultiSelect() throws {
        let json = """
        {
            "id": "fic1",
            "type": "input_chips",
            "field_id": "interests",
            "field_label": "Select your interests",
            "field_options": [
                {"id": "fit", "label": "Fitness"},
                {"id": "nut", "label": "Nutrition"},
                {"id": "med", "label": "Meditation"},
                {"id": "sleep", "label": "Sleep"}
            ],
            "field_required": true
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_chips)
        XCTAssertEqual(block.field_id, "interests")
        XCTAssertEqual(block.field_options?.count, 4)
        XCTAssertEqual(block.field_options?[0].id, "fit")
        XCTAssertEqual(block.field_options?[0].label, "Fitness")
        XCTAssertEqual(block.field_options?[3].id, "sleep")
        XCTAssertEqual(block.field_required, true)
    }

    func testDecodeInputDate() throws {
        let json = """
        {
            "id": "fid1",
            "type": "input_date",
            "field_id": "birth_date",
            "field_label": "Date of Birth",
            "field_required": true
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_date)
        XCTAssertEqual(block.field_id, "birth_date")
        XCTAssertEqual(block.field_label, "Date of Birth")
        XCTAssertEqual(block.field_required, true)
    }

    // MARK: - InputOption edge cases

    func testDecodeInputOptionWithOnlyId() throws {
        // Option with id but no value — resolvedValue should fall back to id
        let json = """
        {
            "id": "io_id",
            "type": "input_select",
            "field_id": "plan",
            "field_options": [
                {"id": "starter", "label": "Starter Plan"}
            ]
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.field_options?.count, 1)
        let option = block.field_options![0]
        XCTAssertEqual(option.id, "starter")
        XCTAssertEqual(option.label, "Starter Plan")
        // value should fall back to id when not explicitly provided
        XCTAssertEqual(option.value, "starter")
        XCTAssertEqual(option.resolvedValue, "starter")
    }

    func testDecodeInputOptionWithOnlyValue() throws {
        // Option with value but no id — id should fall back to value
        let json = """
        {
            "id": "io_val",
            "type": "input_select",
            "field_id": "color",
            "field_options": [
                {"value": "blue_theme", "label": "Blue"}
            ]
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        let option = block.field_options![0]
        XCTAssertEqual(option.id, "blue_theme")
        XCTAssertEqual(option.value, "blue_theme")
        XCTAssertEqual(option.label, "Blue")
    }

    func testDecodeInputOptionWithBothIdAndValue() throws {
        // Option with both id and value — both preserved independently
        let json = """
        {
            "id": "io_both",
            "type": "input_select",
            "field_id": "size",
            "field_options": [
                {"id": "opt_sm", "value": "small", "label": "Small", "icon": "arrow.down"}
            ]
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        let option = block.field_options![0]
        XCTAssertEqual(option.id, "opt_sm")
        XCTAssertEqual(option.value, "small")
        XCTAssertEqual(option.label, "Small")
        XCTAssertEqual(option.icon, "arrow.down")
        XCTAssertEqual(option.resolvedValue, "small")
    }

    // MARK: - Edge cases

    func testDecodeBlockAllFieldsNull() throws {
        // Only id and type provided (spacer) — all optional fields should be nil
        let json = """
        { "id": "null1", "type": "spacer" }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.id, "null1")
        XCTAssertEqual(block.type, .spacer)
        XCTAssertNil(block.text)
        XCTAssertNil(block.style)
        XCTAssertNil(block.image_url)
        XCTAssertNil(block.children)
        XCTAssertNil(block.block_style)
        XCTAssertNil(block.visibility_condition)
        XCTAssertNil(block.entrance_animation)
        XCTAssertNil(block.pressed_style)
        XCTAssertNil(block.bindings)
        XCTAssertNil(block.element_width)
        XCTAssertNil(block.element_height)
        XCTAssertNil(block.z_index)
        XCTAssertNil(block.field_id)
        XCTAssertNil(block.field_options)
        XCTAssertNil(block.loading_items)
        XCTAssertNil(block.timeline_items)
        XCTAssertNil(block.pricing_plans)
        XCTAssertNil(block.columns)
        XCTAssertNil(block.providers)
    }

    func testDecodeStackWithEmptyChildren() throws {
        let json = """
        { "id": "stack_empty", "type": "stack", "children": [] }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .stack)
        XCTAssertNotNil(block.children)
        XCTAssertEqual(block.children?.count, 0)
    }

    func testDecodeRowWithEmptyChildren() throws {
        let json = """
        { "id": "row_empty", "type": "row", "children": [] }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .row)
        XCTAssertEqual(block.children?.count, 0)
    }

    func testDecodeInputSelectWithEmptyOptions() throws {
        let json = """
        {
            "id": "sel_empty",
            "type": "input_select",
            "field_id": "nothing",
            "field_options": []
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_select)
        XCTAssertNotNil(block.field_options)
        XCTAssertEqual(block.field_options?.count, 0)
    }

    func testDecodeDeeplyNestedBlocks() throws {
        // stack > row > button — three levels deep
        let json = """
        {
            "id": "deep_stack",
            "type": "stack",
            "children": [
                {
                    "id": "deep_row",
                    "type": "row",
                    "gap": 8,
                    "children": [
                        {
                            "id": "deep_btn",
                            "type": "button",
                            "text": "Nested Button",
                            "bg_color": "#10b981"
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .stack)
        XCTAssertEqual(block.children?.count, 1)

        let rowBlock = block.children![0]
        XCTAssertEqual(rowBlock.type, .row)
        XCTAssertEqual(rowBlock.gap, 8)
        XCTAssertEqual(rowBlock.children?.count, 1)

        let buttonBlock = rowBlock.children![0]
        XCTAssertEqual(buttonBlock.type, .button)
        XCTAssertEqual(buttonBlock.text, "Nested Button")
        XCTAssertEqual(buttonBlock.bg_color, "#10b981")
    }

    // MARK: - Video block (video_url, video_height, video_corner_radius, autoplay, loop, muted)

    func testDecodeVideoBlock() throws {
        let json = """
        {
            "id": "vid1",
            "type": "video",
            "video_url": "https://example.com/intro.mp4",
            "video_thumbnail_url": "https://example.com/thumb.jpg",
            "video_height": 250,
            "video_corner_radius": 12,
            "autoplay": true,
            "loop": false,
            "muted": true,
            "controls": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .video)
        XCTAssertEqual(block.video_url, "https://example.com/intro.mp4")
        XCTAssertEqual(block.video_thumbnail_url, "https://example.com/thumb.jpg")
        XCTAssertEqual(block.video_height, 250)
        XCTAssertEqual(block.video_corner_radius, 12)
        XCTAssertEqual(block.autoplay, true)
        XCTAssertEqual(block.loop, false)
        XCTAssertEqual(block.muted, true)
        XCTAssertEqual(block.controls, true)
    }

    func testDecodeVideoBlockMinimal() throws {
        let json = """
        {
            "id": "vid2",
            "type": "video",
            "video_url": "https://example.com/clip.mp4"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .video)
        XCTAssertEqual(block.video_url, "https://example.com/clip.mp4")
        XCTAssertNil(block.video_thumbnail_url)
        XCTAssertNil(block.video_height)
        XCTAssertNil(block.video_corner_radius)
        XCTAssertNil(block.autoplay)
        XCTAssertNil(block.loop)
        XCTAssertNil(block.muted)
        XCTAssertNil(block.controls)
    }

    // MARK: - Divider block (divider_color, divider_thickness, divider_margin_y)

    func testDecodeDividerBlock() throws {
        let json = """
        {
            "id": "div1",
            "type": "divider",
            "divider_color": "#e5e7eb",
            "divider_thickness": 2,
            "divider_margin_y": 16
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .divider)
        XCTAssertEqual(block.divider_color, "#e5e7eb")
        XCTAssertEqual(block.divider_thickness, 2)
        XCTAssertEqual(block.divider_margin_y, 16)
    }

    func testDecodeDividerBlockMinimal() throws {
        let json = """
        { "id": "div2", "type": "divider" }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .divider)
        XCTAssertNil(block.divider_color)
        XCTAssertNil(block.divider_thickness)
        XCTAssertNil(block.divider_margin_y)
    }

    // MARK: - List block (items, list_style)

    func testDecodeListBlock() throws {
        let json = """
        {
            "id": "list1",
            "type": "list",
            "items": ["Track your progress", "Set daily goals", "Get personalized tips"],
            "list_style": "check"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .list)
        XCTAssertEqual(block.items?.count, 3)
        XCTAssertEqual(block.items?[0], "Track your progress")
        XCTAssertEqual(block.items?[2], "Get personalized tips")
        XCTAssertEqual(block.list_style, "check")
    }

    func testDecodeListBlockBullet() throws {
        let json = """
        {
            "id": "list2",
            "type": "list",
            "items": ["First item", "Second item"],
            "list_style": "bullet"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .list)
        XCTAssertEqual(block.items?.count, 2)
        XCTAssertEqual(block.list_style, "bullet")
    }

    func testDecodeListBlockNumbered() throws {
        let json = """
        {
            "id": "list3",
            "type": "list",
            "items": ["Step one", "Step two", "Step three"],
            "list_style": "numbered"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .list)
        XCTAssertEqual(block.items?.count, 3)
        XCTAssertEqual(block.list_style, "numbered")
    }

    // MARK: - Icon block (icon_ref, icon_emoji, icon_size, icon_alignment)

    func testDecodeIconBlockWithIconRef() throws {
        let json = """
        {
            "id": "icon1",
            "type": "icon",
            "icon_ref": {
                "library": "sf-symbols",
                "name": "star.fill",
                "color": "#f59e0b",
                "size": 48
            },
            "icon_alignment": "center"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .icon)
        XCTAssertNotNil(block.icon_ref)
        XCTAssertEqual(block.icon_ref?.library, "sf-symbols")
        XCTAssertEqual(block.icon_ref?.name, "star.fill")
        XCTAssertEqual(block.icon_ref?.color, "#f59e0b")
        XCTAssertEqual(block.icon_ref?.size, 48)
        XCTAssertEqual(block.icon_alignment, "center")
    }

    func testDecodeIconBlockWithEmoji() throws {
        let json = """
        {
            "id": "icon2",
            "type": "icon",
            "icon_emoji": "rocket",
            "icon_size": 64,
            "icon_alignment": "left"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .icon)
        XCTAssertEqual(block.icon_emoji, "rocket")
        XCTAssertEqual(block.icon_size, 64)
        XCTAssertEqual(block.icon_alignment, "left")
        XCTAssertNil(block.icon_ref)
    }

    func testDecodeIconRefLucideLibrary() throws {
        let json = """
        {
            "id": "icon3",
            "type": "icon",
            "icon_ref": { "library": "lucide", "name": "heart" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.icon_ref?.library, "lucide")
        XCTAssertEqual(block.icon_ref?.name, "heart")
        XCTAssertNil(block.icon_ref?.color)
        XCTAssertNil(block.icon_ref?.size)
    }

    // MARK: - Per-block text style (style object: font_size, font_weight, color, alignment, line_height, letter_spacing, opacity)

    func testDecodeTextStyleAllFields() throws {
        let json = """
        {
            "id": "ts1",
            "type": "text",
            "text": "Styled text",
            "style": {
                "font_family": "Inter",
                "font_size": 18,
                "font_weight": 600,
                "color": "#334155",
                "alignment": "left",
                "line_height": 1.5,
                "letter_spacing": 0.5,
                "opacity": 0.9
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.style)
        XCTAssertEqual(block.style?.font_family, "Inter")
        XCTAssertEqual(block.style?.font_size, 18)
        XCTAssertEqual(block.style?.font_weight, 600)
        XCTAssertEqual(block.style?.color, "#334155")
        XCTAssertEqual(block.style?.alignment, "left")
        XCTAssertEqual(block.style?.line_height, 1.5)
        XCTAssertEqual(block.style?.letter_spacing, 0.5)
        XCTAssertEqual(block.style?.opacity, 0.9)
    }

    func testDecodeTextStyleMinimal() throws {
        let json = """
        {
            "id": "ts2",
            "type": "heading",
            "text": "Title",
            "style": { "font_size": 24 }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.style)
        XCTAssertEqual(block.style?.font_size, 24)
        XCTAssertNil(block.style?.font_family)
        XCTAssertNil(block.style?.font_weight)
        XCTAssertNil(block.style?.color)
        XCTAssertNil(block.style?.alignment)
        XCTAssertNil(block.style?.line_height)
        XCTAssertNil(block.style?.letter_spacing)
        XCTAssertNil(block.style?.opacity)
    }

    // MARK: - Block style partial (only one or a few fields set)

    func testDecodeBlockStylePartialBackgroundOnly() throws {
        let json = """
        {
            "id": "bsp1",
            "type": "text",
            "text": "Partial",
            "block_style": { "background_color": "#f1f5f9" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.block_style)
        XCTAssertEqual(block.block_style?.background_color, "#f1f5f9")
        XCTAssertNil(block.block_style?.background_gradient)
        XCTAssertNil(block.block_style?.border_color)
        XCTAssertNil(block.block_style?.border_width)
        XCTAssertNil(block.block_style?.border_style)
        XCTAssertNil(block.block_style?.border_radius)
        XCTAssertNil(block.block_style?.shadow)
        XCTAssertNil(block.block_style?.padding_top)
        XCTAssertNil(block.block_style?.margin_top)
        XCTAssertNil(block.block_style?.opacity)
    }

    func testDecodeBlockStylePartialBorderOnly() throws {
        let json = """
        {
            "id": "bsp2",
            "type": "button",
            "text": "Outlined",
            "block_style": {
                "border_color": "#6366f1",
                "border_width": 2,
                "border_style": "dashed",
                "border_radius": 8
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.block_style)
        XCTAssertEqual(block.block_style?.border_color, "#6366f1")
        XCTAssertEqual(block.block_style?.border_width, 2)
        XCTAssertEqual(block.block_style?.border_style, "dashed")
        XCTAssertEqual(block.block_style?.border_radius, 8)
        XCTAssertNil(block.block_style?.background_color)
    }

    func testDecodeBlockStylePartialOpacityOnly() throws {
        let json = """
        {
            "id": "bsp3",
            "type": "image",
            "image_url": "fade.jpg",
            "block_style": { "opacity": 0.5 }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.block_style)
        XCTAssertEqual(block.block_style?.opacity, 0.5)
        XCTAssertNil(block.block_style?.background_color)
        XCTAssertNil(block.block_style?.shadow)
    }

    // MARK: - Entrance animation — remaining types (slide_left, slide_right, scale_down)

    func testDecodeEntranceAnimationSlideLeft() throws {
        let json = """
        {
            "id": "ea_sl",
            "type": "text",
            "text": "Slide left",
            "entrance_animation": { "type": "slide_left", "duration_ms": 350, "delay_ms": 50, "easing": "ease_in" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "slide_left")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 350)
        XCTAssertEqual(block.entrance_animation?.delay_ms, 50)
        XCTAssertEqual(block.entrance_animation?.easing, "ease_in")
    }

    func testDecodeEntranceAnimationSlideRight() throws {
        let json = """
        {
            "id": "ea_sr",
            "type": "text",
            "text": "Slide right",
            "entrance_animation": { "type": "slide_right", "duration_ms": 300, "delay_ms": 100, "easing": "ease_in_out" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "slide_right")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 300)
        XCTAssertEqual(block.entrance_animation?.delay_ms, 100)
        XCTAssertEqual(block.entrance_animation?.easing, "ease_in_out")
    }

    func testDecodeEntranceAnimationScaleDown() throws {
        let json = """
        {
            "id": "ea_scd",
            "type": "icon",
            "icon_emoji": "check",
            "entrance_animation": { "type": "scale_down", "duration_ms": 450, "delay_ms": 0, "easing": "linear" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.entrance_animation?.type, "scale_down")
        XCTAssertEqual(block.entrance_animation?.duration_ms, 450)
        XCTAssertEqual(block.entrance_animation?.delay_ms, 0)
        XCTAssertEqual(block.entrance_animation?.easing, "linear")
    }

    // MARK: - Visibility condition — remaining types (always, when_equals explicit, when_lt)

    func testDecodeVisibilityConditionAlways() throws {
        let json = """
        {
            "id": "vc_alw",
            "type": "text",
            "text": "Always visible",
            "visibility_condition": { "type": "always" }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.visibility_condition)
        XCTAssertEqual(block.visibility_condition?.type, "always")
        XCTAssertNil(block.visibility_condition?.variable)
        XCTAssertNil(block.visibility_condition?.value)
        XCTAssertNil(block.visibility_condition?.expression)
    }

    func testDecodeVisibilityConditionWhenEquals() throws {
        let json = """
        {
            "id": "vc_eq",
            "type": "button",
            "text": "Pro feature",
            "visibility_condition": {
                "type": "when_equals",
                "variable": "user.plan",
                "value": "pro"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.visibility_condition?.type, "when_equals")
        XCTAssertEqual(block.visibility_condition?.variable, "user.plan")
    }

    func testDecodeVisibilityConditionWhenLt() throws {
        let json = """
        {
            "id": "vc_lt",
            "type": "text",
            "text": "Under limit",
            "visibility_condition": {
                "type": "when_lt",
                "variable": "responses.step1.score",
                "value": 50
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.visibility_condition?.type, "when_lt")
        XCTAssertEqual(block.visibility_condition?.variable, "responses.step1.score")
    }

    func testDecodeVisibilityConditionWhenNotEmpty() throws {
        let json = """
        {
            "id": "vc_ne2",
            "type": "image",
            "image_url": "avatar.jpg",
            "visibility_condition": {
                "type": "when_not_empty",
                "variable": "user.avatar_url"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.visibility_condition?.type, "when_not_empty")
        XCTAssertEqual(block.visibility_condition?.variable, "user.avatar_url")
        XCTAssertNil(block.visibility_condition?.value)
    }

    // MARK: - Numeric edge cases (negative offsets, zero values, large values)

    func testDecodeNegativeOffsets() throws {
        let json = """
        {
            "id": "neg1",
            "type": "text",
            "text": "Negative offsets",
            "vertical_offset": -20,
            "horizontal_offset": -15
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.vertical_offset, -20)
        XCTAssertEqual(block.horizontal_offset, -15)
    }

    func testDecodeZeroValues() throws {
        let json = """
        {
            "id": "zero1",
            "type": "progress_bar",
            "progress_value": 0,
            "bar_height": 0,
            "segment_gap": 0,
            "total_segments": 0,
            "filled_segments": 0
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.progress_value, 0)
        XCTAssertEqual(block.bar_height, 0)
        XCTAssertEqual(block.segment_gap, 0)
        XCTAssertEqual(block.total_segments, 0)
        XCTAssertEqual(block.filled_segments, 0)
    }

    func testDecodeLargeValues() throws {
        let json = """
        {
            "id": "large1",
            "type": "circular_gauge",
            "gauge_value": 999999.99,
            "max_value": 1000000,
            "stroke_width": 100,
            "animation_duration_ms": 60000
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.gauge_value, 999999.99)
        XCTAssertEqual(block.max_value, 1000000)
        XCTAssertEqual(block.stroke_width, 100)
        XCTAssertEqual(block.animation_duration_ms, 60000)
    }

    func testDecodeNegativeMargins() throws {
        let json = """
        {
            "id": "negm1",
            "type": "text",
            "text": "Overlap",
            "block_style": {
                "margin_top": -8,
                "margin_bottom": -4,
                "padding_top": 0,
                "padding_left": 0
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.block_style?.margin_top, -8)
        XCTAssertEqual(block.block_style?.margin_bottom, -4)
        XCTAssertEqual(block.block_style?.padding_top, 0)
        XCTAssertEqual(block.block_style?.padding_left, 0)
    }

    // MARK: - Multiple blocks decoded as an array

    func testDecodeMultipleBlocksArray() throws {
        let json = """
        [
            { "id": "arr1", "type": "heading", "text": "Title", "level": 1 },
            { "id": "arr2", "type": "text", "text": "Description body text" },
            { "id": "arr3", "type": "button", "text": "Get Started", "variant": "primary", "action": "next" }
        ]
        """.data(using: .utf8)!

        let blocks = try JSONDecoder().decode([ContentBlock].self, from: json)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].type, .heading)
        XCTAssertEqual(blocks[0].text, "Title")
        XCTAssertEqual(blocks[0].level, 1)
        XCTAssertEqual(blocks[1].type, .text)
        XCTAssertEqual(blocks[1].text, "Description body text")
        XCTAssertEqual(blocks[2].type, .button)
        XCTAssertEqual(blocks[2].text, "Get Started")
        XCTAssertEqual(blocks[2].variant, "primary")
        XCTAssertEqual(blocks[2].action, "next")
    }

    // MARK: - Complete form step as JSON (heading + input_text + input_select + button)

    func testDecodeCompleteFormStepBlocks() throws {
        let json = """
        [
            {
                "id": "form_h",
                "type": "heading",
                "text": "Tell us about yourself",
                "level": 2,
                "style": { "font_size": 24, "font_weight": 700, "color": "#ffffff", "alignment": "center" }
            },
            {
                "id": "form_name",
                "type": "input_text",
                "field_id": "full_name",
                "field_label": "Full Name",
                "field_placeholder": "Jane Doe",
                "field_required": true
            },
            {
                "id": "form_goal",
                "type": "input_select",
                "field_id": "goal",
                "field_label": "Primary Goal",
                "field_options": [
                    { "id": "lose", "label": "Lose Weight" },
                    { "id": "gain", "label": "Build Muscle" },
                    { "id": "health", "label": "Get Healthier" }
                ],
                "field_required": true
            },
            {
                "id": "form_btn",
                "type": "button",
                "text": "Continue",
                "variant": "primary",
                "action": "next",
                "bg_color": "#6366f1",
                "text_color": "#ffffff",
                "button_corner_radius": 12
            }
        ]
        """.data(using: .utf8)!

        let blocks = try JSONDecoder().decode([ContentBlock].self, from: json)
        XCTAssertEqual(blocks.count, 4)

        // Heading
        XCTAssertEqual(blocks[0].type, .heading)
        XCTAssertEqual(blocks[0].text, "Tell us about yourself")
        XCTAssertEqual(blocks[0].level, 2)
        XCTAssertEqual(blocks[0].style?.font_size, 24)
        XCTAssertEqual(blocks[0].style?.alignment, "center")

        // Input text
        XCTAssertEqual(blocks[1].type, .input_text)
        XCTAssertEqual(blocks[1].field_id, "full_name")
        XCTAssertEqual(blocks[1].field_label, "Full Name")
        XCTAssertEqual(blocks[1].field_placeholder, "Jane Doe")
        XCTAssertEqual(blocks[1].field_required, true)

        // Input select
        XCTAssertEqual(blocks[2].type, .input_select)
        XCTAssertEqual(blocks[2].field_id, "goal")
        XCTAssertEqual(blocks[2].field_options?.count, 3)
        XCTAssertEqual(blocks[2].field_options?[0].id, "lose")
        XCTAssertEqual(blocks[2].field_options?[0].label, "Lose Weight")
        XCTAssertEqual(blocks[2].field_options?[2].id, "health")
        XCTAssertEqual(blocks[2].field_required, true)

        // Button
        XCTAssertEqual(blocks[3].type, .button)
        XCTAssertEqual(blocks[3].text, "Continue")
        XCTAssertEqual(blocks[3].action, "next")
        XCTAssertEqual(blocks[3].bg_color, "#6366f1")
        XCTAssertEqual(blocks[3].button_corner_radius, 12)
    }

    // MARK: - Social login disabled provider

    func testDecodeSocialLoginDisabledProvider() throws {
        let json = """
        {
            "id": "sl_dis",
            "type": "social_login",
            "providers": [
                { "type": "apple", "enabled": true },
                { "type": "google", "enabled": true },
                { "type": "facebook", "enabled": false },
                { "type": "github", "label": "Sign in with GitHub", "enabled": false }
            ],
            "button_style": "outlined",
            "button_height": 48,
            "spacing": 10,
            "show_divider": false
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .social_login)
        XCTAssertEqual(block.providers?.count, 4)
        XCTAssertEqual(block.providers?[0].type, "apple")
        XCTAssertEqual(block.providers?[0].enabled, true)
        XCTAssertEqual(block.providers?[2].type, "facebook")
        XCTAssertEqual(block.providers?[2].enabled, false)
        XCTAssertEqual(block.providers?[3].type, "github")
        XCTAssertEqual(block.providers?[3].label, "Sign in with GitHub")
        XCTAssertEqual(block.providers?[3].enabled, false)
        XCTAssertEqual(block.button_style, "outlined")
        XCTAssertEqual(block.button_height, 48)
        XCTAssertEqual(block.spacing, 10)
        XCTAssertEqual(block.show_divider, false)
    }

    // MARK: - Countdown timer variants (circular, flip)

    func testDecodeCountdownTimerCircular() throws {
        let json = """
        {
            "id": "ct_circ",
            "type": "countdown_timer",
            "timer_variant": "circular",
            "duration_seconds": 3600,
            "show_hours": true,
            "show_minutes": true,
            "show_seconds": false,
            "accent_color": "#10b981",
            "on_expire_action": "show_expired_text",
            "expired_text": "Time's up!",
            "font_size": 18
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .countdown_timer)
        XCTAssertEqual(block.timer_variant, "circular")
        XCTAssertEqual(block.duration_seconds, 3600)
        XCTAssertEqual(block.show_hours, true)
        XCTAssertEqual(block.show_minutes, true)
        XCTAssertEqual(block.show_seconds, false)
        XCTAssertEqual(block.accent_color, "#10b981")
        XCTAssertEqual(block.on_expire_action, "show_expired_text")
        XCTAssertEqual(block.expired_text, "Time's up!")
        XCTAssertEqual(block.font_size, 18)
    }

    func testDecodeCountdownTimerFlip() throws {
        let json = """
        {
            "id": "ct_flip",
            "type": "countdown_timer",
            "timer_variant": "flip",
            "duration_seconds": 300,
            "show_days": false,
            "show_hours": false,
            "show_minutes": true,
            "show_seconds": true,
            "labels": {
                "minutes": "min",
                "seconds": "sec"
            },
            "accent_color": "#f97316",
            "on_expire_action": "hide"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .countdown_timer)
        XCTAssertEqual(block.timer_variant, "flip")
        XCTAssertEqual(block.duration_seconds, 300)
        XCTAssertEqual(block.show_days, false)
        XCTAssertEqual(block.show_hours, false)
        XCTAssertEqual(block.show_minutes, true)
        XCTAssertEqual(block.show_seconds, true)
        XCTAssertNotNil(block.labels)
        XCTAssertEqual(block.labels?.minutes, "min")
        XCTAssertEqual(block.labels?.seconds, "sec")
        XCTAssertNil(block.labels?.hours)
        XCTAssertNil(block.labels?.days)
        XCTAssertEqual(block.accent_color, "#f97316")
        XCTAssertEqual(block.on_expire_action, "hide")
    }

    func testDecodeCountdownTimerBar() throws {
        let json = """
        {
            "id": "ct_bar",
            "type": "countdown_timer",
            "timer_variant": "bar",
            "duration_seconds": 60,
            "show_seconds": true,
            "on_expire_action": "auto_advance"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .countdown_timer)
        XCTAssertEqual(block.timer_variant, "bar")
        XCTAssertEqual(block.duration_seconds, 60)
        XCTAssertEqual(block.on_expire_action, "auto_advance")
    }

    // MARK: - Star background block

    func testDecodeStarBackground() throws {
        let json = """
        {
            "id": "sb1",
            "type": "star_background",
            "particle_type": "stars",
            "density": "dense",
            "speed": "slow",
            "active_color": "#ffffff",
            "secondary_color": "#a78bfa",
            "size_range": [1.0, 4.0],
            "fullscreen": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .star_background)
        XCTAssertEqual(block.particle_type, "stars")
        XCTAssertEqual(block.density, "dense")
        XCTAssertEqual(block.speed, "slow")
        XCTAssertEqual(block.secondary_color, "#a78bfa")
        XCTAssertEqual(block.size_range?.count, 2)
        XCTAssertEqual(block.size_range?[0], 1.0)
        XCTAssertEqual(block.size_range?[1], 4.0)
        XCTAssertEqual(block.fullscreen, true)
    }

    func testDecodeStarBackgroundSparkles() throws {
        let json = """
        {
            "id": "sb2",
            "type": "star_background",
            "particle_type": "sparkles",
            "density": "sparse",
            "speed": "fast",
            "fullscreen": false
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .star_background)
        XCTAssertEqual(block.particle_type, "sparkles")
        XCTAssertEqual(block.density, "sparse")
        XCTAssertEqual(block.speed, "fast")
        XCTAssertEqual(block.fullscreen, false)
        XCTAssertNil(block.secondary_color)
        XCTAssertNil(block.size_range)
    }

    func testDecodeStarBackgroundSnow() throws {
        let json = """
        {
            "id": "sb3",
            "type": "star_background",
            "particle_type": "snow",
            "density": "medium",
            "speed": "medium",
            "secondary_color": "#e0e7ff",
            "fullscreen": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.particle_type, "snow")
        XCTAssertEqual(block.density, "medium")
        XCTAssertEqual(block.speed, "medium")
        XCTAssertEqual(block.secondary_color, "#e0e7ff")
    }

    // MARK: - Pricing card block with multiple plans

    func testDecodePricingCardMultiplePlans() throws {
        let json = """
        {
            "id": "pc_multi",
            "type": "pricing_card",
            "pricing_plans": [
                { "id": "free", "label": "Free", "price": "$0", "period": "/month", "is_highlighted": false },
                { "id": "pro", "label": "Pro", "price": "$9.99", "period": "/month", "badge": "POPULAR", "is_highlighted": true },
                { "id": "annual", "label": "Annual", "price": "$79.99", "period": "/year", "badge": "SAVE 33%", "is_highlighted": false },
                { "id": "lifetime", "label": "Lifetime", "price": "$199.99", "period": "one-time", "is_highlighted": false }
            ],
            "pricing_layout": "side_by_side"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .pricing_card)
        XCTAssertEqual(block.pricing_plans?.count, 4)
        XCTAssertEqual(block.pricing_layout, "side_by_side")

        // Free plan
        XCTAssertEqual(block.pricing_plans?[0].id, "free")
        XCTAssertEqual(block.pricing_plans?[0].label, "Free")
        XCTAssertEqual(block.pricing_plans?[0].price, "$0")
        XCTAssertEqual(block.pricing_plans?[0].period, "/month")
        XCTAssertEqual(block.pricing_plans?[0].is_highlighted, false)
        XCTAssertNil(block.pricing_plans?[0].badge)

        // Pro plan (highlighted)
        XCTAssertEqual(block.pricing_plans?[1].id, "pro")
        XCTAssertEqual(block.pricing_plans?[1].badge, "POPULAR")
        XCTAssertEqual(block.pricing_plans?[1].is_highlighted, true)

        // Annual plan (badge, not highlighted)
        XCTAssertEqual(block.pricing_plans?[2].id, "annual")
        XCTAssertEqual(block.pricing_plans?[2].price, "$79.99")
        XCTAssertEqual(block.pricing_plans?[2].badge, "SAVE 33%")
        XCTAssertEqual(block.pricing_plans?[2].is_highlighted, false)

        // Lifetime plan
        XCTAssertEqual(block.pricing_plans?[3].id, "lifetime")
        XCTAssertEqual(block.pricing_plans?[3].period, "one-time")
    }

    func testDecodePricingCardSinglePlan() throws {
        let json = """
        {
            "id": "pc_single",
            "type": "pricing_card",
            "pricing_plans": [
                { "id": "only", "label": "Premium", "price": "$4.99", "period": "/week", "badge": "TRIAL", "is_highlighted": true }
            ],
            "pricing_layout": "stack"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.pricing_plans?.count, 1)
        XCTAssertEqual(block.pricing_plans?[0].id, "only")
        XCTAssertEqual(block.pricing_plans?[0].price, "$4.99")
        XCTAssertEqual(block.pricing_plans?[0].period, "/week")
        XCTAssertEqual(block.pricing_plans?[0].badge, "TRIAL")
        XCTAssertEqual(block.pricing_plans?[0].is_highlighted, true)
        XCTAssertEqual(block.pricing_layout, "stack")
    }

    // MARK: - Form field style

    func testDecodeFormFieldStyle() throws {
        let json = """
        {
            "id": "ffs1",
            "type": "input_text",
            "field_id": "username",
            "field_label": "Username",
            "field_style": {
                "background_color": "#1e293b",
                "border_color": "#334155",
                "border_width": 1,
                "corner_radius": 8,
                "height": "lg",
                "text_color": "#f1f5f9",
                "placeholder_color": "#64748b",
                "font_size": 16,
                "font_weight": "500",
                "focused_border_color": "#6366f1",
                "focused_background_color": "#0f172a",
                "label_color": "#94a3b8",
                "label_font_size": 12,
                "error_border_color": "#ef4444",
                "error_text_color": "#fca5a5"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.field_style)
        XCTAssertEqual(block.field_style?.background_color, "#1e293b")
        XCTAssertEqual(block.field_style?.border_color, "#334155")
        XCTAssertEqual(block.field_style?.border_width, 1)
        XCTAssertEqual(block.field_style?.corner_radius, 8)
        XCTAssertEqual(block.field_style?.height, "lg")
        XCTAssertEqual(block.field_style?.text_color, "#f1f5f9")
        XCTAssertEqual(block.field_style?.placeholder_color, "#64748b")
        XCTAssertEqual(block.field_style?.font_size, 16)
        XCTAssertEqual(block.field_style?.font_weight, "500")
        XCTAssertEqual(block.field_style?.focused_border_color, "#6366f1")
        XCTAssertEqual(block.field_style?.focused_background_color, "#0f172a")
        XCTAssertEqual(block.field_style?.label_color, "#94a3b8")
        XCTAssertEqual(block.field_style?.label_font_size, 12)
        XCTAssertEqual(block.field_style?.error_border_color, "#ef4444")
        XCTAssertEqual(block.field_style?.error_text_color, "#fca5a5")
    }

    func testDecodeFormFieldStyleToggleColors() throws {
        let json = """
        {
            "id": "ffs2",
            "type": "input_toggle",
            "field_id": "dark_mode",
            "field_label": "Dark Mode",
            "field_style": {
                "toggle_on_color": "#22c55e",
                "toggle_off_color": "#6b7280",
                "track_color": "#374151",
                "fill_color": "#10b981",
                "thumb_color": "#ffffff"
            }
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertNotNil(block.field_style)
        XCTAssertEqual(block.field_style?.toggle_on_color, "#22c55e")
        XCTAssertEqual(block.field_style?.toggle_off_color, "#6b7280")
        XCTAssertEqual(block.field_style?.track_color, "#374151")
        XCTAssertEqual(block.field_style?.fill_color, "#10b981")
        XCTAssertEqual(block.field_style?.thumb_color, "#ffffff")
    }

    // MARK: - Spacer with height

    func testDecodeSpacerWithHeight() throws {
        let json = """
        {
            "id": "sp1",
            "type": "spacer",
            "spacer_height": 32
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .spacer)
        XCTAssertEqual(block.spacer_height, 32)
    }

    // MARK: - Button action variants

    func testDecodeButtonLinkAction() throws {
        let json = """
        {
            "id": "btn_link",
            "type": "button",
            "text": "Learn More",
            "variant": "secondary",
            "action": "link",
            "action_value": "https://example.com/about",
            "text_color": "#6366f1"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .button)
        XCTAssertEqual(block.action, "link")
        XCTAssertEqual(block.action_value, "https://example.com/about")
        XCTAssertEqual(block.variant, "secondary")
    }

    func testDecodeButtonSkipAction() throws {
        let json = """
        {
            "id": "btn_skip",
            "type": "button",
            "text": "Skip",
            "variant": "minimal",
            "action": "skip"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.action, "skip")
        XCTAssertEqual(block.variant, "minimal")
        XCTAssertNil(block.action_value)
    }

    // MARK: - All remaining form input types

    func testDecodeInputTextarea() throws {
        let json = """
        {
            "id": "fita1",
            "type": "input_textarea",
            "field_id": "bio",
            "field_label": "About You",
            "field_placeholder": "Tell us something..."
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_textarea)
        XCTAssertEqual(block.field_id, "bio")
    }

    func testDecodeInputPhone() throws {
        let json = """
        {
            "id": "fiph1",
            "type": "input_phone",
            "field_id": "phone_number",
            "field_label": "Phone",
            "field_required": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_phone)
        XCTAssertEqual(block.field_id, "phone_number")
        XCTAssertEqual(block.field_required, true)
    }

    func testDecodeInputPassword() throws {
        let json = """
        {
            "id": "fipw1",
            "type": "input_password",
            "field_id": "password",
            "field_label": "Password",
            "field_placeholder": "At least 8 characters",
            "field_required": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_password)
        XCTAssertEqual(block.field_id, "password")
        XCTAssertEqual(block.field_placeholder, "At least 8 characters")
    }

    func testDecodeInputTime() throws {
        let json = """
        {
            "id": "fit_time",
            "type": "input_time",
            "field_id": "wake_time",
            "field_label": "Wake Up Time"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_time)
        XCTAssertEqual(block.field_id, "wake_time")
    }

    func testDecodeInputDatetime() throws {
        let json = """
        {
            "id": "fidt1",
            "type": "input_datetime",
            "field_id": "appointment",
            "field_label": "Appointment Time",
            "field_required": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_datetime)
        XCTAssertEqual(block.field_id, "appointment")
    }

    func testDecodeInputStepper() throws {
        let json = """
        {
            "id": "fist1",
            "type": "input_stepper",
            "field_id": "quantity",
            "field_label": "Quantity"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_stepper)
        XCTAssertEqual(block.field_id, "quantity")
    }

    func testDecodeInputSegmented() throws {
        let json = """
        {
            "id": "fiseg1",
            "type": "input_segmented",
            "field_id": "plan_type",
            "field_label": "Plan",
            "field_options": [
                { "id": "monthly", "label": "Monthly" },
                { "id": "annual", "label": "Annual" }
            ]
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_segmented)
        XCTAssertEqual(block.field_options?.count, 2)
        XCTAssertEqual(block.field_options?[0].id, "monthly")
        XCTAssertEqual(block.field_options?[1].id, "annual")
    }

    func testDecodeInputLocation() throws {
        let json = """
        {
            "id": "filoc1",
            "type": "input_location",
            "field_id": "home_city",
            "field_label": "City",
            "field_placeholder": "Search for your city"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_location)
        XCTAssertEqual(block.field_id, "home_city")
        XCTAssertEqual(block.field_placeholder, "Search for your city")
    }

    func testDecodeInputRating() throws {
        let json = """
        {
            "id": "firat1",
            "type": "input_rating",
            "field_id": "satisfaction",
            "field_label": "How satisfied are you?"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_rating)
        XCTAssertEqual(block.field_id, "satisfaction")
    }

    func testDecodeInputRangeSlider() throws {
        let json = """
        {
            "id": "firs1",
            "type": "input_range_slider",
            "field_id": "price_range",
            "field_label": "Price Range"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_range_slider)
        XCTAssertEqual(block.field_id, "price_range")
    }

    func testDecodeInputImagePicker() throws {
        let json = """
        {
            "id": "fiip1",
            "type": "input_image_picker",
            "field_id": "profile_photo",
            "field_label": "Profile Photo"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_image_picker)
        XCTAssertEqual(block.field_id, "profile_photo")
    }

    func testDecodeInputColor() throws {
        let json = """
        {
            "id": "ficol1",
            "type": "input_color",
            "field_id": "theme_color",
            "field_label": "Pick a Color"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_color)
        XCTAssertEqual(block.field_id, "theme_color")
    }

    func testDecodeInputUrl() throws {
        let json = """
        {
            "id": "fiurl1",
            "type": "input_url",
            "field_id": "website",
            "field_label": "Website",
            "field_placeholder": "https://yoursite.com"
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_url)
        XCTAssertEqual(block.field_id, "website")
        XCTAssertEqual(block.field_placeholder, "https://yoursite.com")
    }

    func testDecodeInputSignature() throws {
        let json = """
        {
            "id": "fisig1",
            "type": "input_signature",
            "field_id": "legal_signature",
            "field_label": "Sign here",
            "field_required": true
        }
        """.data(using: .utf8)!

        let block = try JSONDecoder().decode(ContentBlock.self, from: json)
        XCTAssertEqual(block.type, .input_signature)
        XCTAssertEqual(block.field_id, "legal_signature")
        XCTAssertEqual(block.field_required, true)
    }
}
