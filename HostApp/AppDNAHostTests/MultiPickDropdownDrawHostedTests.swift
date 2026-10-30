// MultiPickDropdownDrawHostedTests.swift
//
// A dropdown-style Select with `multi_select`, RENDERED and OPERATED: the real renderer is hosted in
// a window on the host app's scene, the field's `Menu` is opened, an option is picked from the menu
// UIKit presents, and the field's drawn label and the stored answer are read back. This is the view's
// own wiring: the menu item's action → `pickMultiFromDropdown` → `DropdownSelectPick.apply` (the
// write) and `SelectionResync` (what the field draws). The Android twin is `MultiPickDropdownDrawTest`.
//
// 🔴 IT LIVES IN THE APP-HOSTED TARGET, not beside the package's other tests. The hostless target has
// no connected window scene, and a `Menu` presents through a context-menu interaction that needs one:
// there the field's button carries an EMPTY menu, activating it presents nothing, and asking the
// interaction to present directly presents nothing either — measured, three ways. Inside the host app
// there is a real scene, so the menu presents and its rows can be found.
//
// The pick runs the action of the row UIKit drew, taken from the menu its list is displaying, then
// closes the menu: a lifted finger cannot be synthesised in-process, and a menu row's tap is exactly
// that action plus the close. Activating the row's accessibility element does not run it (measured).
//
// RED CONTROL: a menu item whose action no longer reaches `pickMultiFromDropdown` → the field keeps
// its placeholder and nothing is stored, and this fails (measured: every assertion after the first
// pick fails). Cutting only the explicit resync inside `pickMultiFromDropdown` still passes, because
// the field's `onChange(of: inputValues)` resyncs the drawn list from the same write — two routes to
// one draw, and this test asserts the draw.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class MultiPickDropdownDrawHostedTests: XCTestCase {

    /// Turns on the accessibility runtime so SwiftUI publishes its element tree; it is otherwise empty
    /// in a test process.
    private static let a11y: Bool = {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(sym, to: SetEnabled.self)(1)
        return true
    }()

    /// Holds the step's answers the way a step does (as view state), and mirrors them out for the test.
    final class Answers { var values: [String: Any] = [:] }

    private struct Harness: View {
        let blocks: [ContentBlock]
        let answers: Answers
        @State private var values: [String: Any] = [:]
        var body: some View {
            ContentBlockRendererView(
                blocks: blocks, onAction: { _, _ in },
                toggleValues: .constant([:]),
                inputValues: Binding(get: { values }, set: { values = $0; answers.values = $0 })
            )
        }
    }

    private func blocks() throws -> [ContentBlock] {
        let json: [[String: Any]] = [[
            "id": "m", "type": "input_select", "field_id": "fav", "multi_select": true,
            "field_placeholder": "Pick some",
            "field_options": [
                ["id": "a", "value": "a", "label": "Alpha"],
                ["id": "b", "value": "b", "label": "Bravo"],
            ],
        ]]
        return try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var window: UIWindow?

    private func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// Every accessibility element in every window of the scene: an open menu draws its items outside
    /// the host view, in a window of its own.
    private func allElements() -> [NSObject] {
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
        for w in window?.windowScene?.windows ?? [] { walk(w, 0) }
        return out
    }

    private func labels() -> [String] { allElements().compactMap(\.accessibilityLabel) }

    /// The field: the Menu's own button, labelled with what it draws.
    private func field(_ label: String) -> NSObject? {
        allElements().first { ($0.accessibilityLabel == label || ($0.accessibilityValue ?? "") == label)
            && $0.accessibilityTraits.contains(.button) }
    }

    /// The UIKit button SwiftUI backs the field's `Menu` with (it owns the menu's interaction).
    private func fieldButton() -> UIButton? {
        func find(_ v: UIView) -> UIButton? {
            if let b = v as? UIButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return window.flatMap(find)
    }

    /// An item of the open menu: an element labelled `option` that is not the field itself.
    private func menuItem(_ option: String, besides fieldElement: NSObject) -> NSObject? {
        allElements().first { $0 !== fieldElement && $0.accessibilityLabel == option && !($0 is UIWindow) }
    }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; spin(0.1) }
        return cond()
    }

    /// Open the menu from the field labelled `fieldLabel`, pick `option` from it, and wait for the menu
    /// to close.
    private func pick(_ option: String, from fieldLabel: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = field(fieldLabel) else {
            return XCTFail("no field labelled \(fieldLabel); labels: \(labels())", file: file, line: line)
        }
        XCTAssertTrue(f.accessibilityActivate(), "the field opens its menu", file: file, line: line)
        var item: NSObject?
        guard waitFor(4, { item = menuItem(option, besides: f); return item != nil }), let item else {
            return XCTFail("the menu never showed \(option); labels: \(labels())", file: file, line: line)
        }
        // The row on screen is a cell of the menu UIKit presented, and that list view holds the menu it
        // displays. A lifted finger on the row runs that row's action and closes the menu; a test
        // cannot lift a finger in-process, so it runs the same action and then closes the menu.
        var list: UIView? = (item as? UIView) ?? allElements().compactMap { $0 as? UIView }.first {
            $0.accessibilityLabel == option && String(describing: type(of: $0)).contains("ContextMenuCell")
        }
        while let l = list, !String(describing: type(of: l)).contains("ContextMenuListView") { list = l.superview }
        guard let displayed = list?.value(forKey: "displayedMenu") as? UIMenu else {
            return XCTFail("no presented menu list holds \(option)", file: file, line: line)
        }
        var actions: [UIAction] = []
        func collect(_ m: UIMenu) {
            for c in m.children { if let a = c as? UIAction { actions.append(a) } else if let sub = c as? UIMenu { collect(sub) } }
        }
        collect(displayed)
        guard let action = actions.first(where: { $0.title == option }) else {
            return XCTFail("the presented menu has no \(option): \(actions.map(\.title))", file: file, line: line)
        }
        UIButton().sendAction(action)
        fieldButton()?.contextMenuInteraction?.dismissMenu()
        _ = waitFor(4) { menuItem(option, besides: f) == nil || field(option) != nil }
        spin(0.6)
    }

    func testPickingFromTheMenuStoresAListAndTheFieldDrawsItInPickOrder() throws {
        XCTAssertTrue(Self.a11y, "the accessibility runtime is needed to read the tree")
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("the host app has no window scene")
        }
        let answers = Answers()
        let host = UIHostingController(rootView: Harness(blocks: try blocks(), answers: answers).frame(width: 393, height: 852))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        self.window = window
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        spin(0.6)
        defer { window.isHidden = true }

        // The control: the harness can see the field and its placeholder before any pick.
        XCTAssertNotNil(field("Pick some"), "the field draws its placeholder; labels: \(labels())")
        XCTAssertNil(answers.values["fav"], "nothing is stored before a pick")

        pick("Bravo", from: "Pick some")
        XCTAssertEqual(answers.values["fav"] as? [String], ["b"], "the pick is stored as a list")
        XCTAssertNotNil(field("Bravo"), "the field draws the pick; labels: \(labels())")

        pick("Alpha", from: "Bravo")
        XCTAssertEqual(answers.values["fav"] as? [String], ["b", "a"], "picks are stored in pick order")
        XCTAssertNotNil(field("Bravo, Alpha"), "the field draws the picks in pick order; labels: \(labels())")

        pick("Bravo", from: "Bravo, Alpha")
        XCTAssertEqual(answers.values["fav"] as? [String], ["a"], "picking a picked option removes it")
        XCTAssertNotNil(field("Alpha"), "the field draws what is left; labels: \(labels())")
    }
}
