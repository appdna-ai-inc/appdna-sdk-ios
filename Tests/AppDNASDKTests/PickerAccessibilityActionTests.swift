// PickerAccessibilityActionTests.swift
//
// The pickers OPERATED through the accessibility tree of a real hosted view — the path VoiceOver takes, and the closest
// a unit test gets to a finger:
//   - the linear measurement slider: `accessibilityIncrement()` / `accessibilityDecrement()` on its element move the
//     stored value by one step each (VoiceOver's swipe up / down);
//   - the Calendar-style Date Picker and the Calendar Date / Date-and-time field: activating a day's element stores
//     that day (a date and time keeps its time of day).
//   CONTROLS: the slider's value is read before the action (it must start where it was seeded), and the day is one the
//   picker did NOT open on, so a pass is the action landing rather than the seed being read back.
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

    /// `seed` is a saved answer: a Date field opens on the saved answer (it has no authored default), so a seed pins the
    /// month the calendar opens on whatever day the test runs.
    private func pickADay(_ json: String, field: String, seed: String? = nil) throws -> (before: Any?, after: Any?) {
        let store = Store()
        if let seed { store.values[field] = seed }
        let view = try host(json, store)
        let before = store.values[field]
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 20; c.hour = 12
        let label = DateFormatter.localizedString(from: Calendar.current.date(from: c)!, dateStyle: .long, timeStyle: .none)
        let day = try XCTUnwrap(element("date_range.day.2026-11-20", in: view)
            ?? elements(view).first { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) },
            "the day is an accessibility element (\(label)); labels: \(elements(view).compactMap(\.accessibilityLabel).prefix(60))")
        XCTAssertTrue(day.accessibilityActivate(), "the day takes an activation")
        settle(0.4)
        return (before, store.values[field])
    }

    func testACalendarStyleDatePickerStoresTheDayTapped() throws {
        let r = try pickADay(##"[{"id":"d","type":"date_wheel_picker","field_id":"cal","picker_mode":"date","default_date_value":"2026-11-12","min_date":"2026-01-01","max_date":"2027-12-31","field_config":{"picker_variant":"graphical"}}]"##, field: "cal")
        XCTAssertNotEqual(r.before as? String, "2026-11-20", "control: the picker did not open on the day tapped")
        XCTAssertEqual(r.after as? String, "2026-11-20")
    }

    func testACalendarDateFieldStoresTheDayTapped() throws {
        let r = try pickADay(##"[{"id":"f","type":"input_date","field_id":"born","picker_presentation":"inline","min_date":"2026-01-01","max_date":"2027-12-31","field_config":{"picker_variant":"graphical"}}]"##, field: "born", seed: "2026-11-12")
        XCTAssertEqual(r.before as? String, "2026-11-12", "control: the field opened on its saved day, not the day tapped")
        XCTAssertEqual(r.after as? String, "2026-11-20")
    }

    /// A date-and-time field in the Calendar variant: the day tapped is stored and the time of day is kept.
    func testACalendarDateTimeFieldStoresTheDayTappedAndKeepsTheTime() throws {
        let seed = AnswerTime.dateTimeString(
            try XCTUnwrap(AnswerTime.date(from: "2026-11-12T09:30:00Z", in: AnswerTime.zone)), in: AnswerTime.zone)
        let r = try pickADay(##"[{"id":"t","type":"input_datetime","field_id":"when","picker_presentation":"inline","min_date":"2026-01-01","max_date":"2027-12-31","field_config":{"picker_variant":"graphical"}}]"##, field: "when", seed: seed)
        XCTAssertEqual(r.before as? String, seed, "control: the field opened on its saved answer")
        let after = try XCTUnwrap(r.after as? String, "a day tap writes the answer")
        XCTAssertTrue(after.hasPrefix("2026-11-20T"), "the day tapped: \(after)")
        XCTAssertEqual(after.dropFirst(10), seed.dropFirst(10), "the time of day is kept: \(after) vs \(seed)")
    }
}
