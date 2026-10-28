// DropdownOptionSheetTests.swift
//
// A Select drawn as a dropdown (the default `display_style`) opens the picked option's
// `sheet_blocks`, as the list, stacked and grid styles do. These tests OPERATE the real dropdown:
// `FormInputSelectBlock` is hosted in a key window, and its menu-style `Picker` is driven through the
// UIKit menu SwiftUI builds for it — the picker is a `UIButton` whose `menu` holds one `UIAction` per
// row, and `sendAction` performs a row exactly as a tap on it does (the picker's own selection
// binding is called, a re-pick of the current row included). The system menu itself is never put on
// screen: a package test has no UIApplication to present it, so what is driven is the menu's ROW,
// not the gesture that opened it.
//
// Every option and every sheet is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/// The step's answers, read by the test after each pick.
private final class Answers {
    var values: [String: Any] = [:]
}

private struct DropdownHost: View {
    let block: ContentBlock
    let answers: Answers
    @State private var revision = 0

    var body: some View {
        FormInputSelectBlock(block: block, inputValues: Binding(
            get: { _ = revision; return answers.values },
            set: { answers.values = $0; revision += 1 }
        ))
    }
}

@MainActor
final class DropdownOptionSheetTests: XCTestCase {

    /// A dropdown (no `display_style`: the default) with one option that owns a sheet — closed by
    /// its own `dismiss` button — and one that does not.
    private func dropdownBlock() throws -> ContentBlock {
        let json = """
        {"id":"sel_plan","type":"input_select","field_id":"plan","field_placeholder":"Choose a plan",
         "field_options":[
           {"id":"monthly","value":"monthly","label":"Monthly","sheet_blocks":[
             {"id":"sh_text","type":"text","text":"Billed every month"},
             {"id":"sh_done","type":"button","text":"Done","action":"dismiss"}]},
           {"id":"yearly","value":"yearly","label":"Yearly"},
           {"id":"room_tpl__1","value":"r_b","label":"Loft","sheet_blocks":[
             {"id":"sh_room","type":"text","text":"About this room"},
             {"id":"sh_room_done","type":"button","text":"Done","action":"dismiss"}]}]}
        """
        return try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    private struct Fixture {
        let hosted: HostedStep
        let answers: Answers
    }

    private func host(answers initial: [String: Any] = [:]) throws -> Fixture {
        SelectedOptionStore.shared.resetForTesting()
        let answers = Answers()
        answers.values = initial
        let hosted = HostedStep(DropdownHost(block: try dropdownBlock(), answers: answers))
        return Fixture(hosted: hosted, answers: answers)
    }

    override func tearDown() {
        SelectedOptionStore.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Driving the picker's menu

    /// The menu-backed button SwiftUI builds for the dropdown's `Picker(.menu)`.
    private func pickerButton(_ hosted: HostedStep) -> UIButton? {
        func find(_ v: UIView) -> UIButton? {
            if let b = v as? UIButton, b.menu != nil { return b }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return find(hosted.window)
    }

    /// Performs the menu row titled `title`, as tapping that row does.
    @discardableResult
    private func pick(_ title: String, in hosted: HostedStep) -> Bool {
        guard let button = pickerButton(hosted), let menu = button.menu else {
            XCTFail("the dropdown drew no menu button")
            return false
        }
        func row(_ e: UIMenuElement) -> UIAction? {
            if let a = e as? UIAction, a.title == title { return a }
            if let m = e as? UIMenu { for c in m.children { if let f = row(c) { return f } } }
            return nil
        }
        guard let action = row(menu) else {
            XCTFail("the dropdown's menu has no row \(title)")
            return false
        }
        button.sendAction(action)
        return true
    }

    // MARK: - Reading the sheet

    private func presentedSheet(_ hosted: HostedStep) -> UIViewController? {
        hosted.host.presentedViewController
    }

    /// The `OptionBottomSheetView` the presented controller hosts — the select's one sheet presenter.
    ///
    /// The same environment never FINISHES a presentation, so a presented sheet cannot be dismissed
    /// here either (its `onDismiss` runs; the controller stays). Each test therefore makes at most
    /// one presentation, and the re-pick case is read off the answer the re-pick writes.
    ///
    /// The sheet is identified by what SwiftUI PRESENTED, not by the text it draws: a package test
    /// has no UIApplication to run the presentation transition, so UIKit records the presentation
    /// (`presentedViewController`) but never installs the sheet's view in a window, and an
    /// uninstalled SwiftUI view draws nothing to read (measured: zero accessibility elements, zero
    /// frame, even re-hosted in a window of its own). The presented controller's `rootView` is read
    /// instead, and the sheet view found in it says which option it presents. What that sheet DRAWS
    /// for an option is the shared fixture's `rendered_text`, and the presenter itself is unchanged.
    private func presentedSheetView(_ hosted: HostedStep) -> OptionBottomSheetView? {
        guard let vc = presentedSheet(hosted) as? UIHostingController<AnyView> else { return nil }
        func find(_ value: Any, _ depth: Int) -> OptionBottomSheetView? {
            if let sheet = value as? OptionBottomSheetView { return sheet }
            guard depth < 40 else { return nil }
            for child in Mirror(reflecting: value).children {
                if let f = find(child.value, depth + 1) { return f }
            }
            return nil
        }
        return find(vc.rootView, 0)
    }

    /// The id of the option whose sheet is presented, or nil.
    private func presentedOptionId(_ hosted: HostedStep) -> String? {
        presentedSheetView(hosted)?.option.id
    }

    // MARK: - Tests

    /// Picking an option that owns a sheet records the answer AT ONCE, and presents the sheet only
    /// after the menu has closed — never on top of the closing menu.
    /// RED before the fix: the dropdown's `onChange` wrote the answer and nothing ever set the sheet.
    func testPickingASheetOptionPresentsItsSheetAfterTheMenuCloses() throws {
        let f = try host()
        defer { f.hosted.close() }
        XCTAssertNil(presentedSheet(f.hosted), "nothing is presented before a pick")

        XCTAssertTrue(pick("Monthly", in: f.hosted))
        f.hosted.spin(0.05)
        XCTAssertEqual(f.answers.values["plan"] as? String, "monthly", "the choice is recorded first")
        XCTAssertNil(presentedSheet(f.hosted), "the sheet waits for the menu to close")

        XCTAssertTrue(f.hosted.wait(4) { presentedSheet(f.hosted) != nil }, "the picked option's sheet is presented")
        XCTAssertEqual(presentedOptionId(f.hosted), "monthly", "the sheet presented is the picked option's")
        XCTAssertEqual(presentedSheetView(f.hosted)?.option.sheet_blocks?.first?.text, "Billed every month")
        XCTAssertEqual(f.answers.values["plan"] as? String, "monthly", "the sheet only presents: the answer is unchanged")
    }

    /// An option without `sheet_blocks` records its answer and presents nothing.
    func testPickingAnOptionWithoutASheetPresentsNothing() throws {
        let f = try host()
        defer { f.hosted.close() }
        XCTAssertTrue(pick("Yearly", in: f.hosted))
        f.hosted.spin(1.0)
        XCTAssertEqual(f.answers.values["plan"] as? String, "yearly")
        XCTAssertNil(presentedSheet(f.hosted), "an option with no sheet presents nothing")
    }

    /// Picking the option that is already selected goes through the pick again — which is what
    /// re-opens its sheet, as a re-tap does in the other styles. The menu's row calls the picker's
    /// selection even for the current value; the old `onChange(of: selectedValue)` never fired for an
    /// unchanged value, so a re-pick reached nothing. The re-pick is read off the answer it writes:
    /// the answer is removed behind the view's back (the view keeps "monthly" selected), and only a
    /// pick that runs writes it again. That the pick then presents the sheet is the first test (one
    /// presentation per test, see `presentedSheetView`) and the shared fixture's `repicked`
    /// checkpoint. RED before the fix: the answer stays absent.
    func testRePickingTheSameOptionRunsThePickAgain() throws {
        let f = try host()
        defer { f.hosted.close() }
        XCTAssertTrue(pick("Monthly", in: f.hosted))
        XCTAssertTrue(f.hosted.wait(4) { presentedSheet(f.hosted) != nil }, "the first pick presents the sheet")
        XCTAssertEqual(presentedOptionId(f.hosted), "monthly")

        f.answers.values["plan"] = nil // no re-render: the view still shows "monthly" selected
        XCTAssertTrue(pick("Monthly", in: f.hosted))
        f.hosted.spin(0.1)
        XCTAssertEqual(f.answers.values["plan"] as? String, "monthly", "the re-pick ran the pick, which opens the sheet")
    }

    /// An option a repeat generated (id `<template>__<n>`, as the pipeline hands it to the view) opens
    /// its own sheet.
    func testAGeneratedOptionOpensItsSheet() throws {
        let f = try host()
        defer { f.hosted.close() }
        XCTAssertTrue(pick("Loft", in: f.hosted))
        XCTAssertTrue(f.hosted.wait(4) { presentedSheet(f.hosted) != nil })
        XCTAssertEqual(presentedOptionId(f.hosted), "room_tpl__1", "the generated option's own sheet")
        XCTAssertEqual(f.answers.values["plan"] as? String, "r_b")
    }

    /// Going back to the placeholder from an option that owns a sheet clears the answer and presents
    /// nothing. The option is selected by a RESTORED answer (a step revisited), so no sheet was
    /// presented on the way in.
    func testThePlaceholderPresentsNothing() throws {
        let f = try host(answers: ["plan": "monthly"])
        defer { f.hosted.close() }
        f.hosted.spin(0.3)
        XCTAssertNil(presentedSheet(f.hosted), "a restored answer is not a pick: nothing is presented")

        XCTAssertTrue(pick("Choose a plan", in: f.hosted))
        f.hosted.spin(1.0)
        XCTAssertEqual(f.answers.values["plan"] as? String, "", "the placeholder clears the answer")
        XCTAssertNil(presentedSheet(f.hosted), "the placeholder presents nothing")
    }
}
