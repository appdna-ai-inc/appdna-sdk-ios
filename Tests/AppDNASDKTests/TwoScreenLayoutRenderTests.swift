// TwoScreenLayoutRenderTests.swift
//
// Onboarding, a paywall, an in-app message and a survey, each rendered by the REAL renderer in a
// real key window at the two sizes of a two-screen (folding) phone, in portrait and landscape, and
// then resized from one to the other while the surface is open — which is how a fold or an unfold
// reaches an app: the same scene is resized and its size classes change. Nothing is torn down.
//
// Geometries (logical points; the device's point sizes are not published, so these are the App
// Store screenshot sizes at @3x, and the trailing inset stands in for the status bar and camera
// that sit on the side of the outer display):
//
//     outer portrait    466 × 678   compact × regular   trailing inset 40
//     outer landscape   678 × 466   compact × compact   trailing inset 40
//     inner portrait    669 × 951   regular × regular
//     inner landscape   951 × 669   regular × regular   trailing inset 40
//
// What is asserted, read off the accessibility tree (frames in window points):
//
//   - the content column is `min(usable width, 560)` and centred in the usable width, so the CTA,
//     the copy and the buttons stop stretching edge to edge on the wide display — and, at a phone
//     width, are exactly as wide as they always were;
//   - on the inner display in landscape (regular, at least 720 wide, wider than tall) a surface with
//     something for each pane SPLITS: a container `min(width, 1040)`, two equal panes, the hero or
//     the pitch in the leading one, the copy, inputs, plans and CTA in the trailing one; a surface
//     with nothing to put beside its content stays a column there;
//   - the CTA is inside the window and clear of the trailing inset;
//   - a resize keeps an answer, a selected plan, a survey score and a scroll position. Each
//     carries a negative control: the same host rebuilt from scratch loses it.
//
// The expected column is computed here from the rule, not by calling `SurfaceColumn`, so this file
// fails against a renderer that has no column at all. All content is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class TwoScreenLayoutRenderTests: XCTestCase {

    // MARK: - Geometry

    struct Geometry {
        let name: String
        let size: CGSize
        let horizontal: UIUserInterfaceSizeClass
        let vertical: UIUserInterfaceSizeClass
        let trailingInset: CGFloat

        var usableWidth: CGFloat { size.width - trailingInset }
        /// The rule under test: the column is the usable width, capped at 560.
        var column: CGFloat { min(usableWidth, 560) }
        var columnMinX: CGFloat { (usableWidth - column) / 2 }
        var columnMaxX: CGFloat { columnMinX + column }
        /// The onboarding step's side inset, a fraction of the column.
        var stepInset: CGFloat { max(24, column * 0.08) }

        /// The rule under test for the split: regular width, at least 720, wider than tall.
        var splitAllowed: Bool { horizontal == .regular && usableWidth >= 720 && usableWidth > size.height }
        var splitContainer: CGFloat { min(usableWidth, 1040) }

        /// The pane the main content (copy, inputs, plans, CTA) is in.
        func mainPane(splits: Bool) -> Pane {
            guard splits && splitAllowed else { return Pane(minX: columnMinX, width: column) }
            let left = (usableWidth - splitContainer) / 2
            return Pane(minX: left + splitContainer / 2, width: splitContainer / 2)
        }

        /// The leading pane of a split.
        var leadPane: Pane {
            Pane(minX: (usableWidth - splitContainer) / 2, width: splitContainer / 2)
        }
    }

    struct Pane {
        let minX: CGFloat
        let width: CGFloat
        var maxX: CGFloat { minX + width }
        var midX: CGFloat { minX + width / 2 }
        var stepInset: CGFloat { max(24, width * 0.08) }
    }

    static let outerPortrait = Geometry(name: "outer portrait", size: CGSize(width: 466, height: 678), horizontal: .compact, vertical: .regular, trailingInset: 40)
    static let outerLandscape = Geometry(name: "outer landscape", size: CGSize(width: 678, height: 466), horizontal: .compact, vertical: .compact, trailingInset: 40)
    static let innerPortrait = Geometry(name: "inner portrait", size: CGSize(width: 669, height: 951), horizontal: .regular, vertical: .regular, trailingInset: 0)
    static let innerLandscape = Geometry(name: "inner landscape", size: CGSize(width: 951, height: 669), horizontal: .regular, vertical: .regular, trailingInset: 40)
    /// A current phone, the control: the column is the whole width, so nothing may have moved.
    static let phone = Geometry(name: "phone", size: CGSize(width: 393, height: 852), horizontal: .compact, vertical: .regular, trailingInset: 0)

    static let all = [outerPortrait, outerLandscape, innerPortrait, innerLandscape]

    // MARK: - Host

    @MainActor
    final class Host {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        private(set) var geometry: Geometry

        init(_ view: AnyView, _ g: Geometry) {
            _ = A11yAutomation.enabled
            host = UIHostingController(rootView: view)
            window = UIWindow(frame: CGRect(origin: .zero, size: g.size))
            geometry = g
            window.rootViewController = host
            window.makeKeyAndVisible()
            apply(g)
        }

        /// A fold or an unfold: the same window resized, its size classes and side inset changed.
        func apply(_ g: Geometry) {
            geometry = g
            window.frame = CGRect(origin: .zero, size: g.size)
            if #available(iOS 17.0, *) {
                host.traitOverrides.horizontalSizeClass = g.horizontal
                host.traitOverrides.verticalSizeClass = g.vertical
            }
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: g.trailingInset)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spin(0.6)
            settle()
        }

        /// Waits until two reads of the published tree, 50 ms apart, put every labelled element in the same place —
        /// so a render read on a loaded machine, where the tree publishes late, is the settled layout and not one
        /// caught on the way to it. Capped at 2 s; the assertions judge whatever the last read was.
        func settle() {
            func layout() -> [String] {
                elements().compactMap { e in e.accessibilityLabel.map { "\($0)@\(frame(e).integral)" } }
            }
            var last = layout()
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                spin(0.05)
                let now = layout()
                if now == last && !now.isEmpty { return }
                last = now
            }
        }

        func close() { window.isHidden = true }

        func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

        func elements() -> [NSObject] {
            // Through `A11yTree`, which recovers the tree when another process turns automation off.
            A11yTree.read([host.view] + [host.presentedViewController?.view].compactMap { $0 })
        }

        func labels() -> [String] { elements().compactMap(\.accessibilityLabel) }

        func button(_ label: String) -> NSObject? {
            elements().first { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
        }

        func element(containing text: String) -> NSObject? {
            elements().first { ($0.accessibilityLabel ?? "").contains(text) }
        }

        /// The frame of `e` in this window's points.
        func frame(_ e: NSObject) -> CGRect {
            if let v = e as? UIView { return v.convert(v.bounds, to: window) }
            return window.convert(e.accessibilityFrame, from: nil)
        }

        @discardableResult
        func tap(_ e: NSObject?) -> Bool {
            guard let e else { return false }
            let ok = e.accessibilityActivate()
            spin(0.4)
            return ok
        }

        func textField() -> UITextField? {
            func find(_ v: UIView) -> UITextField? {
                if let tf = v as? UITextField { return tf }
                for s in v.subviews { if let f = find(s) { return f } }
                return nil
            }
            return find(host.view)
        }

        /// Types as a keystroke does (see `RotationKeepsTypedTextTests`).
        func type(_ text: String) {
            guard let tf = textField() else { return XCTFail("no text field") }
            _ = tf.becomeFirstResponder()
            tf.text = text
            for target in tf.allTargets {
                for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                    _ = (target as NSObject).perform(Selector(action), with: tf)
                }
            }
            tf.delegate?.textFieldDidChangeSelection?(tf)
            NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: tf)
            spin(0.3)
        }

        /// The bounding box, in window points, of the pixels within `tolerance` of `hex` in a render
        /// of the hosted view (`layer.render`, the path `SurfaceSnapshotTests` found draws scroll
        /// content), optionally only below `minY`.
        func colourBox(_ hex: String, minY: CGFloat = 0, tolerance: Int = 10) -> CGRect? {
            let size = window.bounds.size
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in host.view.layer.render(in: ctx.cgContext) }
            guard let cg = image.cgImage, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            let want = (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
            let w = cg.width, hgt = cg.height
            var px = [UInt8](repeating: 0, count: w * hgt * 4)
            guard let ctx = CGContext(data: &px, width: w, height: hgt, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hgt))
            var minX = Int.max, maxX = -1, minYp = Int.max, maxY = -1
            for y in 0..<hgt where CGFloat(y) >= minY {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if abs(Int(px[i]) - want.0) <= tolerance, abs(Int(px[i + 1]) - want.1) <= tolerance, abs(Int(px[i + 2]) - want.2) <= tolerance {
                        minX = min(minX, x); maxX = max(maxX, x); minYp = min(minYp, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: minX, y: minYp, width: maxX - minX + 1, height: maxY - minYp + 1)
        }

        func scrollView() -> UIScrollView? {
            func find(_ v: UIView) -> UIScrollView? {
                if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height + 1 { return s }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            return find(host.view)
        }
    }

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    // MARK: - Surfaces (synthetic)

    private func onboardingFlow(fillerBlocks: Int = 0, hero: Bool = false) throws -> OnboardingFlowConfig {
        let filler = (0..<fillerBlocks).map { i in
            #"{"id":"t\#(i)","type":"text","text":"Line \#(i) of a long synthetic step that has to scroll."}"#
        }.joined(separator: ",")
        let blocks = [
            hero ? ##"{"id":"hero","type":"image","image_url":"https://example.invalid/hero.png","element_height":"120","block_style":{"background_color":"#FF00FF"}}"## : "",
            #"{"id":"h","type":"heading","text":"A synthetic question"}"#,
            #"{"id":"name","type":"input_text","field_id":"name","field_label":"Name"}"#,
            #"{"id":"sel","type":"input_select","field_id":"goal","field_options":[{"id":"o_one","value":"one","label":"Option one"},{"id":"o_two","value":"two","label":"Option two"}]}"#,
            filler,
            #"{"id":"go","type":"button","text":"Continue","action":"next","zone":"bottom"}"#,
        ].filter { !$0.isEmpty }.joined(separator: ",")
        let json = #"{"id":"duo_probe","name":"Two-screen probe","version":1,"steps":[{"id":"s_q","type":"custom","config":{"content_blocks":["#
            + blocks + #"]}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    private func onboarding(_ flow: OnboardingFlowConfig, completed: @escaping ([String: Any]?) -> Void = { _ in }) -> AnyView {
        AnyView(OnboardingFlowHost(
            flow: flow,
            delegate: nil,
            eventTracker: nil,
            onStepViewed: { _, _ in },
            onStepCompleted: { _, _, data in completed(data) },
            onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in },
            onFlowDismissed: { _, _ in }
        ))
    }

    /// `pinnedPlans`: the plans section in the bottom zone, the shape the generator writes, where the
    /// plan rows sit outside the scroll (and so are reachable through the accessibility tree).
    private func paywall(pinnedPlans: Bool = false) throws -> AnyView {
        let zone = pinnedPlans ? #""zone": "bottom", "# : ""
        let json = """
        {
          "id": "duo_paywall",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Choose a plan" } },
              { "id": "plans", \(zone)"type": "plans", "config": { "plan_display_style": "vertical_stack", "plans": [
                  { "product_id": "plan_alpha", "label": "Alpha", "price_display": "$1.11", "is_default": true, "cta_text": "Start Alpha" },
                  { "product_id": "plan_bravo", "label": "Bravo", "price_display": "$2.22", "is_default": false, "cta_text": "Start Bravo" }
              ] } }
            ]
          },
          "cta": { "text": "Continue", "bg_color": "#FF00FF" }
        }
        """
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        return AnyView(PaywallRenderer(config: config, onPlanSelected: { _, _ in }, onRestore: {}, onDismiss: { _ in }))
    }

    private func message(_ type: String, hero: Bool = false) throws -> AnyView {
        let image = hero ? #","image_url":"https://example.invalid/hero.png""# : ""
        let json = ##"{"name":"m","message_type":"\##(type)","content":{"title":"A synthetic message","body":"Two short lines of synthetic copy.","cta_text":"Got it","background_color":"#FFFFFF"\##(image)}}"##
        let config = try JSONDecoder().decode(MessageConfig.self, from: Data(json.utf8))
        return AnyView(MessageRenderer(messageId: "m", config: config, onCTATap: {}, onDismiss: {}))
    }

    private func survey(completion: @escaping (SurveyResult) -> Void = { _ in }) throws -> AnyView {
        let json = #"{"id":"s","name":"s","survey_type":"nps","questions":[{"id":"q1","type":"nps","text":"How likely?","required":true},{"id":"q2","type":"nps","text":"And now?","required":true}],"appearance":{"presentation":"fullscreen"}}"#
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(json.utf8))
        return AnyView(SurveyContainerView(config: config, completion: completion))
    }

    // MARK: - Column assertions

    /// `e` is a full-column-width control: as wide as the column minus `sideInset` each side, and
    /// centred in the usable width.
    /// `e` spans `pane` less `sideInset` each side, centred in it.
    private func assertSpans(_ e: NSObject?, _ pane: Pane, in h: Host, sideInset: CGFloat, _ what: String, tolerance: CGFloat = 3) {
        let g = h.geometry
        guard let e else { return XCTFail("[\(g.name)] \(what): not found; labels: \(h.labels())") }
        let f = h.frame(e)
        XCTAssertEqual(f.width, pane.width - 2 * sideInset, accuracy: tolerance, "[\(g.name)] \(what) width: its pane (\(pane.width)) less its inset")
        XCTAssertEqual(f.midX, pane.midX, accuracy: tolerance, "[\(g.name)] \(what) is centred in its pane")
        assertOnScreen(f, g, what)
    }

    private func assertSpansColumn(_ e: NSObject?, in h: Host, sideInset: CGFloat, _ what: String, tolerance: CGFloat = 3) {
        assertSpans(e, h.geometry.mainPane(splits: false), in: h, sideInset: sideInset, what, tolerance: tolerance)
    }

    private func assertInside(_ e: NSObject?, _ pane: Pane, in h: Host, _ what: String) {
        let g = h.geometry
        guard let e else { return XCTFail("[\(g.name)] \(what): not found; labels: \(h.labels())") }
        let f = h.frame(e)
        XCTAssertGreaterThanOrEqual(f.minX, pane.minX - 0.5, "[\(g.name)] \(what) \(f) starts inside its pane \(pane.minX)…\(pane.maxX)")
        XCTAssertLessThanOrEqual(f.maxX, pane.maxX + 0.5, "[\(g.name)] \(what) \(f) ends inside its pane \(pane.minX)…\(pane.maxX)")
        assertOnScreen(f, g, what)
    }

    private func assertInsideColumn(_ e: NSObject?, in h: Host, _ what: String) {
        assertInside(e, h.geometry.mainPane(splits: false), in: h, what)
    }

    private func assertOnScreen(_ f: CGRect, _ g: Geometry, _ what: String) {
        XCTAssertGreaterThanOrEqual(f.minX, -0.5, "[\(g.name)] \(what) is not clipped on the leading edge")
        XCTAssertLessThanOrEqual(f.maxX, g.usableWidth + 0.5, "[\(g.name)] \(what) stays clear of the trailing inset")
        XCTAssertGreaterThanOrEqual(f.minY, -0.5, "[\(g.name)] \(what) is not above the window")
        XCTAssertLessThanOrEqual(f.maxY, g.size.height + 0.5, "[\(g.name)] \(what) is not below the window (a clipped CTA)")
    }

    // MARK: - Onboarding

    func testOnboardingLaysOutInTheColumnAtEverySize() throws {
        let flow = try onboardingFlow()
        // Control: a phone. The column is the whole width, so the CTA is exactly as wide as it was.
        for g in [Self.phone] + Self.all {
            let h = Host(onboarding(flow), g)
            defer { h.close() }
            let column = g.mainPane(splits: false)
            assertSpans(h.button("Continue"), column, in: h, sideInset: column.stepInset, "pinned CTA")
            assertInside(h.textField(), column, in: h, "the text input")
        }
    }

    /// A step with a hero splits on the inner display in landscape: the hero (a magenta box) in the
    /// leading pane; the input and the pinned CTA in the trailing one. Everywhere else it is the
    /// column, the hero above the input.
    func testAnOnboardingStepWithAHeroSplitsOnlyWhereTheWindowAllowsIt() throws {
        let flow = try onboardingFlow(hero: true)
        for g in [Self.phone] + Self.all {
            let h = Host(onboarding(flow), g)
            defer { h.close() }
            XCTAssertEqual(g.splitAllowed, g.name == "inner landscape", "control: only the inner landscape geometry allows a split")
            let main = g.mainPane(splits: true)
            assertSpans(h.button("Continue"), main, in: h, sideInset: main.stepInset, "pinned CTA")
            assertInside(h.textField(), main, in: h, "the text input")
            guard let hero = h.colourBox("#FF00FF") else { XCTFail("[\(g.name)] the hero box was not drawn"); continue }
            let input = h.textField().map(h.frame) ?? .zero
            if g.splitAllowed {
                XCTAssertGreaterThanOrEqual(hero.minX, g.leadPane.minX - 1, "[\(g.name)] the hero \(hero) is in the leading pane")
                XCTAssertLessThanOrEqual(hero.maxX, g.leadPane.maxX + 1, "[\(g.name)] the hero \(hero) is in the leading pane")
                XCTAssertLessThan(hero.maxX, input.minX, "[\(g.name)] the hero is BESIDE the input")
            } else {
                XCTAssertGreaterThanOrEqual(hero.minX, g.columnMinX - 1, "[\(g.name)] the hero \(hero) is in the column")
                XCTAssertLessThanOrEqual(hero.maxX, g.columnMaxX + 1, "[\(g.name)] the hero \(hero) is in the column")
                XCTAssertLessThanOrEqual(hero.maxY, input.minY + 1, "[\(g.name)] the hero is ABOVE the input")
            }
        }
    }

    /// The column is drawn at its width from the first frame it is measured in: a CTA sampled every 20 ms from the
    /// moment the window is shown is never anything but its column width. Before, the first measurement landed in an
    /// animated transaction and the CTA shrank from the window's width (605) to the column's (470) over about half a
    /// second, so a read that came early on a loaded machine measured something in between.
    func testTheColumnIsItsWidthFromTheFirstMeasuredFrameNotAnimatedTo() throws {
        let flow = try onboardingFlow(hero: true)
        let g = Self.innerPortrait
        _ = A11yAutomation.enabled
        let host = UIHostingController(rootView: onboarding(flow))
        let window = UIWindow(frame: CGRect(origin: .zero, size: g.size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        if #available(iOS 17.0, *) {
            host.traitOverrides.horizontalSizeClass = g.horizontal
            host.traitOverrides.verticalSizeClass = g.vertical
        }
        host.view.layoutIfNeeded()
        let main = g.mainPane(splits: true)
        let expected = main.width - 2 * main.stepInset
        var widths: [CGFloat] = []
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            A11yAutomation.ensure()
            let cta = A11yTree.raw([host.view]).first { $0.accessibilityLabel == "Continue" && $0.accessibilityTraits.contains(.button) }
            if let cta { widths.append(window.convert(cta.accessibilityFrame, from: nil).width) }
        }
        XCTAssertFalse(widths.isEmpty, "control: the CTA was read at all\(A11yTree.diagnosis(A11yTree.raw([host.view]), roots: [host.view]))")
        let off = widths.filter { abs($0 - expected) > 1 }
        XCTAssertTrue(off.isEmpty, "the CTA is \(expected) wide in every frame once it is drawn; \(off.count) of \(widths.count) reads were not: \(off.prefix(8).map { String(format: "%.1f", $0) })")
    }

    /// A fold and an unfold, with an answer typed: the answer is still the step's when it is
    /// continued, after every size the device can take — into two panes and back.
    func testAFoldAndUnfoldKeepAnOnboardingAnswer() throws {
        let flow = try onboardingFlow(hero: true)
        var completed: [[String: Any]?] = []
        let h = Host(onboarding(flow, completed: { completed.append($0) }), Self.outerPortrait)
        defer { h.close() }

        h.type("Ada Lovelace")
        let field = h.textField()
        for g in [Self.innerPortrait, Self.innerLandscape, Self.outerLandscape, Self.outerPortrait, Self.innerLandscape] {
            h.apply(g)
            XCTAssertEqual(h.textField()?.text, "Ada Lovelace", "[\(g.name)] the typed answer is still in the field")
            XCTAssertTrue(h.textField() === field, "[\(g.name)] the same field (not rebuilt) across the mode change")
        }
        h.tap(h.button("Continue"))
        XCTAssertEqual(Self.answer(completed.first ?? nil, "name"), "Ada Lovelace", "the answer typed before the folds is the one continued: \(String(describing: completed.first))")
    }

    /// Negative control for the test above: a host rebuilt from scratch has an empty field.
    func testControlARebuiltOnboardingHostHasNoAnswer() throws {
        let flow = try onboardingFlow(hero: true)
        let h = Host(onboarding(flow), Self.outerPortrait)
        defer { h.close() }
        h.type("Ada Lovelace")
        XCTAssertEqual(h.textField()?.text, "Ada Lovelace", "control: the typing landed")
        h.host.rootView = AnyView(onboarding(flow).id(UUID()))
        h.apply(Self.innerLandscape)
        XCTAssertEqual(h.textField()?.text ?? "", "", "control: a rebuilt host lost the answer")
    }

    func testAFoldKeepsTheOnboardingScrollPosition() throws {
        let flow = try onboardingFlow(fillerBlocks: 40, hero: true)
        let h = Host(onboarding(flow), Self.outerPortrait)
        defer { h.close() }
        guard let scroll = h.scrollView() else { return XCTFail("a long step scrolls") }
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        h.spin(0.3)
        XCTAssertEqual(scroll.contentOffset.y, 300, accuracy: 1, "control: the harness can scroll the step")

        h.apply(Self.innerPortrait)
        let after = h.scrollView()
        XCTAssertTrue(after === scroll, "the same scroll view survives an unfold (no rebuild)")
        XCTAssertGreaterThan(after?.contentOffset.y ?? 0, 100, "an unfold does not throw the user back to the top")
        h.apply(Self.innerLandscape)
        XCTAssertTrue(h.scrollView() === scroll, "the same scroll view survives the move into two panes")
        XCTAssertGreaterThan(h.scrollView()?.contentOffset.y ?? 0, 100, "and keeps its place there")
        h.apply(Self.outerPortrait)
        XCTAssertGreaterThan(h.scrollView()?.contentOffset.y ?? 0, 100, "nor does folding again")
    }

    // MARK: - Paywall

    /// The CTA (filled magenta) measured off a render: below the plans, so only the bottom of the
    /// window is searched — the selected plan's border takes the same accent.
    private func ctaBox(_ h: Host) -> CGRect? {
        h.colourBox("#FF00FF", minY: h.window.bounds.height - 80)
    }

    func testAPaywallLaysOutInTheColumnAtEverySize() throws {
        // The header is a pitch before the plans, so the paywall splits where the window allows.
        for g in [Self.phone] + Self.all {
            let h = Host(try paywall(), g)
            defer { h.close() }
            let main = g.mainPane(splits: true)
            guard let cta = ctaBox(h) else { XCTFail("[\(g.name)] the CTA was not drawn"); continue }
            XCTAssertEqual(cta.width, main.width - 40, accuracy: 4, "[\(g.name)] the CTA \(cta) spans its pane (\(main.width)) less 20 each side")
            XCTAssertEqual(cta.midX, main.midX, accuracy: 3, "[\(g.name)] the CTA is centred in its pane")
            assertOnScreen(cta, g, "paywall CTA")
            XCTAssertNotNil(h.button("Start Alpha"), "[\(g.name)] the CTA names the default plan")
        }
    }

    /// The shape the generator writes: the plans PINNED to the bottom zone with the CTA. The whole
    /// scroll is then the pitch, so it splits on the inner display in landscape with the plans and the
    /// CTA in the trailing pane, and is the column everywhere else.
    func testAGeneratedShapePaywallWithPinnedPlansSplits() throws {
        let json = """
        {
          "id": "duo_paywall_pinned",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Choose a plan" } },
              { "type": "features", "config": { "features": [{ "text": "One" }, { "text": "Two" }] } },
              { "id": "p", "type": "plans", "zone": "bottom", "config": { "plan_display_style": "vertical_stack", "plans": [
                  { "product_id": "plan_alpha", "label": "Alpha", "price_display": "$1.11", "is_default": true, "cta_text": "Start Alpha" }
              ] } },
              { "type": "cta", "config": {} }
            ]
          },
          "cta": { "text": "Continue", "bg_color": "#FF00FF" }
        }
        """
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        for g in [Self.phone] + Self.all {
            let h = Host(AnyView(PaywallRenderer(config: config, onPlanSelected: { _, _ in }, onRestore: {}, onDismiss: { _ in })), g)
            defer { h.close() }
            let main = g.mainPane(splits: true)
            guard let cta = ctaBox(h) else { XCTFail("[\(g.name)] the CTA was not drawn"); continue }
            XCTAssertEqual(cta.midX, main.midX, accuracy: 3, "[\(g.name)] the CTA \(cta) is centred in its pane \(main.minX)…\(main.maxX)")
            // A `cta` SECTION is inset 16 a side (the root CTA of the test above, 20).
            XCTAssertEqual(cta.width, main.width - 32, accuracy: 4, "[\(g.name)] the CTA spans its pane less 16 each side")
        }
    }

    /// The selected plan survives a fold and an unfold, into two panes and back. Read off the CTA,
    /// which names the selected plan (`cta_text` per plan) and sits outside the scroll. The plans are
    /// pinned (the generator's shape), which keeps their rows outside the scroll too, where the
    /// accessibility tree publishes them; the header is the pitch, so the paywall splits.
    func testAFoldAndUnfoldKeepTheSelectedPlan() throws {
        let h = Host(try paywall(pinnedPlans: true), Self.phone)
        defer { h.close() }
        XCTAssertNotNil(h.button("Start Alpha"), "control: the default plan names the CTA; labels: \(h.labels())")
        // The plan row as a control (button trait), else whatever carries its name.
        let bravo = h.elements().first { ($0.accessibilityLabel ?? "").contains("Bravo") && $0.accessibilityTraits.contains(.button) }
            ?? h.element(containing: "Bravo")
        XCTAssertNotNil(bravo, "the harness reaches the Bravo row; labels: \(h.labels())")
        XCTAssertTrue(h.tap(bravo), "activating the Bravo row is handled; traits: \(String(describing: bravo?.accessibilityTraits)), label: \(String(describing: bravo?.accessibilityLabel))")
        XCTAssertNotNil(h.button("Start Bravo"), "selecting Bravo renames the CTA; labels: \(h.labels())")

        for g in [Self.outerPortrait, Self.innerPortrait, Self.innerLandscape, Self.outerLandscape, Self.innerLandscape, Self.phone] {
            h.apply(g)
            XCTAssertNotNil(h.button("Start Bravo"), "[\(g.name)] the selected plan is still selected; labels: \(h.labels())")
        }

        // Negative control: rebuilt from scratch, the paywall is back on its default plan.
        h.host.rootView = AnyView(try paywall(pinnedPlans: true).id(UUID()))
        h.spin(0.5)
        XCTAssertNotNil(h.button("Start Alpha"), "control: a rebuilt paywall forgets the selection")
    }

    // MARK: - In-app messages

    func testAMessageCardAndAFullscreenMessageStayInTheColumn() throws {
        for g in [Self.phone] + Self.all {
            let h = Host(try message("banner"), g)
            defer { h.close() }
            assertInsideColumn(h.element(containing: "A synthetic message"), in: h, "banner title")
        }
        for type in ["modal", "fullscreen"] {
            for g in [Self.phone] + Self.all {
                let h = Host(try message(type), g)
                defer { h.close() }
                guard let cta = h.button("Got it") else {
                    XCTFail("[\(type) \(g.name)] no CTA; labels: \(h.labels())"); continue
                }
                let f = h.frame(cta)
                XCTAssertLessThanOrEqual(f.width, 560, "[\(type) \(g.name)] the CTA is no wider than the column")
                XCTAssertEqual(f.midX, g.usableWidth / 2, accuracy: 3, "[\(type) \(g.name)] the CTA is centred")
                assertOnScreen(f, g, "\(type) CTA")
                if g.usableWidth > 600 {
                    XCTAssertLessThan(f.width, g.usableWidth - 100, "[\(type) \(g.name)] the CTA does not stretch edge to edge")
                }
            }
        }
    }

    /// A full-screen message with a hero splits on the inner display in landscape: its CTA and copy
    /// in the trailing pane. Without a hero it is the column there (the test above).
    func testAFullscreenMessageWithAHeroSplits() throws {
        for g in [Self.phone] + Self.all {
            let h = Host(try message("fullscreen", hero: true), g)
            defer { h.close() }
            let main = g.mainPane(splits: true)
            assertInside(h.button("Got it"), main, in: h, "the CTA")
            assertInside(h.element(containing: "A synthetic message"), main, in: h, "the title")
        }
    }

    // MARK: - Surveys

    func testASurveyLaysOutInTheColumnAtEverySize() throws {
        for g in [Self.phone] + Self.all {
            let h = Host(try survey(), g)
            defer { h.close() }
            assertInsideColumn(h.element(containing: "How likely"), in: h, "the question")
            assertInsideColumn(h.button("Next"), in: h, "Next")
            assertInsideColumn(h.button("10"), in: h, "the last NPS score")
        }
    }

    /// A score given before a fold is still the answer submitted after it.
    func testAFoldAndUnfoldKeepASurveyAnswer() throws {
        var results: [SurveyResult] = []
        let h = Host(try survey(completion: { results.append($0) }), Self.outerPortrait)
        defer { h.close() }

        h.tap(h.button("8"))
        h.apply(Self.innerPortrait)
        let next = h.button("Next")
        XCTAssertNotNil(next)
        XCTAssertFalse(next?.accessibilityTraits.contains(.notEnabled) ?? true, "the score survived the unfold: Next is enabled")
        h.tap(next)
        h.apply(Self.innerLandscape)
        h.tap(h.button("3"))
        h.apply(Self.outerPortrait)
        h.tap(h.button("Submit"))
        guard case .completed(let answers)? = results.first else {
            return XCTFail("the survey completed; got \(results)")
        }
        let byId = Dictionary(uniqueKeysWithValues: answers.map { ($0.question_id, "\($0.answer)") })
        XCTAssertEqual(byId["q1"], "8", "the first score, given before the unfold")
        XCTAssertEqual(byId["q2"], "3", "the second, given before the fold")
    }

    /// Negative control: rebuilt from scratch, the first question has no score and Next is off.
    func testControlARebuiltSurveyHasNoScore() throws {
        let h = Host(try survey(), Self.outerPortrait)
        defer { h.close() }
        h.tap(h.button("8"))
        XCTAssertFalse(h.button("Next")?.accessibilityTraits.contains(.notEnabled) ?? true, "control: a score enables Next")
        h.host.rootView = AnyView(try survey().id(UUID()))
        h.apply(Self.innerPortrait)
        XCTAssertTrue(h.button("Next")?.accessibilityTraits.contains(.notEnabled) ?? false, "control: a rebuilt survey has no score")
    }

    /// A survey presented as a sheet re-lays out when the window is unfolded and folded again: the
    /// sheet and its Submit button stay inside the window.
    func testASheetSurveyReLaysOutOnAFoldAndUnfold() throws {
        let h = Host(AnyView(Color.white), Self.outerPortrait)
        defer { h.close() }
        let json = #"{"id":"s","name":"s","survey_type":"nps","questions":[{"id":"q1","type":"nps","text":"How likely?"}],"appearance":{"presentation":"modal"}}"#
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(json.utf8))
        let sheet = UIHostingController(rootView: SurveyContainerView(config: config, completion: { _ in }))
        sheet.modalPresentationStyle = .pageSheet
        h.host.present(sheet, animated: false)
        h.spin(0.8)
        for g in [Self.outerPortrait, Self.innerPortrait, Self.innerLandscape, Self.outerPortrait] {
            h.apply(g)
            let frame = sheet.view.convert(sheet.view.bounds, to: h.window)
            XCTAssertTrue(h.window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "[\(g.name)] the sheet \(frame) is inside the window")
            guard let submit = h.button("Submit") else { XCTFail("[\(g.name)] no Submit; labels: \(h.labels())"); continue }
            let f = h.frame(submit)
            XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(f), "[\(g.name)] Submit \(f) is inside the sheet \(frame)")
            XCTAssertLessThanOrEqual(f.maxX, g.usableWidth + 0.5, "[\(g.name)] Submit is clear of the trailing inset")
        }
        sheet.dismiss(animated: false)
    }

    // MARK: - Helpers

    /// The answer a content-block step hands on for `field`, whichever shape it travels in.
    static func answer(_ data: [String: Any]?, _ field: String) -> String? {
        guard let data else { return nil }
        if let v = data[field] { return describe(v) }
        if let responses = data["responses"] as? [String: Any], let v = responses[field] { return describe(v) }
        for v in data.values {
            if let d = v as? [String: Any], let inner = d[field] { return describe(inner) }
        }
        return nil
    }

    private static func describe(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let a = v as? [String], a.count == 1 { return a[0] }
        if let d = v as? [String: Any], let s = d["value"] as? String { return s }
        return "\(v)"
    }
}
