// WidgetActionRenderTests.swift
//
// The `add_widget` button OPERATED in a real key window (`HostedStep`):
//   - the step channel reaches a Multi-buttons child and a Row child, an id-less child included, and
//     hands over the decoded block with its how-to;
//   - with no channel (a Screen, a sheet) the button takes the ordinary action path;
//   - through the real `OnboardingStepRouter`: a tap presents the how-to, Done advances with
//     `widget_status`, a return with a new widget advances `added`, and a refused gate presents nothing;
//   - the how-to sheet (`BlockSheetView`) draws its authored blocks with the step's localisation (its
//     Done / Close / link routing is `WidgetAddAttemptTests.testTheSheetIgnoresALinkButton`; the taps
//     themselves are operated on the simulator by `AddWidgetWalkUITests`).
//
// The widget platform is faked through `WidgetAddAttempt.platformForTesting`; everything else is
// production code. Every block and widget is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/// Hosts blocks with a recording channel (or none).
private struct ChannelHost: View {
    let blocks: [ContentBlock]
    let channel: WidgetActionChannel?
    let onAction: (String, String?) -> Void
    @State private var toggles: [String: Bool] = [:]
    @State private var inputs: [String: Any] = [:]

    var body: some View {
        ContentBlockRendererView(blocks: blocks, onAction: onAction, toggleValues: $toggles, inputValues: $inputs)
            .environment(\.appdnaWidgetAction, channel)
    }
}

@MainActor
final class WidgetActionRenderTests: XCTestCase {

    override func tearDown() {
        WidgetAddAttempt.platformForTesting = nil
        OnboardingPressedButton.shared.clear()
        super.tearDown()
    }

    private func blocks(_ json: String) throws -> [ContentBlock] {
        try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
    }

    private static let howto = #"[{"id":"h_head","type":"heading","text":"Add the widget"},{"id":"h_done","type":"button","text":"Done","action":"next"},{"id":"h_close","type":"button","text":"Close","action":"dismiss","variant":"text"}]"#

    // MARK: - The channel reaches nested buttons

    /// A Multi-buttons child, a Row child and an id-less Row child each hand the channel their own
    /// decoded block, how-to included; none takes the action path.
    /// RED CONTROL: the renderer's `add_widget` branch removed — every tap goes to `onAction` instead.
    func testTheChannelReachesMultiButtonsAndRowChildren() throws {
        let list = try blocks(#"""
        [{"id":"mb","type":"multi_buttons","children":[
            {"id":"mb_other","type":"button","text":"Other","action":"next"},
            {"id":"mb_widget","type":"button","text":"Widget from group","action":"add_widget","howto_blocks_ios":\#(Self.howto)}]},
         {"id":"row","type":"row","children":[
            {"id":"row_widget","type":"button","text":"Widget from row","action":"add_widget","howto_blocks_ios":\#(Self.howto)},
            {"type":"button","text":"Widget without id","action":"add_widget","howto_blocks_ios":\#(Self.howto)}]}]
        """#)
        var tapped: [ContentBlock] = []
        var actions: [String] = []
        let hosted = HostedStep(ChannelHost(blocks: list, channel: WidgetActionChannel { tapped.append($0) },
                                            onAction: { a, _ in actions.append(a) }))
        defer { hosted.close() }

        hosted.tap("multi-buttons child") { $0 == "Widget from group" }
        hosted.tap("row child") { $0 == "Widget from row" }
        hosted.tap("id-less row child") { $0 == "Widget without id" }

        XCTAssertEqual(actions, [], "no add_widget tap took the action path")
        XCTAssertEqual(tapped.count, 3)
        XCTAssertEqual(tapped.prefix(2).map(\.id), ["mb_widget", "row_widget"])
        XCTAssertFalse(tapped.last?.id.isEmpty ?? true, "the id-less child carries its decoder id")
        for block in tapped {
            XCTAssertEqual(block.howto_blocks_ios?.map(\.id), ["h_head", "h_done", "h_close"], "the block's own how-to")
        }
    }

    /// No channel (Screens / SDUI, every sheet): the button takes today's path, `onAction("add_widget")`
    /// — which the step's default arm advances with the answers kept.
    /// RED CONTROL: a renderer that swallowed `add_widget` with no channel calls nothing.
    func testWithNoChannelTheButtonTakesTheActionPath() throws {
        let list = try blocks(#"[{"id":"w","type":"button","text":"Add widget","action":"add_widget","action_value":"SampleProvider"}]"#)
        var actions: [(String, String?)] = []
        let hosted = HostedStep(ChannelHost(blocks: list, channel: nil, onAction: { actions.append(($0, $1)) }))
        defer { hosted.close() }
        hosted.tap("add widget") { $0 == "Add widget" }
        XCTAssertEqual(actions.map(\.0), ["add_widget"])
        XCTAssertEqual(actions.first?.1, "SampleProvider")
    }

    // MARK: - Through the step router

    private struct Routed {
        let hosted: HostedStep
        let source: ImmediateWidgetSource
        let events: WidgetBox<[String]>
        let payloads: WidgetBox<[[String: Any]?]>
    }

    private func route(_ blocksJSON: String, hasExtension: Bool = true,
                       placed: Set<WidgetInstance> = [WidgetAddAttemptTests.small]) throws -> Routed {
        let source = ImmediateWidgetSource(placed)
        WidgetAddAttempt.platformForTesting = .init(hasWidgetExtension: { hasExtension }, configurations: source)
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            #"{"id":"widget_step","type":"custom","config":{"content_blocks":\#(blocksJSON)}}"#.utf8))
        let events = WidgetBox<[String]>([])
        let payloads = WidgetBox<[[String: Any]?]>([])
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "fx.widget.\(UUID())")))
        tracker.eventSink = { events.value.append($0.event_name) }
        let router = OnboardingStepRouter(step: step, onNext: { payloads.value.append($0) }, onSkip: {},
                                          flowId: "flow_w", eventTracker: tracker)
        return Routed(hosted: HostedStep(router), source: source, events: events, payloads: payloads)
    }

    /// The how-to the router presented, read off the presented controller (a package test never
    /// installs a presented view in a window, so the view value is read rather than its pixels).
    private func presentedHowto(_ hosted: HostedStep) -> BlockSheetView? {
        guard let vc = hosted.host.presentedViewController else { return nil }
        func find(_ value: Any, _ depth: Int) -> BlockSheetView? {
            if let sheet = value as? BlockSheetView { return sheet }
            guard depth < 50 else { return nil }
            for child in Mirror(reflecting: value).children {
                if let f = find(child.value, depth + 1) { return f }
            }
            return nil
        }
        if let any = vc as? UIHostingController<AnyView>, let f = find(any.rootView, 0) { return f }
        return find(vc, 0)
    }

    private static let bottomButton = #"{"id":"cta_w","type":"button","text":"Add the widget","action":"add_widget","zone":"bottom","howto_blocks_ios":\#(howto)}"#

    /// Tap → the how-to over the step (its authored blocks) → Done with no new widget → ONE advance
    /// carrying `widget_status: unknown` (a widget of the app was already placed at the tap).
    /// RED CONTROL: the router without `.environment(\.appdnaWidgetAction, …)` — the tap advances at
    /// once through the default arm and nothing is presented.
    func testRouterTapPresentsTheHowtoAndDoneAdvancesUnknown() throws {
        let r = try route("[\(Self.bottomButton)]")
        defer { r.hosted.close() }
        r.hosted.tap("add_widget button") { $0 == "Add the widget" }
        XCTAssertTrue(r.hosted.wait { self.presentedHowto(r.hosted) != nil }, "the how-to is presented")
        let sheet = try XCTUnwrap(presentedHowto(r.hosted))
        XCTAssertEqual(sheet.blocks.map(\.id), ["h_head", "h_done", "h_close"])
        XCTAssertEqual(r.events.value, ["widget_add_tapped", "widget_howto_shown"])
        XCTAssertEqual(r.payloads.value.count, 0, "nothing advances while the how-to is up")

        sheet.handle("next")
        XCTAssertTrue(r.hosted.wait { r.payloads.value.count == 1 })
        XCTAssertEqual(r.payloads.value.first??[WidgetStatus.answerKey] as? String, "unknown")
        XCTAssertEqual(r.events.value, ["widget_add_tapped", "widget_howto_shown", "widget_add_unknown", "widget_howto_dismissed"])
    }

    /// The user adds the widget with the how-to open and comes back: the router's didBecomeActive
    /// observer re-reads, sees the new id, closes the how-to and advances `added`.
    /// RED CONTROL: the router without its `didBecomeActiveNotification` observer — no advance.
    func testRouterReturnWithANewWidgetAdvancesAdded() throws {
        let r = try route("[\(Self.bottomButton)]")
        defer { r.hosted.close() }
        r.hosted.tap("add_widget button") { $0 == "Add the widget" }
        XCTAssertTrue(r.hosted.wait { self.presentedHowto(r.hosted) != nil })
        r.source.current = [WidgetAddAttemptTests.small, WidgetAddAttemptTests.medium]
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(r.hosted.wait { r.payloads.value.count == 1 }, "detected on return")
        XCTAssertEqual(r.payloads.value.first??[WidgetStatus.answerKey] as? String, "added")
        XCTAssertEqual(r.events.value, ["widget_add_tapped", "widget_howto_shown", "widget_howto_dismissed", "widget_added"])
    }

    /// A required field left empty: the tap shows the validation toast and starts nothing — no read,
    /// no event, no how-to, no advance.
    /// RED CONTROL: the router's `gate` hook returning true — the how-to is presented.
    func testRouterGateRefusedPresentsNothing() throws {
        let r = try route(#"[{"id":"nick","type":"input_text","field_id":"nickname","field_label":"Nickname","field_required":true,"zone":"bottom"},\#(Self.bottomButton)]"#)
        defer { r.hosted.close() }
        r.hosted.tap("add_widget button") { $0 == "Add the widget" }
        r.hosted.spin(0.3)
        XCTAssertNil(presentedHowto(r.hosted))
        XCTAssertEqual(r.events.value, [])
        XCTAssertEqual(r.source.reads, 0)
        XCTAssertEqual(r.payloads.value.count, 0)
        XCTAssertTrue(r.hosted.wait { r.hosted.labels().contains { $0.hasPrefix("Please fill in") } }, "the validation toast")
    }

    /// No WidgetKit extension: advance at once with `unavailable`, no how-to.
    func testRouterWithNoExtensionAdvancesUnavailable() throws {
        let r = try route("[\(Self.bottomButton)]", hasExtension: false)
        defer { r.hosted.close() }
        r.hosted.tap("add_widget button") { $0 == "Add the widget" }
        XCTAssertTrue(r.hosted.wait { r.payloads.value.count == 1 })
        XCTAssertEqual(r.payloads.value.first??[WidgetStatus.answerKey] as? String, "unavailable")
        XCTAssertNil(presentedHowto(r.hosted))
        XCTAssertEqual(r.events.value, ["widget_add_unavailable"])
    }

    /// The same action on a Multi-buttons child, through the router.
    func testRouterMultiButtonsChildPresentsItsHowto() throws {
        let r = try route(#"[{"id":"mb","type":"multi_buttons","zone":"bottom","children":[{"id":"mb_w","type":"button","text":"Widget child","action":"add_widget","howto_blocks_ios":\#(Self.howto)}]}]"#)
        defer { r.hosted.close() }
        r.hosted.tap("multi-buttons child") { $0 == "Widget child" }
        XCTAssertTrue(r.hosted.wait { self.presentedHowto(r.hosted) != nil })
        XCTAssertEqual(presentedHowto(r.hosted)?.blocks.map(\.id), ["h_head", "h_done", "h_close"])
    }

    // MARK: - The how-to sheet itself

    /// The sheet's pixels, `layer.render(in:)` into a known RGBA bitmap (`drawHierarchy` reads SwiftUI
    /// back blank in a package test, and a ScrollView's content is not published to the accessibility
    /// tree there either — so the render is compared, one variable changed at a time).
    private func pixels(_ view: BlockSheetView) -> [UInt8] {
        let hosted = HostedStep(view)
        defer { hosted.close() }
        hosted.spin(0.3)
        let v = hosted.host.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: v.bounds.size, format: format).image { v.layer.render(in: $0.cgContext) }
        guard let cg = image.cgImage else { XCTFail("no pixels"); return [] }
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return px
    }

    private static func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] { n += 1 }
        return n
    }

    /// The how-to DRAWS its authored blocks, through the step's localisation: the same sheet with no
    /// blocks draws differently (the blocks are drawn), the same blocks rendered twice draw the same
    /// (THE CONTROL: the harness is deterministic), and a translation of the heading changes the
    /// picture (the step's `loc` reaches the sheet).
    /// RED CONTROL: `BlockSheetView` passing `loc: nil` to its renderer — the translated render equals
    /// the untranslated one.
    func testTheHowtoDrawsItsBlocksThroughTheStepLocalisation() throws {
        let list = try blocks(#"""
        [{"id":"h_head","type":"heading","text":"Add the widget"},
         {"id":"h_body","type":"text","text":"Touch and hold the Home Screen"},
         {"id":"h_done","type":"button","text":"Done","action":"next"},
         {"id":"h_close","type":"button","text":"Close","action":"dismiss","variant":"text"}]
        """#)
        let plain: (String, String) -> String = { _, fallback in fallback }
        let german: (String, String) -> String = { key, fallback in key == "block.h_head.text" ? "Widget hinzufügen jetzt" : fallback }
        let empty = pixels(BlockSheetView(blocks: [], loc: plain, onDone: {}, onClose: {}))
        let drawn = pixels(BlockSheetView(blocks: list, loc: plain, onDone: {}, onClose: {}))
        let again = pixels(BlockSheetView(blocks: list, loc: plain, onDone: {}, onClose: {}))
        let translated = pixels(BlockSheetView(blocks: list, loc: german, onDone: {}, onClose: {}))
        XCTAssertEqual(Self.differing(drawn, again), 0, "the control: one render twice is the same picture")
        XCTAssertGreaterThan(Self.differing(empty, drawn), 2000, "the authored blocks are drawn")
        XCTAssertGreaterThan(Self.differing(drawn, translated), 200, "the step's translation of the heading is drawn")
    }
}
