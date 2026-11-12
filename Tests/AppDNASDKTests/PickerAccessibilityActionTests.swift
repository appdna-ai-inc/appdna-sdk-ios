// PickerAccessibilityActionTests.swift
//
// The pickers OPERATED through the accessibility tree of a real hosted view — the path VoiceOver takes, and the closest
// a unit test gets to a finger:
//   - the linear measurement slider: `accessibilityIncrement()` / `accessibilityDecrement()` on its element move the
//     stored value by one step each (VoiceOver's swipe up / down).
//   CONTROL: the slider's value is read before the action (it must start where it was seeded), so a pass is the action
//   landing rather than the seed being read back.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PickerAccessibilityActionTests: XCTestCase {
    final class Store { var values: [String: Any] = [:] }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func host(_ json: String, _ store: Store) throws -> UIView {
        _ = A11yAutomation.enabled  // SwiftUI publishes its element tree only with the accessibility runtime on
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let binding = Binding<[String: Any]>(get: { store.values }, set: { store.values = $0 })
        let size = CGSize(width: 393, height: 700)
        let h = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: binding)
            .frame(width: size.width, height: size.height).background(Color.white))
        let w = UIWindow(frame: CGRect(origin: .zero, size: size))
        w.rootViewController = h
        w.makeKeyAndVisible()
        window = w
        h.view.layoutIfNeeded()
        settle()
        return h.view
    }

    private func settle(_ s: TimeInterval = 0.6) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// Every accessibility element under `root`, depth first (SwiftUI exposes them through `accessibilityElements`).
    private func elements(_ root: NSObject) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(o)).inserted else { return }
            out.append(o)
            if let els = o.accessibilityElements as? [NSObject] { els.forEach { walk($0, depth + 1) } }
            if let v = o as? UIView { v.subviews.forEach { walk($0, depth + 1) } }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } } }
        }
        walk(root, 0)
        return out
    }

    /// SwiftUI's accessibility nodes answer `accessibilityIdentifier` without conforming to
    /// `UIAccessibilityIdentification` in Swift, so the property is read through the selector.
    private func identifier(_ o: NSObject) -> String? {
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue() as? String
    }

    private func element(_ id: String, in root: UIView) -> NSObject? {
        elements(root).first { identifier($0) == id }
    }

    func testVoiceOverAdjustMovesTheLinearSliderOneStepAtATime() throws {
        let store = Store()
        let units = ##"[{"id":"cm","label":"cm","min":100,"max":220,"step":1,"decimals":0,"factor":1,"offset":0}]"##
        let view = try host(##"[{"id":"h","type":"wheel_picker","field_id":"height","field_config":{"measurement_type":"height","measurement_style":"linear","measurement_default":160,"units":\##(units)}}]"##, store)
        XCTAssertEqual(store.values["height"] as? Int, 160, "control: the slider starts on its seed")
        let slider = try XCTUnwrap(element("measurement.linear", in: view)
            ?? elements(view).first { $0.accessibilityTraits.contains(.adjustable) && ($0.accessibilityValue ?? "").hasSuffix("cm") },
            "the slider is an accessibility element")
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable), "VoiceOver treats the slider as adjustable")
        slider.accessibilityIncrement(); settle(0.3)
        XCTAssertEqual(store.values["height"] as? Int, 161, "swipe up: one step up")
        slider.accessibilityIncrement(); settle(0.3)
        XCTAssertEqual(store.values["height"] as? Int, 162)
        slider.accessibilityDecrement(); settle(0.3)
        slider.accessibilityDecrement(); settle(0.3)
        slider.accessibilityDecrement(); settle(0.3)
        XCTAssertEqual(store.values["height"] as? Int, 159, "swipe down: one step down each")
        XCTAssertEqual(slider.accessibilityValue, "159 cm", "VoiceOver announces the value and its unit")
    }
}
