import SnapshotTesting
import SwiftUI
import XCTest
@testable import AppDNASDK

/// SPEC-419 EPIC-1 (Select overhaul) — iOS visual snapshots (surface #4: onboarding select).
///
/// Mirrors the Android Roborazzi `SelectEpic1SnapshotTest` with the SAME select configs so the
/// iOS + Android goldens are directly comparable (cross-platform parity, both systems 100%).
///
/// Record the goldens (first run / after an intended render change):
///   xcodebuild test -scheme AppDNASDK \
///     -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
///     -only-testing:AppDNASDKTests/VisualSnapshotTests RECORD_SNAPSHOTS=YES
/// Then commit Tests/__Snapshots__/. CI re-runs without RECORD_SNAPSHOTS and fails on pixel deltas.
final class VisualSnapshotTests: XCTestCase {

    /// Compare by default (CI fails on pixel drift); record only when the bridge/env asks.
    /// The bridge passes TEST_RUNNER_RECORD_SNAPSHOTS, which xcodebuild forwards to the sim
    /// test process as RECORD_SNAPSHOTS (plain env vars don't reach the test runner).
    ///
    /// Seven tests from the SPEC-438/439/441 batch asserted OUTSIDE this, so they could not be
    /// re-recorded through the bridge at all — which is how the #541 golden stayed pinned to the
    /// filter build after the render was corrected to section navigation, and the iOS suite sat
    /// red on a golden nobody could refresh.
    private var recordMode: SnapshotTestingConfiguration.Record {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
    }

    private func render(_ json: String, inputs: [String: Any] = [:], pad: CGFloat = 16) throws -> some View {
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        return ContentBlockRendererView(
            blocks: [block],
            onAction: { _, _ in },
            toggleValues: .constant([:]),
            inputValues: .constant(inputs)
        )
            .padding(pad)
            .frame(width: 390)
            .background(Color(hex: "#0F1117"))
    }

    // MARK: - SPEC-441 (#541) — category chips on a Select

    /// The screen the reporter sent: a scrollable chip row above the options, the active chip
    /// filtering the list, and a header echoing it. Only pixels can show the row scrolls and
    /// the filter actually narrows the options.
    private static let chipSelectJSON = """
    {
      "id": "sel_chips", "type": "input_select",
      "field_id": "sound",
      "field_label": "Choose your own alarm sound",
      "field_config": {
        "display_style": "stacked",
        "category_header": true,
        "categories": [
          { "id": "trending", "label": "Trending", "icon": "💖" },
          { "id": "loud", "label": "Loud", "icon": "💥" },
          { "id": "alarm", "label": "Alarm tone", "icon": "🔔" },
          { "id": "classic", "label": "Classical", "icon": "🎻" }
        ]
      },
      "field_options": [
        { "id": "o1", "label": "Wake up you lazy", "category": "trending" },
        { "id": "o2", "label": "You're gonna be late", "category": "trending" },
        { "id": "o3", "label": "Rise and Shine Mothertrucker", "category": "trending" },
        { "id": "o4", "label": "Air Horn", "category": "loud" },
        { "id": "o5", "label": "Available under every chip", "category": null }
      ]
    }
    """

    func testSelectCategoryChips_firstChipActive() throws {
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: try! render(Self.chipSelectJSON), as: .image(layout: .sizeThatFits))
        }
    }

    // MARK: - SPEC-439 (#546) — input label position / align / font

    /// A Select whose LABEL is the thing under test. `label_position: hidden` was decoded by
    /// neither native before this change, so a label the author hid still rendered on device —
    /// the editor showed one thing and the phone another. Only pixels can show it is gone.
    private static func labelSelectJSON(_ fieldStyle: String) -> String {
        """
        {
          "id": "sel_label", "type": "input_select",
          "field_id": "sound",
          "field_label": "Choose an alarm sound",
          "field_style": \(fieldStyle),
          "field_config": { "display_style": "stacked" },
          "field_options": [
            { "id": "o1", "label": "Trending" },
            { "id": "o2", "label": "Loud" }
          ]
        }
        """
    }

    func testSelectLabel_hidden_rendersNoLabel() throws {
        let v = try render(Self.labelSelectJSON("""
        { "label_position": "hidden", "label_color": "#E5E7EB", "label_font_size": 15 }
        """))
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: v, as: .image(layout: .sizeThatFits))
        }
    }

    func testSelectLabel_above_default() throws {
        let v = try render(Self.labelSelectJSON("""
        { "label_position": "above", "label_color": "#E5E7EB", "label_font_size": 15 }
        """))
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: v, as: .image(layout: .sizeThatFits))
        }
    }

    func testSelectLabel_centerAligned() throws {
        let v = try render(Self.labelSelectJSON("""
        { "label_position": "above", "label_align": "center", "label_color": "#E5E7EB", "label_font_size": 15 }
        """))
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: v, as: .image(layout: .sizeThatFits))
        }
    }

    func testSelectLabel_rightAlignedLarge() throws {
        let v = try render(Self.labelSelectJSON("""
        { "label_position": "above", "label_align": "right", "label_color": "#E5E7EB", "label_font_size": 24 }
        """))
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: v, as: .image(layout: .sizeThatFits))
        }
    }

    // MARK: - SPEC-438 (#544, #548) — product-level price presentation

    /// Renders the REAL PlanCard from a console-shaped plan JSON, so the pill and the
    /// headline price layout are checked as pixels rather than as decoded fields. The
    /// strings are the production ones from the reported paywall: the length of
    /// "25,00 zł miesięcznie" is the whole reason #545 existed.
    private func renderPlanCard(planJSON: String, style: PlanCardStyle) throws -> some View {
        let plan = try JSONDecoder().decode(PaywallPlan.self, from: Data(planJSON.utf8))
        return PlanCard(plan: plan, isSelected: true, onSelect: {}, cardStyle: style)
            .padding(16)
            .frame(width: 390)
            .background(Color(hex: "#0F1117"))
    }

    private static let promoPlanJSON = """
    {
      "id": "annual",
      "product_id": "app.premium.annual",
      "label": "Rocznie",
      "price_display": "25,00 zł miesięcznie",
      "original_price_display": "359,88 zł",
      "price_total_display": "299,99 zł rocznie",
      "description": "7-dniowy okres próbny",
      "description_badge": {
        "enabled": true,
        "bg_color": "#15803D",
        "text_color": "#DCFCE7",
        "corner_radius": 6
      },
      "is_default": true
    }
    """

    func testPlanCard_headlineStacked_withSubtitlePill() throws {
        var style = PlanCardStyle()
        style.showSubtitle = true
        style.priceLayout = "headline_stacked"
        style.strikethroughColor = "#9CA3AF"
        style.strikethroughFontSize = 13
        style.strikethroughGap = 8
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: try! renderPlanCard(planJSON: Self.promoPlanJSON, style: style), as: .image(layout: .sizeThatFits))
        }
    }

    /// The default. Must look exactly like it did before SPEC-438 — no charged total,
    /// struck price inline — because every existing paywall renders through this path.
    func testPlanCard_inlineDefault_unchanged() throws {
        var style = PlanCardStyle()
        style.showSubtitle = true
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: try! renderPlanCard(planJSON: Self.promoPlanJSON, style: style), as: .image(layout: .sizeThatFits))
        }
    }

    private func renderMany(_ jsons: [String]) throws -> some View {
        let blocks = try jsons.map { try JSONDecoder().decode(ContentBlock.self, from: Data($0.utf8)) }
        return ContentBlockRendererView(
            blocks: blocks,
            onAction: { _, _ in },
            toggleValues: .constant([:]),
            inputValues: .constant([:])
        )
            .padding(16)
            .frame(width: 390)
            .background(Color(hex: "#0F1117"))
    }

    /// Like renderMany but feeds a `responses` context (for EPIC-5 variable bindings + visibility conditions).
    private func renderConditional(_ jsons: [String], responses: [String: Any]) throws -> some View {
        let blocks = try jsons.map { try JSONDecoder().decode(ContentBlock.self, from: Data($0.utf8)) }
        return ContentBlockRendererView(
            blocks: blocks,
            onAction: { _, _ in },
            toggleValues: .constant([:]),
            responses: responses,
            inputValues: .constant([:])
        )
            .padding(16)
            .frame(width: 390)
            .background(Color(hex: "#0F1117"))
    }

    /// leading_text + trailing_text on one row + positionable "RECOMMENDED" badge + subtitle.
    func testSelectStacked_leadingTrailingBadge() throws {
        let view = try render("""
        {
          "id": "sel1", "type": "input_select",
          "field_config": { "display_style": "stacked" },
          "field_options": [
            { "id": "o1", "label": "Casual", "leading_text": "5 min/day", "trailing_text": "Easy",
              "badge": { "text": "RECOMMENDED", "bg_color": "#22C55E", "text_color": "#FFFFFF", "position": "top_trailing" } },
            { "id": "o2", "label": "Regular", "leading_text": "10 min/day", "trailing_text": "Steady" },
            { "id": "o3", "label": "Serious", "subtitle": "Big goals", "leading_text": "15 min/day", "trailing_text": "Hard" }
          ]
        }
        """)
        // Compare by default (CI fails on pixel drift); record only when the bridge/env asks.
        // The bridge passes TEST_RUNNER_RECORD_SNAPSHOTS, which xcodebuild forwards to the sim
        // test process as RECORD_SNAPSHOTS (plain env vars don't reach the test runner).
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Per-option center alignment (title + subtitle centered).
    func testSelectStacked_centerAligned() throws {
        let view = try render("""
        {
          "id": "sel2", "type": "input_select",
          "field_config": { "display_style": "stacked" },
          "field_options": [
            { "id": "c1", "label": "Beginner", "subtitle": "Just starting out", "text_alignment": "center" },
            { "id": "c2", "label": "Intermediate", "subtitle": "Some experience", "text_alignment": "center" },
            { "id": "c3", "label": "Advanced", "subtitle": "Very experienced", "text_alignment": "center" }
          ]
        }
        """)
        // Compare by default (CI fails on pixel drift); record only when the bridge/env asks.
        // The bridge passes TEST_RUNNER_RECORD_SNAPSHOTS, which xcodebuild forwards to the sim
        // test process as RECORD_SNAPSHOTS (plain env vars don't reach the test runner).
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Per-option image_overlay_color tint (parity with Android ContentBlockRenderer).
    func testSelectStacked_imageOverlay() throws {
        let view = try render("""
        {
          "id": "sel3", "type": "input_select",
          "field_config": { "display_style": "stacked" },
          "field_options": [
            { "id": "i1", "label": "Circle", "image_url": "https://example.com/a.png", "image_overlay_color": "#FF5722", "image_overlay_opacity": 0.85 },
            { "id": "i2", "label": "Rounded", "image_url": "https://example.com/b.png", "image_shape": "rounded", "image_overlay_color": "#2196F3", "image_overlay_opacity": 0.85 },
            { "id": "i3", "label": "Square", "image_url": "https://example.com/c.png", "image_shape": "square", "image_overlay_color": "#22C55E", "image_overlay_opacity": 0.85 }
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Selected-state styling — option "b" selected (green accent): selected gets the accent
    /// border + tinted bg; unselected get the neutral gray border (no more purple-border bug).
    func testSelectStacked_selectedState() throws {
        let view = try render("""
        {
          "id": "sel4", "type": "input_select",
          "field_config": { "display_style": "stacked" },
          "field_style": { "fill_color": "#22C55E" },
          "field_options": [
            { "id": "a", "value": "a", "label": "Casual", "subtitle": "Easy pace" },
            { "id": "b", "value": "b", "label": "Regular", "subtitle": "Recommended" },
            { "id": "c", "value": "c", "label": "Serious", "subtitle": "Intense" }
          ]
        }
        """, inputs: ["sel4": "b"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Selected-state image tint — "Picked" is selected → its image uses selected_image_overlay_color
    /// (green); "Other" is unselected → it uses the base image_overlay_color (gray). Parity with Android.
    func testSelectStacked_selectedImageTint() throws {
        let view = try render("""
        {
          "id": "sel5", "type": "input_select",
          "field_config": { "display_style": "stacked" },
          "field_options": [
            { "id": "p", "value": "p", "label": "Picked", "image_url": "https://example.com/a.png", "image_overlay_color": "#9CA3AF", "selected_image_overlay_color": "#22C55E", "image_overlay_opacity": 0.85, "selected_image_overlay_opacity": 0.85 },
            { "id": "q", "value": "q", "label": "Other", "image_url": "https://example.com/b.png", "image_overlay_color": "#9CA3AF", "image_overlay_opacity": 0.85 }
          ]
        }
        """, inputs: ["sel5": "p"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-447 (#555) — the two layouts that move the text OFF the image.
    ///
    /// A dto_parsing fixture proves the keys reach the model; it cannot prove a renderer honours
    /// them — I verified that by deleting Android's `tile_image_layout` read and watching the
    /// fixture stay green. Only pixels close that gap, which is why the spec's acceptance
    /// criterion is "asserted by golden BYTES differing" rather than by inspection.
    private static func tilesJSON(_ layoutConfig: String, optionExtras: String = "") -> String {
        """
        {
          "id": "tiles_layout", "type": "input_select",
          "field_config": { "display_style": "image_tiles", "grid_columns": 2, \(layoutConfig) },
          "field_style": { "fill_color": "#FACC15" },
          "field_options": [
            { "id": "w1", "value": "w1", "label": "Sunrise Vineyard", "subtitle": "Lakeside", "image_url": "https://example.com/a.png"\(optionExtras) },
            { "id": "w2", "value": "w2", "label": "Southridge Vineyard", "subtitle": "Highlands", "image_url": "https://example.com/b.png"\(optionExtras) }
          ]
        }
        """
    }

    func testSelect_imageTiles_imageStrip() throws {
        let view = try render(Self.tilesJSON("""
        "tile_image_layout": "image_strip", "tile_strip_ratio": 0.75, "tile_surface_color": "#1F2937"
        """), inputs: ["tiles_layout": "w1"])
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-447 AC — "in image_strip and contained the overlay covers the IMAGE REGION ONLY;
    /// switching layout with a dark scrim set must not dim the text surface."
    ///
    /// The overlay was an unconstrained `Color` in the ZStack, so it tinted the band too and the
    /// authored `tile_surface_color` came out muddied by a setting meant for the photograph. Every
    /// key still parsed and every view still drew, so only pixels show it — and only iOS pixels
    /// show it on iOS, since this renderer is separate from Android's.
    func testSelect_imageTiles_stripOverlayDoesNotDimTheBand() throws {
        let overlay = ", \"image_overlay_color\": \"#000000\", \"image_overlay_opacity\": 0.6"
        let view = try render(Self.tilesJSON("""
        "tile_image_layout": "image_strip", "tile_strip_ratio": 0.75, "tile_surface_color": "#1F2937"
        """, optionExtras: overlay), inputs: ["tiles_layout": "w1"])
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-446 §3 — a Summary Screen stat that HOSTS a control.
    ///
    /// The required-gate for these shipped without the rendering half on both platforms:
    /// `RequiredFieldGate` blocked on an unanswered stat input while nothing ever drew one, so a
    /// stat marked required could not be satisfied and the step could not be advanced. Every fixture
    /// passed, because a fixture sets `inputValues` directly and never asks a renderer to produce
    /// the control a user is supposed to touch. Only pixels separate those two states.
    ///
    /// The second card reads `{{step.party}}`, which is the reporter's own case: a value shown live
    /// on the SAME screen as the control that sets it. It also pins the first-frame bug found while
    /// recording this — the control seeds its default after composition, so without merging authored
    /// defaults into the resolver that card resolved to nothing and was suppressed entirely.
    // MARK: - The summary-stat slider has NO iOS pixel golden, on purpose
    //
    // There WAS one. It passed on the machine that recorded it and failed every CI run, because it
    // was the only snapshot in this suite containing a SwiftUI `Slider` -- a control the OS draws,
    // and draws differently on the runner's iOS than on the recording machine. A tolerance did not
    // rescue it (0.99/0.97 still failed), which is the tell that the two renders differ by more
    // than antialiasing. Re-recording on the runner image is not possible from a development
    // machine, and a golden that can only be verified in one place is not a test -- it is a
    // tripwire that fires on the environment rather than on the code.
    //
    // The claim it was making is still covered, on surfaces where it is actually verifiable:
    //
    //   * Android `summary_stat_slider.png` (Roborazzi) renders the SAME case deterministically on
    //     the JVM and runs in CI, so "the control is drawn" is still proven -- just not twice.
    //   * `step_advance/summary_required_stat_gate` asserts `prefilled_stat_seeds_control`, and
    //     that the gate blocks while unanswered and releases once answered, on BOTH natives.
    //   * `template_engine/summary_stat_and_pipe_resolution` asserts the sibling `{{step.x}}` stat
    //     resolves from what the control wrote.
    //
    // What is genuinely lost is an iOS-side pixel record of the slider's own appearance. Recording
    // one on the CI image is the fix if that is ever wanted. A skip-list here is not -- and
    // `check:fixture-runner-skips` would catch it.

    // MARK: - #581 / #580 — the new Image styles and the Sound Button icon
    //
    // A fixture proves the keys are DECODED; only a snapshot proves they are DRAWN. Both features
    // are entirely visual, so a decode-only test would pass against a renderer that reads every
    // value and ignores it.

    func testImage_glowStyle() throws {
        let view = try render("""
        {
          "id": "img_glow", "type": "image", "image_url": "https://example.com/a.png",
          "image_frame": "glow", "height": 160, "corner_radius": 16,
          "field_config": { "frame_glow_color": "#F472B6" }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    func testImage_colorFrameStyle() throws {
        let view = try render("""
        {
          "id": "img_cf", "type": "image", "image_url": "https://example.com/a.png",
          "image_frame": "color_frame", "height": 160,
          "field_config": { "frame_color": "#F59E0B", "frame_corner_radius": 24 }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Thin beside thick is the point — the two differ only in bezel padding and radii, and a
    /// golden of one alone would not show a renderer that ignored the distinction.
    func testImage_phoneMockupThin() throws {
        let view = try render("""
        {
          "id": "img_thin", "type": "image", "image_url": "https://example.com/a.png",
          "image_frame": "phone_thin", "height": 160
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    func testSound_buttonPlayIcon() throws {
        let view = try render("""
        {
          "id": "snd_icon", "type": "sound_button", "text": "Play sound",
          "audio_url": "https://example.com/clip.mp3",
          "field_config": { "sound_icon": "play", "sound_icon_size": 24, "sound_icon_color": "#FDE047", "sound_icon_gap": 12 }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// #578 — the divider between two SPECIFIC providers.
    ///
    /// Three providers with the divider in the middle slot. A decode test cannot catch the bug
    /// this guards: a renderer that reads the slot and then places the divider at the end still
    /// parses everything correctly. Only the picture shows where it landed.
    func testSocial_dividerBetweenProviders() throws {
        let view = try render("""
        {
          "id": "social_div", "type": "social_login",
          "show_divider": true, "divider_text": "or", "divider_position": "after",
          "field_config": { "divider_after_index": 1 },
          "providers": [
            {"type": "apple", "label": "Continue with Apple"},
            {"type": "google", "label": "Continue with Google"},
            {"type": "email", "label": "Continue with Email"}
          ]
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// The end slot, beside the interior one. `bottom` must still draw EXACTLY ONE divider — the
    /// failure mode when the end is guarded on "not top" is two of them.
    func testSocial_dividerAtBottom() throws {
        let view = try render("""
        {
          "id": "social_div_b", "type": "social_login",
          "show_divider": true, "divider_text": "or", "divider_position": "bottom",
          "providers": [
            {"type": "apple", "label": "Continue with Apple"},
            {"type": "google", "label": "Continue with Google"}
          ]
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    // MARK: - Map (SPEC-451)

    /// The fallback state, at an aspect-ratio height.
    ///
    /// This is the state most authors will see first — a customer who has not pasted a Mapbox token
    /// yet — and it is the one a decode test cannot judge at all. What the picture pins is that the
    /// surface is the AUTHORED colour, the corner radius is honoured, the label is centred, and
    /// 16:9 resolves against the same 390pt reference width Android uses. Android computes that
    /// height in its own code; only paired goldens show the two agreeing.
    func testMap_fallbackAtAspectRatio() throws {
        let view = try render("""
        {
          "id": "map_fallback", "type": "map",
          "field_config": {
            "map_mode": "route",
            "map_height_mode": "aspect", "map_aspect": "16:9",
            "map_corner_radius": 20,
            "map_surface_color": "#1F2937",
            "map_fallback_text": "Route unavailable offline",
            "map_stops": [
              {"title": "A", "lat": 52.2297, "lng": 21.0122},
              {"title": "B", "lat": 54.352, "lng": 18.6466}
            ]
          }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// The place info card overlaid on the map.
    ///
    /// Position is purely visual: a renderer that reads `place_info_position` and then always draws
    /// the card below parses every field correctly and looks right in no screenshot. The card's
    /// colours and radius ride along, because "authored colour honoured" is the other thing a
    /// parse cannot show.
    func testMap_placeInfoCardOverlaid() throws {
        let view = try render("""
        {
          "id": "map_place", "type": "map",
          "field_config": {
            "map_mode": "place",
            "map_height": 200, "map_corner_radius": 14,
            "map_surface_color": "#111827",
            "map_fallback_text": "Map unavailable",
            "place_lat": 51.5072, "place_lng": -0.1276,
            "place_title": "Our Shoreditch studio",
            "place_subtitle": "Open daily 11-6 · tastings from £15",
            "place_info_position": "overlay_bottom",
            "place_info_bg": "#FFFFFF", "place_info_text": "#111827", "place_info_radius": 12
          }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// The same card BELOW the map rather than over it — the case that separates a renderer which
    /// honours the position from one that has a single hard-coded layout.
    func testMap_placeInfoCardBelow() throws {
        let view = try render("""
        {
          "id": "map_place_below", "type": "map",
          "field_config": {
            "map_mode": "place",
            "map_height": 200, "map_corner_radius": 14,
            "map_surface_color": "#111827",
            "map_fallback_text": "Map unavailable",
            "place_lat": 51.5072, "place_lng": -0.1276,
            "place_title": "Our Shoreditch studio",
            "place_subtitle": "Open daily 11-6",
            "place_info_position": "below",
            "place_info_bg": "#0F172A", "place_info_text": "#F9FAFB", "place_info_radius": 8
          }
        }
        """)
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// #595 — a published summary step decoded and composed the way the DEVICE does it: the whole
    /// step JSON through `OnboardingStep` (not a hand-written block through the renderer), then
    /// `ThreeZoneStepLayout`. The reported symptom was a step whose heading, buttons and footnote
    /// all drew but whose summary card stack was simply absent.
    ///
    /// The shape here is copied verbatim from a published `config/onboarding_index/flows/*` doc —
    /// zones, `element_*`, `stats_layout`, the per-stat keys and the stat that carries `input`
    /// without a `field_id`. Only the human-readable strings are replaced; changing any KEY makes
    /// this test stop reproducing what shipped.
    ///
    /// WHAT THE GOLDEN PINS, card by card: the heading and both zoned CTAs land in the right zones;
    /// cards 1, 2 and 4 draw their value and label; and **card 3 draws a STEPPER**. Card 3 is the
    /// stat with an `input` and no `field_id` — it used to render as an empty box on both natives
    /// while the console preview drew the control, which is the preview/device divergence the
    /// reporter photographed. If card 3 goes blank again, `summaryStatFieldId` has been bypassed.
    func testSummaryScreenStepAsPublished() throws {
        let json = """
        {
          "id": "step9",
          "type": "custom",
          "layout": {
            "content_blocks": [
              { "id": "block_1", "text": "Complete your reservation", "type": "heading", "level": 1,
                "style": { "color": "#EAE9E5", "alignment": "center", "font_size": 22, "font_weight": 700 },
                "horizontal_align": "center" },
              { "id": "block_5", "text": "", "type": "summary_screen", "zone": "top",
                "bg_color": "#232F43", "text_color": "#EAE9E5",
                "field_config": {
                  "stats_layout": "vertical",
                  "summary_stats": [
                    { "color": "#EAE9E5", "label": "photo", "value": "Hillside Vineyard Estate" },
                    { "color": "#FFD700", "label": "Old Town - 12 min away", "value": "Today - 4:30 PM" },
                    { "color": "#EAE9E5", "input": "stepper", "label": "", "value": "", "required": "true" },
                    { "color": "#EAE9E5", "label": "Total Due Now: $45", "value": "Tour Price" }
                  ]
                },
                "element_width": "100%", "element_height": "auto",
                "vertical_align": "top", "vertical_offset": 0, "horizontal_align": "center" },
              { "id": "block_2", "text": "Pay with Credit Card", "type": "button", "zone": "bottom",
                "style": { "color": "#000000", "alignment": "center", "font_size": 16, "font_weight": 600 },
                "action": "next", "variant": "primary", "bg_color": "#ffffff", "text_color": "#000000",
                "element_width": "fill", "vertical_align": "bottom", "vertical_offset": 0,
                "horizontal_align": "center", "button_corner_radius": 24 },
              { "id": "block_6", "text": "Confirm Reservation", "type": "button", "zone": "bottom",
                "style": { "color": "#192334", "alignment": "center", "font_size": 16, "font_weight": 600 },
                "action": "link", "variant": "primary", "bg_color": "#FFD700", "text_color": "#192334",
                "element_width": "fill", "vertical_align": "bottom", "vertical_offset": 0,
                "horizontal_align": "center", "button_corner_radius": 24 },
              { "id": "block_3", "text": "Free cancellation up to 24 hours.", "type": "text", "zone": "bottom",
                "style": { "color": "#A0A4A7", "alignment": "center", "font_size": 16, "font_weight": 400 },
                "vertical_align": "bottom", "vertical_offset": 0, "horizontal_align": "center" }
            ]
          }
        }
        """
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        let blocks = step.config.content_blocks ?? []
        XCTAssertEqual(blocks.count, 5, "the step decoder dropped blocks")
        XCTAssertTrue(
            blocks.contains { $0.type == .summary_screen },
            "summary_screen decoded as .unknown — an SDK that does not know a block type renders it as nothing at all, which is exactly the reported symptom"
        )
        let view = ThreeZoneStepLayout(
            blocks: blocks,
            onAction: { _, _ in },
            toggleValues: .constant([:]),
            inputValues: .constant([:])
        )
        .frame(width: 390, height: 844)
        .background(Color(hex: "#141B2B"))
        // NO PIXEL GOLDEN HERE, deliberately, and this is a real reduction in coverage rather than
        // a tidy-up.
        //
        // The golden committed with this test was recorded on the only build machine available,
        // which has iPhone 17 Pro on iOS 26.2 and no other device or runtime installed. CI compares
        // on iPhone 16. The two do not render this card identically — a summary card hosting a
        // stepper is exactly the kind of view whose metrics move between iOS versions — so the
        // golden failed the first CI run it ever saw, and no machine we have can record one that
        // would pass. Keeping it meant a permanently red suite; re-recording it here would just
        // re-pin it to the wrong environment.
        //
        // What still guards #595 is above, and it is the part that actually caught the bug: the
        // step must decode into FIVE blocks and `summary_screen` must not fall through to
        // `.unknown`. The reported symptom was a card stack that rendered as nothing, and
        // `.unknown` rendering as `EmptyView` is precisely how that happened.
        //
        // To restore the pixel check, record on a machine whose simulator matches
        // `.github/workflows/sdk-ci.yml` (iPhone 16), then re-add the assertion below:
        //     withSnapshotTesting(record: recordMode) { assertSnapshot(of: view, as: .image(layout: .sizeThatFits)) }
        _ = view
    }
    func testSelect_imageTiles_contained() throws {
        let view = try render(Self.tilesJSON("""
        "tile_image_layout": "contained", "tile_strip_ratio": 0.7, "tile_surface_color": "#1F2937",
        "tile_image_inset": 10, "tile_image_frame_width": 2, "tile_image_frame_color": "#F59E0B"
        """), inputs: ["tiles_layout": "w1"])
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Image-fill tiles layout — 2×2 grid (image fills the tile, label overlaid over a scrim);
    /// "Lifting" selected with a yellow accent border. Parity with Android.
    func testSelect_imageTiles() throws {
        let view = try render("""
        {
          "id": "tiles1", "type": "input_select",
          "field_config": { "display_style": "image_tiles", "grid_columns": 2 },
          "field_style": { "fill_color": "#FACC15" },
          "field_options": [
            { "id": "run", "value": "run", "label": "Running", "image_url": "https://example.com/a.png", "image_overlay_color": "#E11D48", "image_overlay_opacity": 0.9 },
            { "id": "lift", "value": "lift", "label": "Lifting", "image_url": "https://example.com/b.png", "image_overlay_color": "#2563EB", "image_overlay_opacity": 0.9 },
            { "id": "yoga", "value": "yoga", "label": "Yoga", "image_url": "https://example.com/c.png", "image_overlay_color": "#7C3AED", "image_overlay_opacity": 0.9 },
            { "id": "swim", "value": "swim", "label": "Swimming", "image_url": "https://example.com/d.png", "image_overlay_color": "#059669", "image_overlay_opacity": 0.9 }
          ]
        }
        """, inputs: ["tiles1": "lift"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Bubble/chip layout — wrapping pill chips; "Running" selected (green fill), others bordered. Parity with Android.
    func testSelect_bubbleChips() throws {
        let view = try render("""
        {
          "id": "bubble1", "type": "input_select",
          "field_config": { "display_style": "bubble" },
          "field_style": { "fill_color": "#22C55E", "text_color": "#FFFFFF" },
          "field_options": [
            { "id": "running", "value": "running", "label": "Running" },
            { "id": "yoga", "value": "yoga", "label": "Yoga" },
            { "id": "cycling", "value": "cycling", "label": "Cycling" },
            { "id": "swimming", "value": "swimming", "label": "Swimming" },
            { "id": "boxing", "value": "boxing", "label": "Boxing" },
            { "id": "pilates", "value": "pilates", "label": "Pilates" }
          ]
        }
        """, inputs: ["bubble1": "running"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// List / separators layout — borderless rows + hairline dividers; "Plus" selected (tint + ✓). Parity with Android.
    func testSelect_listSeparators() throws {
        let view = try render("""
        {
          "id": "list1", "type": "input_select",
          "field_config": { "display_style": "list" },
          "field_style": { "fill_color": "#3B82F6", "text_color": "#FFFFFF" },
          "field_options": [
            { "id": "free", "value": "free", "label": "Free", "subtitle": "Basic features" },
            { "id": "plus", "value": "plus", "label": "Plus", "subtitle": "More storage + priority support" },
            { "id": "pro", "value": "pro", "label": "Pro", "subtitle": "Everything, unlimited" },
            { "id": "team", "value": "team", "label": "Team", "subtitle": "For your whole organization" }
          ]
        }
        """, inputs: ["list1": "plus"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Custom field border + fill — input_text (green border) + input_email (blue border), dark fill. Parity with Android.
    func testField_customBorderFill() throws {
        let view = try renderMany([
            """
            { "id": "name", "type": "input_text", "label": "Full name", "field_placeholder": "Jane Doe",
              "field_style": { "border_color": "#22C55E", "background_color": "#1F2937", "text_color": "#FFFFFF", "placeholder_color": "#9CA3AF" } }
            """,
            """
            { "id": "email", "type": "input_email", "label": "Email", "field_placeholder": "jane@example.com",
              "field_style": { "border_color": "#3B82F6", "background_color": "#1F2937", "text_color": "#FFFFFF", "placeholder_color": "#9CA3AF" } }
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// Selection animation glow — "Focused" selected with selection_animation:glow → accent glow halo. Parity with Android.
    func testSelect_selectionGlow() throws {
        let view = try render("""
        {
          "id": "glow1", "type": "input_select",
          "field_config": { "display_style": "stacked", "selection_animation": "glow" },
          "field_style": { "fill_color": "#22C55E" },
          "field_options": [
            { "id": "a", "value": "a", "label": "Calm", "subtitle": "Relaxing pace" },
            { "id": "b", "value": "b", "label": "Focused", "subtitle": "Steady progress" },
            { "id": "c", "value": "c", "label": "Intense", "subtitle": "Push hard" }
          ]
        }
        """, inputs: ["glow1": "b"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-2 — progress bar multi-color gradient fill (~80% filled, green→yellow→red). Parity with Android.
    func testProgress_gradient() throws {
        let view = try render("""
        {
          "id": "pb1", "type": "progress_bar",
          "progress_variant": "continuous", "total_segments": 5, "filled_segments": 4,
          "bar_height": 14, "corner_radius": 7, "track_color": "#374151",
          "bar_gradient_colors": ["#22C55E", "#EAB308", "#EF4444"]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-420 — measurement wheel, ruler style (weight, kg base, 70). Parity with Android.
    func testMeasurement_ruler() throws {
        let view = try render("""
        {
          "id": "mw1", "type": "wheel_picker", "field_id": "weight", "highlight_color": "#6366F1",
          "field_config": {
            "measurement_type": "weight", "measurement_style": "ruler",
            "measurement_default": 70, "unit_default": "kg",
            "units": [
              { "id": "kg", "label": "kg", "min": 30, "max": 200, "step": 0.5, "decimals": 1, "factor": 1, "offset": 0 },
              { "id": "lbs", "label": "lbs", "min": 66, "max": 441, "step": 1, "decimals": 0, "factor": 2.20462, "offset": 0 }
            ]
          }
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-420 — measurement wheel, gauge style (temperature, °C base, 37). Parity with Android.
    func testMeasurement_gauge() throws {
        let view = try render("""
        {
          "id": "mw2", "type": "wheel_picker", "field_id": "temp", "highlight_color": "#6366F1",
          "field_config": {
            "measurement_type": "temperature", "measurement_style": "gauge",
            "measurement_default": 37, "unit_default": "c",
            "units": [
              { "id": "c", "label": "°C", "min": 35, "max": 42, "step": 0.1, "decimals": 1, "factor": 1, "offset": 0 },
              { "id": "f", "label": "°F", "min": 95, "max": 108, "step": 0.1, "decimals": 1, "factor": 1.8, "offset": 32 }
            ]
          }
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-420 — measurement wheel, dial style (height, cm base, 170). Parity with Android.
    func testMeasurement_dial() throws {
        let view = try render("""
        {
          "id": "mw3", "type": "wheel_picker", "field_id": "height", "highlight_color": "#6366F1",
          "field_config": {
            "measurement_type": "height", "measurement_style": "dial",
            "measurement_default": 170, "unit_default": "cm",
            "units": [
              { "id": "cm", "label": "cm", "min": 100, "max": 220, "step": 1, "decimals": 0, "factor": 1, "offset": 0 },
              { "id": "in", "label": "in", "min": 39, "max": 87, "step": 1, "decimals": 0, "factor": 0.393701, "offset": 0 }
            ]
          }
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-420 — measurement wheel, classic flat drum style (weight, kg base, 70). Parity with Android.
    func testMeasurement_wheel() throws {
        let view = try render("""
        {
          "id": "mw4", "type": "wheel_picker", "field_id": "weight", "highlight_color": "#6366F1",
          "field_config": {
            "measurement_type": "weight", "measurement_style": "wheel",
            "measurement_default": 70, "unit_default": "kg",
            "units": [
              { "id": "kg", "label": "kg", "min": 30, "max": 200, "step": 0.5, "decimals": 1, "factor": 1, "offset": 0 },
              { "id": "lbs", "label": "lbs", "min": 66, "max": 441, "step": 1, "decimals": 0, "factor": 2.20462, "offset": 0 }
            ]
          }
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-2 — flow-level progress: thin (2pt) solid + thick (12pt) multi-color gradient. Parity with Android.
    func testProgress_flowThinGradient() throws {
        let view = VStack(spacing: 22) {
            ContinuousProgressBar(progress: 0.6, color: Color(hex: "#6366F1"), trackColor: Color(hex: "#374151"), height: 2)
            ContinuousProgressBar(
                progress: 0.8, color: Color(hex: "#22C55E"), trackColor: Color(hex: "#374151"), height: 12,
                gradientColors: [Color(hex: "#22C55E"), Color(hex: "#EAB308"), Color(hex: "#EF4444")]
            )
        }
        .padding(24)
        .frame(width: 390)
        .background(Color(hex: "#0F1117"))

        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-2 — nav glyphs: custom chevron + default arrow + back⇄X close. Parity with Android.
    func testNav_glyphs() throws {
        let view = VStack(alignment: .leading, spacing: 20) {
            NavGlyph(glyph: "‹", color: Color(hex: "#6366F1"), size: 28)
            NavGlyph(glyph: "←", color: Color(hex: "#E5E7EB"), size: 20)
            NavGlyph(glyph: "✕", color: Color(hex: "#EF4444"), size: 20)
        }
        .padding(24)
        .frame(width: 390, alignment: .leading)
        .background(Color(hex: "#0F1117"))

        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-2 — skip-beside-bar: progress fills the row, "Skip" beside it. Parity with Android.
    func testProgress_skipBeside() throws {
        let view = HStack(spacing: 0) {
            ContinuousProgressBar(progress: 0.5, color: Color(hex: "#6366F1"), trackColor: Color(hex: "#374151"), height: 6)
                .frame(maxWidth: .infinity)
                .padding(.leading, 16)
            Text("Skip")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "#9CA3AF"))
                .padding(.leading, 12)
                .padding(.trailing, 16)
        }
        .frame(width: 390)
        .padding(.vertical, 20)
        .background(Color(hex: "#0F1117"))

        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — phone-mockup frame (image_frame:"phone"): bezel + dynamic-island notch. Parity with Android.
    func testImage_phoneMockup() throws {
        let json = """
        {
          "id": "img1", "type": "image",
          "image_url": "https://example.com/screen.png",
          "image_frame": "phone", "height": 420
        }
        """
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        let view = ContentBlockRendererView(
            blocks: [block],
            onAction: { _, _ in },
            toggleValues: .constant([:]),
            inputValues: .constant([:])
        )
            .padding(40)
            .frame(width: 390)
            .background(Color(hex: "#E5E7EB"))

        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — large radial % ring loading variant (progress_value static). Parity with Android.
    func testLoading_radialRing() throws {
        let view = try render("""
        {
          "id": "ld1", "type": "animated_loading",
          "loading_variant": "ring", "progress_value": 0.65,
          "show_percentage": true, "progress_color": "#6366F1"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — cog/gear spinner loading variant. Parity with Android.
    func testLoading_cogSpinner() throws {
        let view = try render("""
        {
          "id": "ld2", "type": "animated_loading",
          "loading_variant": "cog", "progress_color": "#6366F1"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — splash-bottom spinner (small spinner anchored to the bottom). Parity with Android.
    func testLoading_splashBottom() throws {
        let view = try render("""
        {
          "id": "ld3", "type": "animated_loading",
          "loading_variant": "splash_bottom", "height": 360, "progress_color": "#6366F1"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — loading text styling (message above the ring, custom size/color). Parity with Android.
    func testLoading_textStyling() throws {
        let view = try render("""
        {
          "id": "ld4", "type": "animated_loading",
          "loading_variant": "ring", "progress_value": 0.6,
          "loading_text": "Almost there", "loading_text_position": "above",
          "loading_text_size": 24, "loading_text_color": "#A5B4FC",
          "progress_color": "#6366F1"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-3 — media gallery (horizontal row of image tiles). Parity with Android.
    func testMedia_gallery() throws {
        let view = try render("""
        {
          "id": "mg1", "type": "media_gallery",
          "gallery_images": ["https://example.com/1.jpg", "https://example.com/2.jpg", "https://example.com/3.jpg"],
          "gallery_item_width": 105, "gallery_item_height": 160,
          "gallery_corner_radius": 14, "gallery_spacing": 10
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-4a — side-by-side equal-width buttons via the row block. Parity with Android.
    func testLayout_sideBySide() throws {
        let view = try render("""
        {
          "id": "row1", "type": "row", "row_child_fill": true, "gap": 12,
          "children": [
            {"id": "b1", "type": "button", "text": "Skip", "bg_color": "#2A2A2E", "text_color": "#FFFFFF", "button_corner_radius": 14, "element_width": "fill"},
            {"id": "b2", "type": "button", "text": "Continue", "bg_color": "#6366F1", "text_color": "#FFFFFF", "button_corner_radius": 14, "element_width": "fill"}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-4b — sectioned/zone background with overlaid content. Parity with Android.
    func testLayout_sectionBackground() throws {
        let view = try render("""
        {
          "id": "sec1", "type": "section_background", "height": 420,
          "field_config": {
            "content_arrangement": "space_between",
            "background_zones": [
              {"weight": 2, "color": "#1E1B4B"},
              {"weight": 1, "color": "#6366F1"}
            ]
          },
          "children": [
            {"id": "t1", "type": "text", "text": "Welcome to AppDNA", "style": {"font_size": 26, "font_weight": 700, "color": "#FFFFFF"}},
            {"id": "b1", "type": "button", "text": "Get Started", "bg_color": "#FFFFFF", "text_color": "#1E1B4B", "button_corner_radius": 14, "element_width": "fill"}
          ]
        }
        """, pad: 0)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-1 — multi-column grid select (display_style "grid", grid_columns 2). Parity with Android.
    func testSelect_gridMultiColumn() throws {
        let view = try render("""
        {
          "id": "selg", "type": "input_select",
          "field_config": { "display_style": "grid", "grid_columns": 2 },
          "field_options": [
            {"id": "a", "value": "sleep", "label": "Sleep", "subtitle": "Better rest"},
            {"id": "b", "value": "focus", "label": "Focus", "subtitle": "Deep work"},
            {"id": "c", "value": "calm", "label": "Calm", "subtitle": "Less stress"},
            {"id": "d", "value": "energy", "label": "Energy", "subtitle": "More drive"}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-9 — rich_text markdown (heading, bold, italic, link, bullet list). Parity with Android.
    func testRichText_inlineStyles() throws {
        let view = try render("""
        {
          "id": "rt", "type": "rich_text",
          "markdown_content": "This is **bold**, *italic*, and a [link](https://appdna.ai).",
          "base_style": { "color": "#E5E7EB" },
          "link_color": "#A5B4FC"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-479 (#605) — `++underline++` and a link together.
    ///
    /// `testRichText_inlineStyles` above covers bold/italic/link but NOT the AppDNA-specific `++underline++`
    /// marker, which is applied by `applyUnderlineMarkers` AFTER the native markdown parse. That post-processing
    /// step had no test at all, and #605 reports "linked and underlined Markdown content doesn't render".
    /// This pins both in one render: the link must be coloured and underlined, the `++` markers must be GONE,
    /// and the word between them must be underlined.
    func testRichText_underlineAndLink() throws {
        let view = try render("""
        {
          "id": "rtu", "type": "rich_text",
          "markdown_content": "Plain, ++underlined++, and a [link](https://appdna.ai).",
          "base_style": { "color": "#E5E7EB" },
          "link_color": "#A5B4FC"
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-7 — social login provider buttons (Apple / Google / Email) brand defaults. Parity with Android.
    func testSocial_providers() throws {
        let view = try render("""
        {
          "id": "sl", "type": "social_login",
          "providers": [
            {"type": "google", "label": "Continue with Google"},
            {"type": "email", "label": "Continue with Email"}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// #560 — per-provider label size. The DTO fixture proves the number is DECODED; only a
    /// snapshot proves it is DRAWN, which is the half a decode-only test would let ship broken.
    /// Two providers at different sizes, so the golden fails on a renderer that reads the field
    /// and then ignores it as much as on one that never reads it.
    func testSocial_providerFontSize() throws {
        let view = try render("""
        {
          "id": "sl_size", "type": "social_login",
          "providers": [
            {"type": "google", "label": "Continue with Google", "font_size": 22},
            {"type": "email", "label": "Continue with Email", "font_size": 12}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-8 — swipeable carousel: 3 pages + dot indicator (page 0). Parity with Android.
    func testLayout_carousel() throws {
        let view = try render("""
        {
          "id": "car", "type": "carousel", "height": 120,
          "children": [
            {"id": "p1", "type": "text", "text": "Welcome to AppDNA", "style": {"font_size": 24, "font_weight": 700, "color": "#FFFFFF"}},
            {"id": "p2", "type": "text", "text": "Discover your insights", "style": {"font_size": 24, "font_weight": 700, "color": "#FFFFFF"}},
            {"id": "p3", "type": "text", "text": "Get started today", "style": {"font_size": 24, "font_weight": 700, "color": "#FFFFFF"}}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-10 — pricing plan cards: Monthly + Yearly (highlighted "BEST VALUE"). Parity with Android.
    func testPricing_card() throws {
        let view = try render("""
        {
          "id": "pc", "type": "pricing_card", "active_color": "#6366F1",
          "pricing_plans": [
            {"id": "m", "label": "Monthly", "price": "$9.99", "period": "per month"},
            {"id": "y", "label": "Yearly", "price": "$59.99", "period": "per year", "badge": "BEST VALUE", "is_highlighted": true}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-5 — variables + conditional logic. Heading uses a `{{responses.user_name}}` template (value
    /// carried over from a prior step); two blocks are gated by an age condition — the "verified" block
    /// shows (age 25 > 18), the "too young" block is hidden. Parity with Android.
    func testEpic5_variablesConditional() throws {
        let view = try renderConditional([
            """
            {"id": "h", "type": "heading", "horizontal_align": "center", "text": "Welcome back, {{responses.user_name}}!", "style": {"font_size": 26, "font_weight": 700, "color": "#FFFFFF", "alignment": "center"}}
            """,
            """
            {"id": "ok", "type": "text", "horizontal_align": "center", "text": "✓ Age verified — you're all set", "visibility_condition": {"type": "when_gt", "variable": "responses.age", "value": "18"}, "style": {"font_size": 16, "font_weight": 600, "color": "#34D399", "alignment": "center"}}
            """,
            """
            {"id": "no", "type": "text", "horizontal_align": "center", "text": "✗ You must be 18 or older", "visibility_condition": {"type": "when_lt", "variable": "responses.age", "value": "18"}, "style": {"font_size": 16, "font_weight": 600, "color": "#F87171", "alignment": "center"}}
            """,
        ], responses: ["user_name": "Alex", "age": "25"])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-6 — authored button_height resizes the CTA itself (default ~52 vs tall 72). Parity with Android.
    func testEpic6_buttonHeight() throws {
        let view = try renderMany([
            """
            {"id": "b1", "type": "button", "text": "Continue", "bg_color": "#6366F1"}
            """,
            """
            {"id": "b2", "type": "button", "text": "Get Started", "bg_color": "#10B981", "button_height": 72}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — OTP / code-input: 6 boxes, "1234" entered (4 filled + active 5th + empty 6th). Parity w/ Android.
    func testEpic11_otpInput() throws {
        let view = try render("""
        {"id": "otp", "type": "otp_input", "active_color": "#6366F1", "field_config": {"otp_length": 6, "otp_value": "1234"}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — warning/info banner variants: warning (amber) / error (red) / success (green). Parity w/ Android.
    func testEpic11_warningBanner() throws {
        let view = try renderMany([
            """
            {"id": "w", "type": "warning_banner", "text": "Your session is about to expire", "field_config": {"banner_variant": "warning"}}
            """,
            """
            {"id": "e", "type": "warning_banner", "text": "Passwords do not match", "field_config": {"banner_variant": "error"}}
            """,
            """
            {"id": "s", "type": "warning_banner", "text": "Email verified successfully", "field_config": {"banner_variant": "success"}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-481 (#601) — the warning banner's new authoring surface, all five in one render:
    /// a chosen icon, a subtitle under the message, centre alignment, the banner's own border
    /// width/colour/corner-radius, independent message + subtitle sizes, and a font family.
    ///
    /// `testEpic11_warningBanner` above is the OTHER half of this proof: it is deliberately left
    /// untouched, so if any SPEC-481 default drifted from the pre-SPEC-481 render its committed
    /// reference would stop matching. New capability here, no regression there.
    func testSpec481_warningBannerSubtitleAndChrome() throws {
        let view = try renderMany([
            """
            {"id": "b1", "type": "warning_banner", "text": "Your trial ends soon",
             "field_config": {"banner_variant": "info", "banner_icon": "\u{1F514}",
                              "banner_subtitle": "Renew before Friday to keep your streak.",
                              "banner_text_align": "center", "banner_border_width": 2,
                              "banner_border_color": "#2563EB", "banner_corner_radius": 20,
                              "banner_title_size": 17, "banner_subtitle_size": 12,
                              "banner_font_family": "Georgia"}}
            """,
            """
            {"id": "b2", "type": "warning_banner", "text": "Storage almost full",
             "field_config": {"banner_subtitle": "Free up space to keep syncing.",
                              "banner_text_align": "trailing", "banner_corner_radius": 0,
                              "banner_border_width": 0}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// SPEC-482 (#609) — "no way to arrange 3 buttons 2-then-1 with its own background container".
    ///
    /// There is: a Row is also a COLUMN (`row_direction: "vertical"`) and Rows NEST, so the grid is
    /// an outer vertical Row holding a horizontal Row of two buttons plus a third button, with the
    /// outer Row's `block_style` as the group's background. Nothing in the SDKs or the console
    /// needed to change — the BlockPicker just called it "Horizontal row layout", so an author
    /// hunting for a grid never tried it.
    ///
    /// This test exists because that claim is worthless unless it actually renders. If a future
    /// change breaks nesting or vertical direction, the documented recipe silently stops working.
    func testSpec482_threeButtonGridWithBackground() throws {
        let view = try render("""
        {
          "id": "grp", "type": "row", "row_direction": "vertical", "spacing": 8,
          "block_style": {
            "background_color": "#1F2937", "border_radius": 16,
            "padding_top": 12, "padding_bottom": 12, "padding_left": 12, "padding_right": 12
          },
          "stack_children": [
            {
              "id": "r1", "type": "row", "row_direction": "horizontal", "spacing": 8,
              "stack_children": [
                {"id": "b1", "type": "button", "text": "Skip", "variant": "secondary",
                 "bg_color": "#374151", "text_color": "#F9FAFB", "element_width": "fill"},
                {"id": "b2", "type": "button", "text": "Maybe later", "variant": "secondary",
                 "bg_color": "#374151", "text_color": "#F9FAFB", "element_width": "fill"}
              ]
            },
            {"id": "b3", "type": "button", "text": "Continue", "variant": "primary",
             "bg_color": "#6366F1", "text_color": "#FFFFFF", "element_width": "fill"}
          ]
        }
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — password-strength meter: weak (1/4) / good (3/4) / strong (4/4). Parity with Android.
    func testEpic11_passwordStrength() throws {
        let view = try renderMany([
            """
            {"id": "p1", "type": "password_strength", "field_config": {"strength_level": 1}}
            """,
            """
            {"id": "p2", "type": "password_strength", "field_config": {"strength_level": 3}}
            """,
            """
            {"id": "p3", "type": "password_strength", "field_config": {"strength_level": 4}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — speech bubble (mascot dialogue): white bubble + downward left tail. Parity with Android.
    func testEpic11_speechBubble() throws {
        let view = try render("""
        {"id": "sb", "type": "speech_bubble", "text": "Great job! You're on a 7-day streak 🔥", "bg_color": "#FFFFFF", "text_color": "#111827", "field_config": {"bubble_tail": "left"}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — quiz feedback panel: correct (green ✓) + wrong (red ✗), headline + detail. Parity w/ Android.
    func testEpic11_feedbackPanel() throws {
        let view = try renderMany([
            """
            {"id": "fc", "type": "feedback_panel", "text": "Great job!", "field_config": {"feedback_state": "correct", "feedback_detail": "10-day streak kept 🔥"}}
            """,
            """
            {"id": "fw", "type": "feedback_panel", "text": "Not quite", "field_config": {"feedback_state": "wrong", "feedback_detail": "Correct answer: Tokyo"}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — session summary: headline + 2x2 stat grid (Time / Accuracy / XP / Streak). Parity w/ Android.
    func testEpic11_summaryScreen() throws {
        let view = try render("""
        {"id": "sum", "type": "summary_screen", "text": "Lesson complete!", "field_config": {"summary_stats": [{"value": "5:32", "label": "Time", "color": "#6366F1"}, {"value": "92%", "label": "Accuracy", "color": "#10B981"}, {"value": "+120", "label": "XP earned", "color": "#F59E0B"}, {"value": "7", "label": "Day streak", "color": "#EF4444"}]}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — press-and-hold-to-confirm: pill 65% filled (left→right accent fill behind text). Parity w/ Android.
    func testEpic11_pressHoldConfirm() throws {
        let view = try render("""
        {"id": "ph", "type": "press_hold_confirm", "text": "Hold to confirm", "active_color": "#6366F1", "field_config": {"hold_progress": 0.65}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — Health connect card. Provider is PLATFORM-FIXED: iOS renders Apple Health (Google Fit is
    /// Android-only), so this golden intentionally differs from the Android one. Two states: connect + connected.
    func testEpic11_healthConnect() throws {
        let view = try renderMany([
            """
            {"id": "h1", "type": "health_connect"}
            """,
            """
            {"id": "h2", "type": "health_connect", "field_config": {"connected": true}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — interactive footer: dark-mode capsule toggle (off/on) + language switcher pill. Parity w/ Android.
    func testEpic11_settingsFooter() throws {
        let view = try renderMany([
            """
            {"id": "sf1", "type": "settings_footer", "field_config": {"dark_mode": false, "language": "English"}}
            """,
            """
            {"id": "sf2", "type": "settings_footer", "active_color": "#6366F1", "field_config": {"dark_mode": true, "language": "Español"}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — memory/pair-match: 3-col grid, all 3 states (up 🍎 / down ? / matched 🍌). Parity with Android.
    func testEpic11_memoryMatch() throws {
        let view = try render("""
        {"id": "mm", "type": "memory_match", "active_color": "#6366F1", "field_config": {"match_columns": 3, "match_cards": [{"symbol": "🍎", "state": "up"}, {"state": "down"}, {"symbol": "🍌", "state": "matched"}, {"state": "down"}, {"symbol": "🍎", "state": "up"}, {"symbol": "🍌", "state": "matched"}]}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-11 — month calendar: June 2026, days 12-14 selected (accent), today=15 (ring). Parity with Android.
    func testEpic11_calendarMonth() throws {
        let view = try render("""
        {"id": "cal", "type": "calendar_month", "active_color": "#6366F1", "field_config": {"month_label": "June 2026", "days_in_month": 30, "start_offset": 1, "selected_days": [12, 13, 14], "today": 15}}
        """)
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }

    /// EPIC-9 parity — heading + text centered via STYLE.alignment only (no horizontal_align). Was iOS-left; now centered (matches Android).
    func testEpic9_styleAlignment() throws {
        let view = try renderMany([
            """
            {"id": "h", "type": "heading", "text": "Centered Heading", "style": {"font_size": 24, "font_weight": 700, "color": "#FFFFFF", "alignment": "center"}}
            """,
            """
            {"id": "t", "type": "text", "text": "This body is centered via style.alignment", "style": {"font_size": 15, "color": "#A5B4FC", "alignment": "center"}}
            """,
        ])
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
        }
    }
}
