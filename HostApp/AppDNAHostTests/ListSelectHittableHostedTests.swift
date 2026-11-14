// ListSelectHittableHostedTests.swift
//
// A list-style Select's options were NOT HITTABLE to XCUITest (and so to anything that drives the
// accessibility tree: UI tests, VoiceOver touch exploration, the device-walk tooling), although a finger on the
// same pixels selected them. The cause was the step's scroll-view finder (`appdnaStepScrollContent`): a
// `UIViewRepresentable` placed as the content's `background`, so SwiftUI hosted it in a UIKit view the size of the
// WHOLE step content. Touch never reached it (the probe has interaction off), but the accessibility tree did: an
// empty element over the step, ordered above most of its rows. Which rows it covered depended on the step's
// content, which is why one generated flow showed it and another did not.
//
// This hosts the real `OnboardingFlowHost` in the host app's window scene, advances from the first step to the
// question step the way the CTA does, and reads the UIKit views that were laid out: no platform-view host may cover
// an option's centre. The finder must still find its scroll view (it is what keeps a Location field's logo in
// view), so that is asserted too.
//
// RED CONTROL (measured 2026-11-14): with `appdnaStepScrollContent` as `background(finder)` — the shape before the
// fix — the finder's host spans the step content and contains every option's centre, and this fails. On the
// iPhone 17 Pro simulator the same shape read `hittable: false` for three of four options in an XCUITest
// snapshot, and `true` for all four with the fix.
//
// All content is synthetic.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class ListSelectHittableHostedTests: XCTestCase {

    /// Turns on the accessibility runtime so SwiftUI publishes its element tree (empty otherwise in a test).
    private static let a11y: Bool = {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(sym, to: SetEnabled.self)(1)
        return true
    }()

    private func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func elements(_ window: UIWindow) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(o)).inserted else { return }
            out.append(o)
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } }
            }
            for e in o.accessibilityElements ?? [] { if let e = e as? NSObject { walk(e, depth + 1) } }
            if let v = o as? UIView { for s in v.subviews { walk(s, depth + 1) } }
        }
        walk(window, 0)
        return out
    }

    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; spin(0.1) }
        return cond()
    }

    /// A welcome step with entrance animations, then a question step with an emoji icon, a heading, body text with a
    /// line height, a required list Select and a pinned CTA: the shape of the step the defect was found on.
    private static let flowJSON = ##"""
    {"id":"f","name":"List select","version":1,"status":"active",
     "settings":{"allow_back":true,"show_progress":true,"progress_style":"continuous_bar","dismiss_allowed":true,
                 "background":{"type":"color","color":"#FFFFFF"}},
     "steps":[
      {"id":"s1","type":"welcome","layout":{},"content_blocks":[
        {"id":"b","type":"badge","badge_text":"Day one"},
        {"id":"h1","type":"heading","text":"A short start","style":{"alignment":"center","font_size":30,"font_weight":700},
         "entrance_animation":{"type":"slide_up","easing":"ease_out","delay_ms":150,"duration_ms":450}},
        {"id":"t1","type":"text","text":"Two screens, one question.","style":{"alignment":"center","font_size":17,"line_height":1.5},
         "entrance_animation":{"type":"slide_up","easing":"ease_out","delay_ms":250,"duration_ms":450}},
        {"id":"go","type":"button","text":"Begin","zone":"bottom","action":"next","variant":"primary","button_height":56,"vertical_align":"bottom"}],
       "next_step_rules":[{"condition":"always","target_step_id":"s2"}]},
      {"id":"s2","type":"question","layout":{},"content_blocks":[
        {"id":"i","type":"icon","icon_size":48,"icon_emoji":"⭐","icon_alignment":"left"},
        {"id":"h2","type":"heading","text":"Which one fits?","style":{"alignment":"left","font_size":28,"font_weight":700}},
        {"id":"t2","type":"text","text":"Your answer picks what the next screen shows.","style":{"alignment":"left","font_size":17,"line_height":1.5}},
        {"id":"sel","type":"input_select","field_id":"pick","field_label":"Pick one","field_config":{"display_style":"list"},
         "field_options":[{"id":"a","label":"Alpha"},{"id":"b","label":"Bravo"},{"id":"c","label":"Charlie"},{"id":"d","label":"Delta"}],
         "field_required":true},
        {"id":"next","type":"button","text":"Continue","zone":"bottom","action":"next","variant":"primary","button_height":56,"vertical_align":"bottom"}]}
     ]}
    """##

    func testNoUIKitHostCoversAListSelectsOptions() throws {
        XCTAssertTrue(Self.a11y, "the accessibility runtime is needed to read the tree")
        let flow = try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(Self.flowJSON.utf8))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("the host app has no window scene")
        }
        var viewed: [String] = []
        let host = UIHostingController(rootView: OnboardingFlowHost(
            flow: flow, delegate: nil, eventTracker: nil,
            onStepViewed: { id, _ in viewed.append(id) }, onStepCompleted: { _, _, _ in }, onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in }, onFlowDismissed: { _, _ in }))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Advance from the welcome step through its CTA, as a tap does.
        var begin: NSObject?
        XCTAssertTrue(waitFor(6) { begin = elements(window).first { $0.accessibilityLabel == "Begin" }; return begin != nil },
                      "the welcome step's CTA is in the tree")
        XCTAssertEqual(begin?.accessibilityActivate(), true)
        XCTAssertTrue(waitFor(6) { viewed.contains("s2") }, "the question step is viewed; saw \(viewed)")

        // The step slides in: read the options' frames once they are on screen and have stopped moving.
        let labels = ["Alpha", "Bravo", "Charlie", "Delta"]
        var options: [String: CGRect] = [:]
        var previous: [String: CGRect] = [:]
        XCTAssertTrue(waitFor(10) {
            let els = elements(window)
            previous = options
            options = [:]
            for l in labels { if let e = els.first(where: { $0.accessibilityLabel == l }) { options[l] = e.accessibilityFrame } }
            let settled = options.count == labels.count && options == previous
            if !settled { spin(0.3) }
            return settled && options.values.allSatisfy { window.bounds.contains($0) }
        }, "every option is in the tree, on screen and settled; found \(options)")

        // CONTROL: the harness can see the finder at all — its probe is laid out, inside the step's scroll view.
        let all = views(window)
        let probes = all.compactMap { $0 as? AppDNAEnclosingScrollViewFinder.Probe }
        XCTAssertFalse(probes.isEmpty, "the step's scroll-view finder is laid out (the harness can see it)")
        for p in probes {
            var v: UIView? = p.superview
            while let c = v, !(c is UIScrollView) { v = c.superview }
            XCTAssertNotNil(v, "the finder still finds the step's scroll view, which is its whole job")
        }

        // THE ASSERTION: no UIKit platform-view host inside the step covers an option's centre.
        for (label, f) in options.sorted(by: { $0.key < $1.key }) {
            let centre = CGPoint(x: f.midX, y: f.midY)
            let covering = all.filter { v in
                String(describing: type(of: v)).contains("PlatformViewHost")
                    && v.convert(v.bounds, to: nil).contains(centre)
            }
            print("[1827] \(label) centre \(centre) covering \(covering.map { "\(type(of: $0)) \($0.convert($0.bounds, to: nil))" })")
            XCTAssertTrue(covering.isEmpty,
                          "\(label) at \(centre) is covered by \(covering.map { "\(type(of: $0)) \($0.convert($0.bounds, to: nil))" })")
        }
    }
}
