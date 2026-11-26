// StepViewDriverTests.swift
//
// Tests that OPERATE a real onboarding step view in a real key window: type into its UIKit text field,
// tap its rows and its Continue through the accessibility tree (automation enabled the way
// accessibility-snapshot tooling enables it), and read what the step hands on.
//
//   - advancing while a location resolve is in flight stores the TYPED text — through the form step's
//     Continue (`FormStepView`) and through a content-block step's button (`OnboardingStepRouter`);
//   - the step's Google credit is decided once per change of what the step draws, not once per body
//     pass (`GoogleCreditMemo`).
//
// Only the network is stubbed: a URLProtocol registered for the shared session answers the
// autocomplete with one synthetic row and holds every resolve open, so the tap's resolve is still in
// flight when Continue is tapped. All place data is synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

// MARK: - Driving a hosted SwiftUI view

/// Turns on the accessibility runtime so SwiftUI publishes its element tree to a hosted view, as the
/// accessibility-snapshot tools do; the tree is otherwise empty in a unit test.
///
/// 🔴 The switch is SIMULATOR-WIDE, not per process: it is `AutomationEnabled` in the simulator's
/// `com.apple.Accessibility` domain. Another process on the same simulator — an XCUITest runner opening
/// or closing its session — can turn it off in the middle of a test, and SwiftUI then stops publishing
/// the tree: every label read comes back `[]` and a render test fails as "no button for Continue".
/// Turning it on once per process was not enough, so it is re-asserted before every read
/// (`HostedStep.elements()`), and `enabled` re-asserts on every access.
enum A11yAutomation {
    private typealias SetEnabled = @convention(c) (Int32) -> Void
    private typealias GetEnabled = @convention(c) () -> UInt8
    private static let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
    private static let setter: SetEnabled? = lib.flatMap { dlsym($0, "_AXSSetAutomationEnabled") }
        .map { unsafeBitCast($0, to: SetEnabled.self) }
    private static let getter: GetEnabled? = lib.flatMap { dlsym($0, "_AXSAutomationEnabled") }
        .map { unsafeBitCast($0, to: GetEnabled.self) }

    /// How often a read found the switch OFF and turned it back on, in this process — named in the
    /// failure message, so an empty tree reads as what it is rather than as a render regression.
    static var timesFoundOff = 0

    /// The switch as this process sees it; nil when the runtime cannot be reached.
    static var isOn: Bool? { getter.map { $0() != 0 } }

    /// Turns the switch on (again). Returns false only when the runtime cannot be reached.
    @discardableResult
    static func ensure() -> Bool {
        guard let setter else { return false }
        setter(1)
        return true
    }

    /// Kept for the call sites that turn it on before hosting their own view. Re-asserts on every access.
    static var enabled: Bool { ensure() }
}

/// The one walk every render test reads a hosted view's accessibility tree with. Called on the main thread,
/// like every render test; not isolated, so a test class that is not `@MainActor` can call it as it walked before.
enum A11yTree {
    /// Every accessibility element under `roots`, depth first, each once — the tree as it is published right now,
    /// with no re-assert and no wait.
    static func raw(_ roots: [NSObject], maxDepth: Int = 60) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < maxDepth, seen.insert(ObjectIdentifier(o)).inserted else { return }
            out.append(o)
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } }
            }
            for e in o.accessibilityElements ?? [] { if let e = e as? NSObject { walk(e, depth + 1) } }
            if let v = o as? UIView { for s in v.subviews { walk(s, depth + 1) } }
        }
        roots.forEach { walk($0, 0) }
        return out
    }

    /// A tree with at least one label — what every hosted step publishes when the runtime is on.
    static func hasALabel(_ elements: [NSObject]) -> Bool { elements.contains { $0.accessibilityLabel != nil } }

    /// The tree under `roots`, read the way a test means to read it: the accessibility runtime is re-asserted first,
    /// and when `ready` does not hold — by default, no label at all — it is re-read for up to `timeout` while SwiftUI
    /// publishes the tree. Returns the last read either way; the caller's assertion judges it.
    ///
    /// Why the wait: on a shared simulator, a full-suite run once read EMPTY trees (`labels []`) in tests that pass
    /// alone. That has not been reproduced: not by turning the accessibility automation switch off in-process (the
    /// tree still published its labels), not with another XCUITest runner snapshotting the same simulator, not under
    /// heavy CPU load. So each read that is not ready prints `A11Y-NOT-READY` with the state that could explain it.
    static func read(_ roots: [NSObject], maxDepth: Int = 60, timeout: TimeInterval = 6,
                     until ready: ([NSObject]) -> Bool = A11yTree.hasALabel) -> [NSObject] {
        if A11yAutomation.isOn == false {
            A11yAutomation.timesFoundOff += 1
            // Another process turned the simulator-wide switch off: say so every time, so a run's log counts it.
            print("A11Y-SWITCH-FOUND-OFF before a read (\(A11yAutomation.timesFoundOff) in this process); turned back on")
        }
        A11yAutomation.ensure()
        var out = raw(roots, maxDepth: maxDepth)
        guard !ready(out) else { return out }
        let first = state(roots, out)
        let start = Date()
        let end = start.addingTimeInterval(timeout)
        while Date() < end {
            if A11yAutomation.isOn == false { A11yAutomation.timesFoundOff += 1 }
            A11yAutomation.ensure()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            out = raw(roots, maxDepth: maxDepth)
            if ready(out) { break }
        }
        // Every read that was not ready, with the state that could explain it — read by a person looking at a run on
        // a busy simulator, where another process can take the switch, the key window or the foreground.
        print("A11Y-NOT-READY first[\(first)] then[\(state(roots, out))] recovered=\(ready(out)) "
            + "after=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        return out
    }

    /// The state of the read: the switch, the hosting window (key, hidden), its scene, the app, and the tree's size.
    static func state(_ roots: [NSObject], _ elements: [NSObject]) -> String {
        let window = (roots.first as? UIView)?.window
        let scene = window?.windowScene.map { "\($0.activationState.rawValue)" } ?? "none"
        return "switch=\(A11yAutomation.isOn.map { $0 ? "on" : "OFF" } ?? "?") key=\(window?.isKeyWindow ?? false) "
            + "hidden=\(window?.isHidden ?? true) inWindow=\(window != nil) scene=\(scene) "
            + "app=\(UIApplication.shared.applicationState.rawValue) elements=\(elements.count) "
            + "labels=\(elements.filter { $0.accessibilityLabel != nil }.count)"
    }

    /// Says so when a read came back with no label, with the state of the read, so an empty tree does not read as a
    /// render regression; "" otherwise.
    static func diagnosis(_ elements: [NSObject], roots: [NSObject] = []) -> String {
        guard !hasALabel(elements) else { return "" }
        return " — the accessibility tree has NO label (\(state(roots, elements)); the switch was found off "
            + "\(A11yAutomation.timesFoundOff) time(s) in this process). A render that passes alone and reads empty here "
            + "is the hosting environment, not the view: see the A11Y-NOT-READY lines in the log"
    }
}

@MainActor
final class HostedStep {
    let host: UIViewController
    let window: UIWindow

    init<V: View>(_ view: V) {
        _ = A11yAutomation.enabled
        let host = UIHostingController(rootView: view.frame(width: 393, height: 852))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        self.host = host
        self.window = window
        spin(0.4)
    }

    func close() { window.isHidden = true }

    /// How long a lookup waits for the element it expects.
    static let lookupTimeout: TimeInterval = 8

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the run loop until `cond` holds, or `timeout` passes.
    @discardableResult
    func wait(_ timeout: TimeInterval = 4, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            spin(0.05)
        }
        return cond()
    }

    /// Every accessibility element under the host, depth first.
    ///
    /// Re-asserts the accessibility runtime first, and when the tree comes back with no label at all,
    /// waits, bounded, for SwiftUI to publish it. A hosted step always draws some text, so a tree
    /// with no label is never the answer a test means to read.
    func elements() -> [NSObject] { A11yTree.read([host.view]) }

    func labels() -> [String] { elements().compactMap(\.accessibilityLabel) }

    /// Names the cause when the tree is empty, so it does not read as a render regression.
    func treeDiagnosis() -> String { A11yTree.diagnosis(elements(), roots: [host.view]) }

    func has(label: String) -> Bool { labels().contains(label) }

    /// Taps the first element whose label satisfies `match` and that is a button.
    @discardableResult
    func tap(_ what: String, where match: (String) -> Bool) -> Bool {
        // wait for the button, not only for SOME label: on a loaded simulator the tree is published in parts, and
        // a tree with a heading but not yet its button is not the one this tap means to read.
        var hit: NSObject?
        let end = Date().addingTimeInterval(Self.lookupTimeout)
        while true {
            hit = elements().first(where: { e in
                guard let l = e.accessibilityLabel, match(l) else { return false }
                return e.accessibilityTraits.contains(.button)
            })
            if hit != nil || Date() >= end { break }
            spin(0.05)
        }
        guard let e = hit else {
            XCTFail("no button for \(what); labels: \(labels())\(treeDiagnosis())")
            return false
        }
        let ok = e.accessibilityActivate()
        spin(0.2)
        return ok
    }

    /// Types `text` into the first UIKit text field, as a keystroke does: the text, then the
    /// field's own `editingChanged` action.
    func type(_ text: String) {
        func find(_ v: UIView) -> UITextField? {
            if let tf = v as? UITextField { return tf }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let tf = find(host.view) else { return XCTFail("no text field") }
        tf.text = text
        // A package test runs with no UIApplication, so `sendActions` dispatches nothing: the field's
        // own editingChanged targets are invoked directly instead.
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
        spin(0.1)
    }
}

// MARK: - The geocoding stub

/// Answers the autocomplete with one synthetic Google row; holds every resolve OPEN (no reply), so a
/// tap's resolve stays in flight for as long as the test needs.
final class GeocodeStallingProxy: URLProtocol {
    static var autocompleteCalls = 0
    static var resolveCalls = 0
    static let row: [String: Any] = [
        "id": "ChIJ-synthetic-springfield", "provider": "google",
        "formatted_address": "Springfield, IL, USA", "city": "Springfield",
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("/geocode/") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasSuffix("/resolve") {
            Self.resolveCalls += 1
            return // held open
        }
        Self.autocompleteCalls += 1
        let body = try! JSONSerialization.data(withJSONObject: ["data": ["suggestions": [Self.row]]])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Advancing while a resolve is in flight

@MainActor
final class LocationAdvanceViewTests: XCTestCase {

    private var savedClient: APIClient?

    /// The field that registered with the step's settlement.
    private var registered: LocationSuggestionSearch?

    override func setUp() {
        super.setUp()
        registered = nil
        LocationAdvanceSettlement.registeredForTesting = { [weak self] _, holder in self?.registered = holder }
        GeocodeStallingProxy.autocompleteCalls = 0
        GeocodeStallingProxy.resolveCalls = 0
        URLProtocol.registerClass(GeocodeStallingProxy.self)
        savedClient = AppDNA.apiClientForTesting
        AppDNA.apiClientForTesting = APIClient(apiKey: "synthetic-key", environment: .production)
    }

    override func tearDown() {
        LocationAdvanceSettlement.registeredForTesting = nil
        AppDNA.apiClientForTesting = savedClient
        URLProtocol.unregisterClass(GeocodeStallingProxy.self)
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    /// Types into the field, waits for the Google row the stubbed autocomplete lists, and taps it, so
    /// its resolve is held open; then taps Continue.
    ///
    /// The row is tapped through the accessibility tree where it is reachable (a field in the step's
    /// pinned zone). A field inside the step's scroll view is not published to the tree in a package
    /// test, so its row is tapped through the field's own holder — `select(at:)`, the call the row's
    /// button makes — reached through the step's settlement as the field registers. Continue is always
    /// a real tap.
    private func typeTapAndContinue(_ step: HostedStep, holder: () -> LocationSuggestionSearch?) {
        step.type("Springf")
        XCTAssertTrue(step.wait { GeocodeStallingProxy.autocompleteCalls == 1 && (holder()?.results.isEmpty == false) },
                      "the stubbed autocomplete listed the row")
        if step.labels().contains(where: { $0.contains("Springfield") }) {
            print("[advance] the row: a real tap")
            step.tap("the Google row") { $0.contains("Springfield") }
        } else {
            print("[advance] the row: the holder's select(at: 0)")
            holder()?.select(at: 0)
            step.spin(0.2)
        }
        XCTAssertTrue(step.wait { GeocodeStallingProxy.resolveCalls == 1 }, "the tap sent its resolve")
        XCTAssertEqual(holder()?.isResolving, true, "the resolve is in flight")
        step.tap("Continue") { $0 == "Continue" }
    }

    private func router(_ json: String, onNext: @escaping ([String: Any]?) -> Void) throws -> OnboardingStepRouter {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        return OnboardingStepRouter(step: step, onNext: onNext, onSkip: {})
    }

    /// The legacy FORM step: an optional Location field, a Google row tapped, and Continue tapped while
    /// its resolve is still in flight. The step hands on the typed text.
    /// RED CONTROL: `FormStepView.handleSubmit` without `locationSettlement.settleInto` hands on no
    /// answer for the field.
    func testTheFormStepsContinueMidResolveStoresTheTypedText() throws {
        var payloads: [[String: Any]?] = []
        let view = try router(
            #"{"id":"where","type":"form","config":{"title":"Where?","fields":[{"id":"home","type":"location","label":"Home","required":false}]}}"#,
            onNext: { payloads.append($0) }
        )
        let step = HostedStep(view)
        defer { step.close() }
        typeTapAndContinue(step, holder: { registered })
        XCTAssertTrue(step.wait { !payloads.isEmpty }, "Continue advanced the step")
        XCTAssertEqual(payloads.first??["home"] as? String, "Springf", "the typed text is the answer")
        XCTAssertEqual(GeocodeStallingProxy.resolveCalls, 1, "control: the resolve was in flight, never answered")
    }

    /// A content-block step: an optional `input_location` and a Continue button, both in the step's
    /// pinned bottom zone, so the row and Continue are both real taps. The same.
    /// RED CONTROL: `OnboardingStepRouter.onNext` without `locationSettlement.settleInto` hands on no
    /// answer for the field.
    func testABlockStepsContinueMidResolveStoresTheTypedText() throws {
        var payloads: [[String: Any]?] = []
        let view = try router(
            #"{"id":"where","type":"custom","config":{"content_blocks":[{"id":"loc","type":"input_location","field_id":"home","zone":"bottom"},{"id":"go","type":"button","text":"Continue","action":"next","zone":"bottom"}]}}"#,
            onNext: { payloads.append($0) }
        )
        let step = HostedStep(view)
        defer { step.close() }
        typeTapAndContinue(step, holder: { registered })
        XCTAssertTrue(step.wait { !payloads.isEmpty }, "Continue advanced the step")
        XCTAssertEqual(payloads.first??["home"] as? String, "Springf", "the typed text is the answer")
        XCTAssertEqual(GeocodeStallingProxy.resolveCalls, 1, "control: the resolve was in flight, never answered")
    }
}

// MARK: - The credit is decided once per change of what the step draws

@MainActor
final class GoogleCreditMemoViewTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    /// The router re-renders on every published change of its interaction store (and on every
    /// keystroke). With a Google answer held, each of those body passes used to encode the whole
    /// step; now the step is encoded once, and the credit is still drawn.
    /// RED CONTROL: the router calling `GoogleCredit.shows(step:…)` directly encodes once per pass.
    func testBodyPassesDoNotReEncodeTheStep() throws {
        let home = GoogleAttributionData.google
        SessionDataStore.shared.setOnboardingResponses(["places": ["home": home]])
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            #"{"id":"c","type":"custom","config":{"content_blocks":[{"id":"t","type":"text","text":"Welcome from {{responses.places.home.city}}"}]}}"#.utf8
        ))
        let store = HostDataInteractionStore()
        let view = OnboardingStepRouter(step: step, onNext: { _ in }, onSkip: {},
                                        accumulatedResponses: ["places": ["home": home]], interactionStore: store)
        let hosted = HostedStep(view)
        defer { hosted.close() }
        XCTAssertTrue(hosted.wait { hosted.has(label: GoogleMapsAttribution.label) }, "the credit is drawn")
        let before = GoogleCredit.sourcesBuilt
        for _ in 0..<5 {
            store.objectWillChange.send()
            hosted.spin(0.1)
        }
        XCTAssertEqual(GoogleCredit.sourcesBuilt - before, 0, "five body passes, no new encode of the step")
        XCTAssertTrue(hosted.has(label: GoogleMapsAttribution.label), "the credit is still drawn")
    }

    /// The memo: a keystroke into a field holding no Google answer reuses the sources and the answer;
    /// a Google answer that moves re-walks; a changed patch re-encodes.
    func testTheMemoRebuildsOnlyWhatChanged() throws {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            #"{"id":"c","type":"custom","config":{"content_blocks":[{"id":"t","type":"text","text":"Hi {{responses.places.home.city}}"},{"id":"sel","type":"input_select","field_id":"pick","field_options":[{"id":"a","label":"A"}]}]}}"#.utf8
        ))
        let memo = GoogleCreditMemo()
        func shows(inputs: [String: Any], accumulated: [String: Any], patches: [String: [String: Any]] = [:]) -> Bool {
            memo.shows(step: step, override: nil, fieldConfigOverrides: patches, fieldOptionsOverrides: [:],
                       answers: GoogleCredit.Answers(accumulated: accumulated, stepInputs: inputs, sessionStore: [:]))
        }
        let google = ["places": ["home": GoogleAttributionData.google]]
        let start = GoogleCredit.sourcesBuilt
        XCTAssertTrue(shows(inputs: ["nick": "A"], accumulated: google))
        XCTAssertTrue(shows(inputs: ["nick": "Ab"], accumulated: google))
        XCTAssertEqual(GoogleCredit.sourcesBuilt - start, 1, "a keystroke reuses the sources")
        XCTAssertFalse(shows(inputs: [:], accumulated: ["places": ["work": GoogleAttributionData.google]]),
                       "the Google answer moved where no token reads it: re-walked, no credit")
        XCTAssertFalse(shows(inputs: [:], accumulated: [:]), "no Google answer: no credit")
        XCTAssertTrue(shows(inputs: [:], accumulated: google, patches: ["sel": ["search_placeholder": "x"]]))
        XCTAssertEqual(GoogleCredit.sourcesBuilt - start, 2, "a new patch re-encodes")
    }
}

// MARK: - The colour behind the step credit

final class GoogleAttributionStepBackdropTests: XCTestCase {

    /// The step credit is drawn on what the flow host draws: a chat step is dark whatever the
    /// appearance, so its credit is white. RED CONTROL: deciding from the step's `background` alone
    /// (nil on a chat step) gives the system background, which is light in a light appearance.
    func testAChatStepsCreditIsDecidedByTheChatFill() throws {
        typealias A = GoogleMapsAttribution
        let chat = try JSONDecoder().decode(OnboardingStep.self, from: Data(#"{"id":"chat","type":"interactive_chat","config":{}}"#.utf8))
        XCTAssertEqual(A.backdrop(ofStep: chat.config, type: chat.type), .plain(hex: "#0F172A"))
        XCTAssertEqual(A.variant(on: A.backdrop(ofStep: chat.config, type: chat.type), darkAppearance: false), .white)
        let styled = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            ##"{"id":"chat2","type":"interactive_chat","config":{"chat_config":{"style":{"background_color":"#FAFAFA"}}}}"##.utf8
        ))
        XCTAssertEqual(A.variant(on: A.backdrop(ofStep: styled.config, type: styled.type), darkAppearance: true), .gray)
        let plain = try JSONDecoder().decode(OnboardingStep.self, from: Data(#"{"id":"w","type":"welcome","config":{"title":"Hi"}}"#.utf8))
        XCTAssertEqual(A.backdrop(ofStep: plain.config, type: plain.type), .plain(hex: nil), "the system background follows the appearance")
        let coloured = try JSONDecoder().decode(OnboardingStep.self, from: Data(
            ##"{"id":"w2","type":"welcome","config":{"title":"Hi","background":{"type":"color","color":"#101828"}}}"##.utf8
        ))
        XCTAssertEqual(A.variant(on: A.backdrop(ofStep: coloured.config, type: coloured.type), darkAppearance: false), .white)
    }

    /// A Screen's field logo is drawn on the screen's own fill, or its section's: an authored dark
    /// screen is dark in a light appearance. RED CONTROL: a Screen decided from the system background
    /// (`backdrop(ofScreen:)` answering `.plain(hex: nil)`, the default every Screen had) gives the
    /// gray logo on a dark screen.
    func testAScreensLogoIsDecidedByTheScreenAndSectionFill() throws {
        typealias A = GoogleMapsAttribution
        func screen(_ json: String) throws -> BackgroundConfig {
            try JSONDecoder().decode(BackgroundConfig.self, from: Data(json.utf8))
        }
        func section(_ json: String) throws -> SectionStyle {
            try JSONDecoder().decode(SectionStyle.self, from: Data(json.utf8))
        }
        let dark = A.backdrop(ofScreen: try screen(##"{"type":"solid","color":"#101828"}"##))
        XCTAssertEqual(A.variant(on: dark, darkAppearance: false), .white)
        XCTAssertEqual(A.backdrop(ofScreen: try screen(##"{"type":"gradient","gradient":{"start":"#000000","end":"#FFFFFF"}}"##)), .busy)
        XCTAssertEqual(A.backdrop(ofScreen: try screen(##"{"type":"solid","color":"#FFFFFF","opacity":0.5}"##)), .busy)
        XCTAssertEqual(A.backdrop(ofScreen: nil), .plain(hex: nil))
        let light = A.backdrop(ofSection: try section(##"{"background_color":"#FFFFFF"}"##), behind: dark)
        XCTAssertEqual(A.variant(on: light, darkAppearance: true), .gray, "the section's own fill decides")
        XCTAssertEqual(A.backdrop(ofSection: try section("{}"), behind: dark), dark, "no fill: what is behind")
    }
}
