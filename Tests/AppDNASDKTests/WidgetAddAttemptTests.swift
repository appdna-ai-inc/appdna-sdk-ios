// WidgetAddAttemptTests.swift
//
// The `add_widget` button on iOS: one test per row of the attempt's state machine, driven through its
// seams (the extension probe, the configurations source) against the PRODUCTION `WidgetAddAttempt`,
// plus the extension probe on real bundles on disk, the sheet's button routing, and the decode.
//
// All widget data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

/// A configurations source whose reads are answered by the test, in order — so a test can hold a read
/// open across another event.
final class HeldWidgetSource: WidgetConfigurationsSource {
    private var pending: [(Set<WidgetInstance>?) -> Void] = []
    var reads = 0

    func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void) {
        reads += 1
        pending.append(completion)
    }

    var waiting: Int { pending.count }

    func answer(_ value: Set<WidgetInstance>?) {
        guard !pending.isEmpty else { return XCTFail("no read is waiting") }
        pending.removeFirst()(value)
    }
}

/// Answers every read at once with `current`.
final class ImmediateWidgetSource: WidgetConfigurationsSource {
    var current: Set<WidgetInstance>?
    var reads = 0
    init(_ current: Set<WidgetInstance>?) { self.current = current }
    func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void) {
        reads += 1
        completion(current)
    }
}

@MainActor
final class WidgetAddAttemptTests: XCTestCase {

    static let small = WidgetInstance(id: "w_existing", kind: "SampleWidget", family: "systemSmall")
    static let medium = WidgetInstance(id: "w_new", kind: "SampleWidget", family: "systemMedium")

    /// What the step saw.
    final class StepSpy {
        var events: [(name: String, props: [String: Any])] = []
        var advances: [WidgetStatus] = []
        var toasts = 0
        var gateOpen = true

        func hooks() -> WidgetAddAttempt.StepHooks {
            .init(flowId: "flow_w", stepId: "step_w",
                  gate: { [unowned self] in gateOpen },
                  onGateRefused: { [unowned self] in toasts += 1 },
                  track: { [unowned self] name, props in events.append((name, props)) },
                  advance: { [unowned self] in advances.append($0) })
        }

        var names: [String] { events.map(\.name) }
        func props(_ name: String) -> [String: Any]? { events.last { $0.name == name }?.props }
    }

    static func button(howto: [String] = ["h_head", "h_done", "h_close"], id: String? = "cta_w") throws -> ContentBlock {
        let blocks: [String: String] = [
            "h_head": #"{"id":"h_head","type":"heading","text":"Add the widget"}"#,
            "h_done": #"{"id":"h_done","type":"button","text":"Done","action":"next"}"#,
            "h_close": #"{"id":"h_close","type":"button","text":"Close","action":"dismiss","variant":"text"}"#,
        ]
        let list = howto.compactMap { blocks[$0] }.joined(separator: ",")
        let idPart = id.map { #""id":"\#($0)","# } ?? ""
        let json = #"{\#(idPart)"type":"button","text":"Add the widget","action":"add_widget","howto_blocks_ios":[\#(list)]}"#
        return try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    private func make(hasExtension: Bool = true, source: WidgetConfigurationsSource) -> (WidgetAddAttempt, StepSpy) {
        let attempt = WidgetAddAttempt(platform: .init(hasWidgetExtension: { hasExtension }, configurations: source))
        let spy = StepSpy()
        attempt.configure(presentation: 1, hooks: spy.hooks())
        return (attempt, spy)
    }

    /// The sheet's onDismiss, as SwiftUI runs it after the sheet item goes nil.
    private func systemDismissedIfClosed(_ attempt: WidgetAddAttempt, hadSheet: Bool) {
        if hadSheet && attempt.sheet == nil { attempt.sheetDidDismiss() }
    }

    // MARK: - idle × tap

    /// Row: IDLE × TAP, gate refused → toast, nothing else.
    /// RED CONTROL: `tap` without its `hooks.gate()` guard presents the sheet and emits.
    func testGateRefusedShowsTheToastAndStartsNothing() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(source: source)
        spy.gateOpen = false
        attempt.tap(try Self.button())
        XCTAssertEqual(spy.toasts, 1, "the step's validation toast")
        XCTAssertEqual(spy.names, [], "a refused gate emits nothing")
        XCTAssertEqual(source.reads, 0, "no widget read")
        XCTAssertNil(attempt.sheet, "no how-to")
        XCTAssertEqual(spy.advances, [], "no advance")
        XCTAssertEqual(attempt.phase, .idle)
    }

    /// Row: IDLE × TAP, probe finds no extension → `widget_add_unavailable{no_widget}`, advance
    /// `unavailable`, no how-to.
    /// RED CONTROL: `tap` without the probe guard reads and presents the how-to instead.
    func testNoWidgetExtensionAdvancesUnavailable() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(hasExtension: false, source: source)
        attempt.tap(try Self.button())
        XCTAssertEqual(spy.names, ["widget_add_unavailable"])
        XCTAssertEqual(spy.props("widget_add_unavailable")?["reason"] as? String, "no_widget")
        XCTAssertEqual(spy.props("widget_add_unavailable")?["flow_id"] as? String, "flow_w")
        XCTAssertEqual(spy.props("widget_add_unavailable")?["step_id"] as? String, "step_w")
        XCTAssertEqual(spy.advances, [.unavailable])
        XCTAssertNil(attempt.sheet)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(attempt.phase, .done)
    }

    /// Row: IDLE × TAP → read S0 FIRST, then `widget_add_tapped{existing_count}`, the how-to, and
    /// `widget_howto_shown`. A second tap while the read is out is ignored.
    /// RED CONTROL: emitting `widget_add_tapped` before the read (the log order flips).
    func testTapReadsBeforeAnyEventThenPresentsTheHowto() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(source: source)
        let order = WidgetBox<[String]>([])
        let tracker = spy.hooks()
        attempt.configure(presentation: 1, hooks: .init(
            flowId: tracker.flowId, stepId: tracker.stepId, gate: tracker.gate, onGateRefused: tracker.onGateRefused,
            track: { name, props in order.value.append(name); tracker.track(name, props) }, advance: tracker.advance))
        let reading = ReadLogSource(inner: source) { order.value.append("read") }
        attempt.platform = .init(hasWidgetExtension: { true }, configurations: reading)

        attempt.tap(try Self.button())
        XCTAssertEqual(attempt.phase, .reading)
        XCTAssertEqual(order.value, ["read"], "S0 is read before any event")
        attempt.tap(try Self.button())
        XCTAssertEqual(source.reads, 1, "a second tap while reading is ignored")
        source.answer([Self.small])
        XCTAssertEqual(order.value, ["read", "widget_add_tapped", "widget_howto_shown"])
        XCTAssertEqual(spy.props("widget_add_tapped")?["existing_count"] as? Int, 1)
        XCTAssertEqual(spy.props("widget_add_tapped")?["block_id"] as? String, "cta_w")
        XCTAssertEqual(spy.props("widget_howto_shown")?["block_id"] as? String, "cta_w")
        XCTAssertEqual(attempt.sheet?.blocks.map(\.id), ["h_head", "h_done", "h_close"])
        XCTAssertEqual(attempt.phase, .howto)
    }

    /// `existing_count` is null when the read at the tap fails; detection is then off, so Done yields
    /// `unknown` (iOS cannot tell) with no second read.
    /// RED CONTROL: `existing_count` reported as 0 for a failed read.
    func testFailedReadAtTheTapTurnsDetectionOff() throws {
        let source = ImmediateWidgetSource(nil)
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        XCTAssertTrue(spy.props("widget_add_tapped")?["existing_count"] is NSNull, "null, not 0")
        attempt.appDidBecomeActive()
        XCTAssertEqual(source.reads, 1, "no read on return with S0 unknown")
        let had = attempt.sheet != nil
        attempt.doneTapped()
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertEqual(source.reads, 1, "no read on Done with S0 unknown")
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_add_unknown", "widget_howto_dismissed"])
        XCTAssertTrue(spy.props("widget_add_unknown")?["existing_count"] is NSNull)
        XCTAssertEqual(spy.advances, [.unknown])
    }

    // MARK: - howto × active

    /// Row: HOWTO × ACTIVE, S1−S0 non-empty → the SDK closes the how-to itself, `dismissed{detected}`,
    /// `widget_added{howto, family of the NEW widget}`, advance `added`. The sheet's onDismiss after
    /// that programmatic close reports nothing.
    /// RED CONTROL: `appDidBecomeActive` returning without a read — the how-to stays up, no advance.
    func testReturnWithANewWidgetClosesTheHowtoAndAdvancesAdded() throws {
        let source = ImmediateWidgetSource([Self.small])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        source.current = [Self.small, Self.medium]
        let had = attempt.sheet != nil
        attempt.appDidBecomeActive()
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertNil(attempt.sheet)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_howto_dismissed", "widget_added"])
        XCTAssertEqual(spy.props("widget_howto_dismissed")?["via"] as? String, "detected")
        XCTAssertEqual(spy.props("widget_added")?["method"] as? String, "howto")
        XCTAssertEqual(spy.props("widget_added")?["family"] as? String, "systemMedium")
        XCTAssertEqual(spy.advances, [.added])
        XCTAssertEqual(attempt.phase, .done)
    }

    /// Row: HOWTO × ACTIVE, no new widget → stays in HOWTO, nothing emitted.
    /// RED CONTROL: `appDidBecomeActive` concluding on every answered read (`conclude` instead of
    /// waiting for a new widget) advances here.
    func testReturnWithoutANewWidgetStays() throws {
        let source = ImmediateWidgetSource([Self.small])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        attempt.appDidBecomeActive()
        XCTAssertEqual(source.reads, 2)
        XCTAssertNotNil(attempt.sheet)
        XCTAssertEqual(attempt.phase, .howto)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown"])
        XCTAssertEqual(spy.advances, [])
    }

    /// D10: a widget removed and another added in the same trip still reads as added — a set
    /// difference, never a count compare.
    /// RED CONTROL: `firstAdded` as `after.count > before.count ? … : nil` returns nil here.
    func testDetectionIsASetDifferenceNotACount() {
        XCTAssertEqual(WidgetAddAttempt.firstAdded(before: [Self.small], after: [Self.medium]), Self.medium)
        XCTAssertNil(WidgetAddAttempt.firstAdded(before: [Self.small, Self.medium], after: [Self.small]))
        XCTAssertNil(WidgetAddAttempt.firstAdded(before: [Self.small], after: [Self.small]))
    }

    /// The one entry WidgetKit reports for a size can come back with a NEW identity once a second widget
    /// of that size is placed (iOS 26.2 simulator, walk 3). That is not a new kind or size, so it is not
    /// `added`: with the small one already placed, the attempt ends `unknown`, whatever the timing.
    /// RED CONTROL: `firstAdded` as `after.subtracting(before)` returns `smallAgain` here.
    func testASizeAlreadyPlacedIsNotNewWhenItsEntryChangesIdentity() {
        let smallAgain = WidgetInstance(id: "w_existing_reissued", kind: "SampleWidget", family: "systemSmall")
        XCTAssertNil(WidgetAddAttempt.firstAdded(before: [Self.small], after: [smallAgain]))
        XCTAssertNil(WidgetAddAttempt.firstAdded(before: [Self.small], after: [Self.small, smallAgain]))
        XCTAssertEqual(WidgetAddAttempt.firstAdded(before: [Self.small], after: [smallAgain, Self.medium]), Self.medium)
        XCTAssertEqual(WidgetAddAttempt.outcome(added: WidgetAddAttempt.firstAdded(before: [Self.small], after: [smallAgain]),
                                                before: [Self.small], detection: "ok"), .unknown)
    }

    // MARK: - howto × Done → checking

    /// Rows: HOWTO × DONE_CTA → CHECKING (a read); CHECKING × QUERY(S1) with nothing new and NO widget
    /// at the tap → `widget_not_added{howto, ok}`, close(cta), `dismissed{cta}`, advance `not_added`.
    /// While the read is out, a second Done, a tap and a return are all ignored.
    /// RED CONTROL: `doneTapped` advancing without the read (no CHECKING state) emits before `answer`;
    /// `outcome` answering `unknown` for an empty S0 fails the status.
    func testDoneWithoutAddingAdvancesNotAdded() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        source.answer([])
        attempt.doneTapped()
        XCTAssertEqual(attempt.phase, .checking)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown"], "nothing decided until S1 is read")
        attempt.doneTapped()
        attempt.tap(try Self.button())
        attempt.appDidBecomeActive()
        XCTAssertEqual(source.waiting, 1, "one read in flight")
        let had = attempt.sheet != nil
        source.answer([])
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_not_added", "widget_howto_dismissed"])
        XCTAssertEqual(spy.props("widget_not_added")?["method"] as? String, "howto")
        XCTAssertEqual(spy.props("widget_not_added")?["detection"] as? String, "ok")
        XCTAssertEqual(spy.props("widget_howto_dismissed")?["via"] as? String, "cta")
        XCTAssertEqual(spy.advances, [.notAdded])
        XCTAssertNil(attempt.sheet)
    }

    /// The user ALREADY had the app's widget at the tap and nothing new appeared: WidgetKit cannot see a
    /// second widget of a size already placed, so the outcome is `unknown` — `widget_add_unknown{howto,
    /// existing_count}`, never `widget_not_added`.
    /// RED CONTROL: `outcome` answering `not_added` whenever nothing was added (the old rule).
    func testDoneWithAWidgetAlreadyPlacedIsUnknown() throws {
        let source = ImmediateWidgetSource([Self.small])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        let had = attempt.sheet != nil
        attempt.doneTapped()
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_add_unknown", "widget_howto_dismissed"])
        XCTAssertEqual(spy.props("widget_add_unknown")?["method"] as? String, "howto")
        XCTAssertEqual(spy.props("widget_add_unknown")?["existing_count"] as? Int, 1)
        XCTAssertEqual(spy.advances, [.unknown])
    }

    /// The rule itself, every case: added wins; not_added only from an empty, known S0 with a read
    /// that answered; everything else unknown.
    /// RED CONTROL: each wrong rule (`not_added` for any miss; `unknown` for an empty S0; `not_added`
    /// on a failed read) fails its own line.
    func testTheOutcomeRule() {
        typealias A = WidgetAddAttempt
        XCTAssertEqual(A.outcome(added: Self.medium, before: [Self.small], detection: "ok"), .added)
        XCTAssertEqual(A.outcome(added: nil, before: [], detection: "ok"), .notAdded, "no widget before, none now")
        XCTAssertEqual(A.outcome(added: nil, before: [Self.small], detection: "ok"), .unknown, "one already placed")
        XCTAssertEqual(A.outcome(added: nil, before: [], detection: "unavailable"), .unknown, "the Done read failed")
        XCTAssertEqual(A.outcome(added: nil, before: nil, detection: "unavailable"), .unknown, "the tap read failed")
    }

    /// Row: CHECKING × QUERY(S1) with a new widget → `widget_added{howto}`, `added` (the CTA re-query).
    /// RED CONTROL: Done concluding from S0 alone reports not_added.
    func testDoneAfterAddingAdvancesAdded() throws {
        let source = ImmediateWidgetSource([])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        source.current = [Self.medium]
        let had = attempt.sheet != nil
        attempt.doneTapped()
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_added", "widget_howto_dismissed"])
        XCTAssertEqual(spy.props("widget_added")?["family"] as? String, "systemMedium")
        XCTAssertEqual(spy.advances, [.added])
    }

    /// A read at Done that FAILS, though the user had no widget at the tap → `unknown` (iOS cannot
    /// tell), with `existing_count` 0, after exactly one read at Done.
    /// RED CONTROL: `check` treating a failed read as an empty set (`placed ?? []`) concludes
    /// `not_added`.
    func testDoneWithAFailedReadIsUnknown() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        source.answer([])
        attempt.doneTapped()
        XCTAssertEqual(source.waiting, 1, "Done reads once")
        source.answer(nil)
        XCTAssertFalse(spy.names.contains("widget_not_added"))
        XCTAssertEqual(spy.props("widget_add_unknown")?["existing_count"] as? Int, 0)
        XCTAssertEqual(spy.advances, [.unknown])
    }

    // MARK: - howto × close

    /// Row: HOWTO × CLOSE(swipe) → `dismissed{swipe}` → IDLE, no advance; the next tap is a new attempt.
    /// RED CONTROL: `sheetDidDismiss` ignoring an unrecorded close — no `swipe` event, still HOWTO.
    func testSwipeReturnsToTheStepWithoutAdvancing() throws {
        let source = ImmediateWidgetSource([])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        attempt.sheet = nil
        attempt.sheetDidDismiss()
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_howto_dismissed"])
        XCTAssertEqual(spy.props("widget_howto_dismissed")?["via"] as? String, "swipe")
        XCTAssertEqual(spy.advances, [])
        XCTAssertEqual(attempt.phase, .idle)
        attempt.tap(try Self.button())
        XCTAssertEqual(spy.names.filter { $0 == "widget_add_tapped" }.count, 2, "a new attempt")
        XCTAssertNotNil(attempt.sheet)
    }

    /// Row: HOWTO × CLOSE(dismiss) → `dismissed{dismiss}` once → IDLE. The closed sheet's `onDismiss`
    /// can arrive late — after the user has already tapped again and a NEW how-to is up — and must not
    /// be read as a swipe of the new one.
    /// RED CONTROL: `close(_:)` without recording its reason — the late onDismiss reports a `swipe` and
    /// retires the new attempt.
    func testCloseButtonReturnsToTheStepAndIsReportedOnce() throws {
        let source = ImmediateWidgetSource([])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        attempt.closeTapped()
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_howto_dismissed"])
        XCTAssertEqual(spy.props("widget_howto_dismissed")?["via"] as? String, "dismiss")
        XCTAssertEqual(spy.advances, [])
        XCTAssertEqual(attempt.phase, .idle)

        attempt.tap(try Self.button())
        attempt.sheetDidDismiss() // the FIRST sheet's onDismiss, late
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown", "widget_howto_dismissed",
                                   "widget_add_tapped", "widget_howto_shown"], "no phantom swipe")
        XCTAssertEqual(attempt.phase, .howto, "the new attempt is still live")
        XCTAssertNotNil(attempt.sheet)
    }

    /// A read that answers after its attempt was closed is dropped: no `widget_added` for a retired
    /// attempt.
    /// RED CONTROL: the read's `serial` check removed — the late answer advances a closed attempt.
    func testALateReadAfterACloseIsDropped() throws {
        let source = HeldWidgetSource()
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        source.answer([])
        attempt.appDidBecomeActive()
        attempt.closeTapped()
        attempt.sheetDidDismiss()
        source.answer([Self.medium])
        XCTAssertEqual(spy.advances, [])
        XCTAssertFalse(spy.names.contains("widget_added"))
    }

    // MARK: - any × step goes away; done is terminal

    /// Row: any × the step view disappears → discarded, no status, no event; the next presentation
    /// starts at IDLE.
    /// RED CONTROL: `discard` leaving `sheet` set (onDismiss then reports a swipe).
    func testDiscardEmitsNothingAndANewPresentationStartsIdle() throws {
        let source = ImmediateWidgetSource([])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button())
        let had = attempt.sheet != nil
        attempt.discard()
        systemDismissedIfClosed(attempt, hadSheet: had)
        XCTAssertNil(attempt.sheet)
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_howto_shown"])
        XCTAssertEqual(spy.advances, [])
        XCTAssertEqual(attempt.phase, .idle)

        // DONE is terminal for the presentation; a new presentation starts at IDLE.
        attempt.tap(try Self.button())
        attempt.doneTapped()
        XCTAssertEqual(attempt.phase, .done)
        attempt.tap(try Self.button())
        XCTAssertEqual(spy.advances.count, 1, "a tap after DONE is ignored")
        attempt.configure(presentation: 2, hooks: spy.hooks())
        XCTAssertEqual(attempt.phase, .idle)
        attempt.tap(try Self.button())
        XCTAssertEqual(attempt.phase, .howto)
    }

    /// A button whose how-to is empty (authored before the field existed) ends the attempt as Done
    /// would — read, outcome, advance — with no sheet, no `widget_howto_shown` and no dismissal.
    /// RED CONTROL: `tap` presenting an empty how-to (the `howto.isEmpty` branch removed) shows a sheet.
    func testAnEmptyHowtoEndsTheAttemptWithoutASheet() throws {
        let source = ImmediateWidgetSource([])
        let (attempt, spy) = make(source: source)
        attempt.tap(try Self.button(howto: []))
        XCTAssertNil(attempt.sheet)
        XCTAssertEqual(source.reads, 2, "the tap's read and the Done-equivalent read")
        XCTAssertEqual(spy.names, ["widget_add_tapped", "widget_not_added"])
        XCTAssertEqual(spy.advances, [.notAdded])
        XCTAssertEqual(attempt.phase, .done)
    }

    // MARK: - The sheet's buttons

    /// Inside a sheet only Done (`next` / `continue`) and Close (`dismiss`) act; `link` and everything
    /// else is logged and ignored.
    /// RED CONTROL: `route` sending `link` to `.done` — the link button then ends the attempt.
    func testTheSheetIgnoresALinkButton() {
        XCTAssertEqual(BlockSheetView.route("next"), .done)
        XCTAssertEqual(BlockSheetView.route("continue"), .done)
        XCTAssertEqual(BlockSheetView.route("dismiss"), .close)
        for other in ["link", "add_widget", "refresh_step", "refresh", "skip", "permission", "nonsense"] {
            XCTAssertEqual(BlockSheetView.route(other), .ignored, other)
        }
        var done = 0, closed = 0
        let sheet = BlockSheetView(blocks: [], loc: nil, onDone: { done += 1 }, onClose: { closed += 1 })
        sheet.handle("link")
        XCTAssertEqual(done + closed, 0, "a link inside a sheet does nothing")
        sheet.handle("next")
        sheet.handle("dismiss")
        XCTAssertEqual([done, closed], [1, 1])
    }

    // MARK: - Decode

    /// `howto_blocks_ios` / `howto_blocks_android` decode as content blocks, at any depth; a child with
    /// no id gets one.
    /// RED CONTROL: the two decode lines removed — both lists come back nil.
    func testHowtoListsDecodeAsContentBlocks() throws {
        let json = #"""
        {"id":"row","type":"row","children":[
          {"type":"button","action":"add_widget","text":"Add",
           "howto_blocks_ios":[{"id":"i1","type":"heading","text":"iOS"},{"id":"i2","type":"button","action":"next","text":"Done"}],
           "howto_blocks_android":[{"id":"a1","type":"text","text":"Android"}]}]}
        """#
        let row = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        let child = try XCTUnwrap(row.children?.first)
        XCTAssertFalse(child.id.isEmpty, "an id-less child gets a decoder id")
        XCTAssertEqual(child.howto_blocks_ios?.map(\.id), ["i1", "i2"])
        XCTAssertEqual(child.howto_blocks_ios?.first?.type, .heading)
        XCTAssertEqual(child.howto_blocks_android?.map(\.id), ["a1"])
    }

    // MARK: - The extension probe, on real bundles

    /// An `.appex` whose extension point is WidgetKit's is found; another extension point, a missing
    /// Info.plist and an app with no PlugIns are not.
    /// RED CONTROL: matching any `.appex` (dropping the extension-point compare) finds the
    /// share extension.
    func testTheProbeFindsOnlyAWidgetKitExtension() throws {
        func app(_ appexes: [(name: String, point: String?)]) throws -> Bundle {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("probe-\(UUID().uuidString).app", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "ai.appdna.probe", "CFBundlePackageType": "APPL"] as NSDictionary)
                .write(to: root.appendingPathComponent("Info.plist"))
            for appex in appexes {
                let dir = root.appendingPathComponent("PlugIns/\(appex.name).appex", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let point = appex.point {
                    try (["NSExtension": ["NSExtensionPointIdentifier": point]] as NSDictionary)
                        .write(to: dir.appendingPathComponent("Info.plist"))
                }
            }
            return try XCTUnwrap(Bundle(url: root))
        }
        XCTAssertTrue(WidgetHostProbe(bundle: try app([("SampleWidgetExtension", "com.apple.widgetkit-extension")])).hasWidgetExtension())
        XCTAssertTrue(WidgetHostProbe(bundle: try app([
            ("Share", "com.apple.share-services"), ("SampleWidgetExtension", "com.apple.widgetkit-extension"),
        ])).hasWidgetExtension())
        XCTAssertFalse(WidgetHostProbe(bundle: try app([("Share", "com.apple.share-services")])).hasWidgetExtension())
        XCTAssertFalse(WidgetHostProbe(bundle: try app([("Broken", nil)])).hasWidgetExtension())
        XCTAssertFalse(WidgetHostProbe(bundle: try app([])).hasWidgetExtension())
    }

    /// The live source answers exactly once, on the main thread, within its bound — whatever
    /// WidgetKit does in a hostless test process.
    func testTheLiveSourceAnswersOnceWithinItsBound() {
        let done = expectation(description: "answered")
        var calls = 0
        let started = Date()
        WidgetCenterConfigurationsSource(timeout: 0.5).read { _ in
            XCTAssertTrue(Thread.isMainThread)
            calls += 1
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(calls, 1, "exactly once, even when the answer and the timeout both arrive")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}

final class WidgetBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Logs each read before handing it on.
struct ReadLogSource: WidgetConfigurationsSource {
    let inner: WidgetConfigurationsSource
    let onRead: () -> Void
    func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void) {
        onRead()
        inner.read(completion)
    }
}
