import XCTest

/**
 SPEC-507 §8.1 / §8.2 — the location-field device walks, screen by screen.

 The flow is synthetic (one location `type` per step, block and form-step surfaces): city block,
 address block, region block, address form step, country form step, a done step. Each method walks
 it, writes a frame per screen to the Mac's /tmp (`spec507-<run>-<nn>-<name>.png`), and logs the
 stored answer twice: `getLocationData` for `-appdnaLocationField`, and the raw responses bucket.
 Queries are public place names only (Rule 11).
 */
final class Spec507LocationWalkUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var flowId: String? { TestCredentials.locationFlowId.isEmpty ? nil : TestCredentials.locationFlowId }
    private var run = "x"
    private var n = 0

    /// An address query whose list holds an interpolated address, and the edit whose own fresh search
    /// does not list it (checked against the proxy before the walk).
    private static let addrQuery = "Rua Augusta 150"
    private static let addrTarget = "Almonte"
    private static let addrEdit = "9"

    // MARK: - walks

    /// §8.1 — a released build against the P1 server, Mapbox app: suggestions show, a tap stores and shows.
    func testP1Mapbox() throws {
        let app = try start("p1mbx", field: "w_city_blk")
        typeAndTap(app, "Porto", row: "Porto", tag: "city")
        advance(app, to: "Walk address block")
        advance(app, to: "Walk region block")
        advance(app, to: "Walk address form")
        advance(app, to: "Walk country form")
        typeAndTap(app, "Portugal", row: "Portugal", tag: "country-form")
        advance(app, to: "Walk done")
        finish(app)
    }

    /// §8.1 — a released build against the P1 server, Google app: no suggestions, the typed text is stored.
    func testP1Google() throws {
        let app = try start("p1ggl", field: "w_city_blk")
        let f = field(app)
        type("Porto", into: f, in: app)
        Thread.sleep(forTimeInterval: 6)
        shot(app, "city-typed-no-list")
        // 1.0.83's content block searches Apple MapKit on the device (spec §1), not our proxy: observed, not asserted.
        let rows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Portugal")).count
        NSLog("[spec507] google: block rows naming Portugal after 6s = \(rows); field=\(value(f))")
        advance(app, to: "Walk address block")
        advance(app, to: "Walk region block")
        advance(app, to: "Walk address form")
        advance(app, to: "Walk country form")
        // The form step's field searches through our proxy: a Google app gets no suggestions.
        let ff = field(app)
        type("Portugal", into: ff, in: app)
        Thread.sleep(forTimeInterval: 6)
        shot(app, "country-form-typed-no-list")
        let formRows = app.staticTexts.matching(NSPredicate(format: "label == %@", "Portugal")).count
        NSLog("[spec507] google: form-step rows labelled Portugal after 6s = \(formRows); field=\(value(ff))")
        XCTAssertEqual(formRows, 0, "a Google app showed proxy suggestions to a released build")
        advance(app, to: "Walk done")
        finish(app)
    }

    /// §8.2 (a)(b)(c) and (e) spinner timing — the on-branch build against a resolving server.
    func testP2Resolve() throws {
        let app = try start("p2", field: "w_addr_blk")
        // (a) city block
        let city = typeAndTap(app, "Porto", row: "Porto", tag: "a-city", burst: true)
        advance(app, to: "Walk address block")
        back(app, to: "Walk city block")
        checkShown(app, city, tag: "a-city-back")
        advance(app, to: "Walk address block")
        // (b) address block, stale-list tap
        let addr = staleTap(app, tag: "b-addr")
        advance(app, to: "Walk region block")
        back(app, to: "Walk address block")
        checkShown(app, addr, tag: "b-addr-back")
        advance(app, to: "Walk region block")
        // (c) region block
        let region = typeAndTap(app, "Californ", row: "California", tag: "c-region")
        advance(app, to: "Walk address form")
        back(app, to: "Walk region block")
        checkShown(app, region, tag: "c-region-back")
        advance(app, to: "Walk address form")
        // (b) address form step
        let addrForm = staleTap(app, tag: "b-addr-form")
        advance(app, to: "Walk country form")
        back(app, to: "Walk address form")
        checkShown(app, addrForm, tag: "b-addr-form-back")
        advance(app, to: "Walk country form")
        // (c) country form step
        let country = typeAndTap(app, "Portug", row: "Portugal", tag: "c-country-form", burst: true)
        advance(app, to: "Walk done")
        back(app, to: "Walk country form")
        checkShown(app, country, tag: "c-country-form-back")
        advance(app, to: "Walk done")
        finish(app)
        // iOS has no in-flow resume (§3.9): a relaunch is checked through getLocationData only.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        readback(app, tag: "relaunch")
    }

    /// §8.2 (e) — the deferred notes on #1147: the spinner during the debounce; an optional field's
    /// Continue while its resolve is in flight (the walker's proxy holds a "Lisbo" resolve 4 s); and the
    /// dropdown after a stale-list tap once the held fresh reply lands.
    func testP2ContinueDuringResolve() throws {
        let app = try start("p2e", field: "w_city_blk")
        let f = field(app)
        for _ in 0..<5 { f.tap(); if app.keyboards.element.waitForExistence(timeout: 3) { break } }
        f.typeText("Lisbo")
        for i in 0..<5 { shot(app, "typing+\(i)") }
        let r = row(app, "Lisbon")
        XCTAssertTrue(r.waitForExistence(timeout: 20), "no Lisbon row")
        shot(app, "list")
        r.tap()
        shot(app, "tap+0")
        app.buttons["Next"].firstMatch.tap()
        shot(app, "after-next")
        let advanced = app.staticTexts["Walk address block"].waitForExistence(timeout: 3)
        NSLog("[spec507] p2e: advanced with the resolve in flight = \(advanced)")
        Thread.sleep(forTimeInterval: 5)
        shot(app, "after-held-reply")
        if advanced {
            back(app, to: "Walk city block")
            Thread.sleep(forTimeInterval: 1)
            shot(app, "back-on-city")
            NSLog("[spec507] p2e: city field after back = \(value(field(app)))")
            advance(app, to: "Walk address block")
        } else {
            NSLog("[spec507] p2e: still on city, field = \(value(f))")
            advance(app, to: "Walk address block")
        }
        let addr = staleTap(app, tag: "e-addr-held", settle: 8)
        NSLog("[spec507] p2e: address after the held fresh reply landed = \(addr)")
        advance(app, to: "Walk region block")
        advance(app, to: "Walk address form")
        advance(app, to: "Walk country form")
        advance(app, to: "Walk done")
        finish(app)
    }

    /// §8.2 (d) — a refused resolve: the typed text is stored and shown.
    func testP2Refused() throws {
        let app = try start("p2d", field: "w_city_blk")
        let f = field(app)
        type("Porto", into: f, in: app)
        let r = row(app, "Porto")
        XCTAssertTrue(r.waitForExistence(timeout: 20), "no Porto row")
        shot(app, "list")
        // The walker swaps the app's key for an invalid one now (the list is already drawn), then
        // creates /tmp/spec507-go on the Mac, so the tap's resolve is refused by the provider.
        try? FileManager.default.createDirectory(atPath: "/tmp", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "/tmp/spec507-ready", contents: Data())
        var waited = 0
        while !FileManager.default.fileExists(atPath: "/tmp/spec507-go") && waited < 240 { Thread.sleep(forTimeInterval: 1); waited += 1 }
        NSLog("[spec507] p2d: go signal after \(waited)s")
        shot(app, "list-before-tap")
        r.tap()
        for i in 0..<4 { Thread.sleep(forTimeInterval: 0.5); shot(app, "after-tap-\(i)") }
        NSLog("[spec507] p2d: field after a refused resolve = \(value(f))")
        advance(app, to: "Walk address block")
        back(app, to: "Walk city block")
        shot(app, "back")
        NSLog("[spec507] p2d: field after back = \(value(field(app)))")
        advance(app, to: "Walk address block")
        advance(app, to: "Walk region block")
        advance(app, to: "Walk address form")
        advance(app, to: "Walk country form")
        advance(app, to: "Walk done")
        finish(app)
    }

    // MARK: - legs

    @discardableResult
    private func typeAndTap(_ app: XCUIApplication, _ q: String, row title: String, tag: String, burst: Bool = false) -> String {
        let f = field(app)
        type(q, into: f, in: app)
        let r = row(app, title)
        XCTAssertTrue(r.waitForExistence(timeout: 20), "[\(tag)] no row \(title)")
        logRows(app, tag)
        shot(app, "\(tag)-list")
        let before = value(f)
        r.tap()
        if burst { for i in 0..<4 { shot(app, "\(tag)-tap+\(i)") } }
        let after = waitChange(f, from: before)
        Thread.sleep(forTimeInterval: 1)
        shot(app, "\(tag)-tapped")
        let open = row(app, title).exists
        NSLog("[spec507] \(tag): field before=\(before) after=\(after) dropdown-still-open=\(open)")
        return after
    }

    /// Type the address query, wait for the interpolated target, edit the text while the list is
    /// shown, and tap the target's row at its old position before the fresh search lands.
    private func staleTap(_ app: XCUIApplication, tag: String, settle: Double = 2) -> String {
        let f = field(app)
        type(Self.addrQuery, into: f, in: app)
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", Self.addrTarget)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 20), "[\(tag)] no row naming \(Self.addrTarget)")
        logRows(app, tag)
        shot(app, "\(tag)-list")
        let frame = target.frame
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        f.typeText(Self.addrEdit)
        point.tap()
        shot(app, "\(tag)-tap+0")
        let after = waitChange(f, from: Self.addrQuery + Self.addrEdit)
        Thread.sleep(forTimeInterval: settle)
        shot(app, "\(tag)-tapped")
        let open = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Brazil")).count
            + app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Canada")).count
        NSLog("[spec507] \(tag): field after stale tap=\(after); rows still drawn (Brazil/Canada)=\(open)")
        return after
    }

    private func checkShown(_ app: XCUIApplication, _ expected: String, tag: String) {
        Thread.sleep(forTimeInterval: 1)
        shot(app, tag)
        let shown = value(field(app))
        NSLog("[spec507] \(tag): field on re-entry=\(shown) expected=\(expected)")
        XCTAssertEqual(shown, expected, "[\(tag)] the field does not show the resolved line on re-entry")
    }

    // MARK: - plumbing

    private func start(_ runName: String, field fieldId: String) throws -> XCUIApplication {
        guard let apiKey, let flowId else { throw XCTSkip("run via scripts/sdk-host-ios.ts --uitest --location-flow <id>") }
        run = runName
        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey, "-appdnaFlow", flowId, "-appdnaLocationField", fieldId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        var presented = false
        for _ in 0..<12 where !presented {
            app.buttons["host.onboarding"].tap()
            presented = app.staticTexts["Walk city block"].waitForExistence(timeout: 5)
        }
        guard presented else {
            let drawn = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex).map(\.label).prefix(30)
            XCTFail("the flow never presented. On screen: \(Array(drawn))")
            throw XCTSkip("not presented")
        }
        shot(app, "city-block")
        return app
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let f = app.textFields.firstMatch
        XCTAssertTrue(f.waitForExistence(timeout: 10), "the step has no text field")
        return f
    }

    private func value(_ f: XCUIElement) -> String { (f.value as? String) ?? "" }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    private func logRows(_ app: XCUIApplication, _ tag: String) {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        NSLog("[spec507] \(tag): drawn texts = \(labels)")
    }

    private func waitChange(_ f: XCUIElement, from before: String) -> String {
        var v = value(f)
        for _ in 0..<40 where v == before { Thread.sleep(forTimeInterval: 0.25); v = value(f) }
        return v
    }

    private func advance(_ app: XCUIApplication, to heading: String) {
        for label in ["Next", "Continue", "Finish"] where app.buttons[label].exists {
            app.buttons[label].firstMatch.tap(); break
        }
        let ok = app.staticTexts[heading].waitForExistence(timeout: 15)
        XCTAssertTrue(ok, "did not reach \(heading)")
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, heading.replacingOccurrences(of: " ", with: "-"))
    }

    private func back(_ app: XCUIApplication, to heading: String) {
        let candidates = ["Back", "chevron.left", "Go back", "Previous"].map { app.buttons[$0] }
        if let b = candidates.first(where: { $0.exists }) { b.tap() } else {
            NSLog("[spec507] no Back button by label; buttons = \(app.buttons.allElementsBoundByIndex.map(\.label))")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.10)).tap()
        }
        XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 10), "Back did not return to \(heading)")
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func finish(_ app: XCUIApplication) {
        app.buttons["Finish"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20), "the flow did not complete")
        Thread.sleep(forTimeInterval: 2)
        shot(app, "host-after-finish")
        // Background the app so the SDK flushes its event queue (the completion event), then come back.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 10)
        app.activate()
        Thread.sleep(forTimeInterval: 5)
        readback(app, tag: "after-finish")
    }

    private func readback(_ app: XCUIApplication, tag: String) {
        let ld = app.staticTexts["host.locationData"]
        let raw = app.staticTexts["host.responsesRaw"]
        _ = raw.waitForExistence(timeout: 10)
        for _ in 0..<20 where raw.label.contains("no bucket") || raw.label.contains("not read") {
            Thread.sleep(forTimeInterval: 0.5)
        }
        NSLog("[spec507] \(run) \(tag) getLocationData: \(ld.label)")
        NSLog("[spec507] \(run) \(tag) RAW: \(raw.label)")
    }

    private func type(_ text: String, into f: XCUIElement, in app: XCUIApplication) {
        for attempt in 1...4 {
            for _ in 0..<5 { f.tap(); if app.keyboards.element.waitForExistence(timeout: 3) { break } }
            if attempt > 1 {
                // Clear what a previous attempt left, so a retry never doubles the text.
                let left = value(f).count
                if left > 0 { f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left)) }
            }
            f.typeText(text)
            // The field's value can lag the keystrokes: poll before deciding the text did not land.
            for _ in 0..<8 { if value(f).localizedCaseInsensitiveContains(text) { return }; Thread.sleep(forTimeInterval: 0.25) }
            NSLog("[spec507] typing attempt \(attempt) did not land: field=\(value(f))")
        }
        XCTFail("could not type \(text)")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        n += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? png.write(to: URL(fileURLWithPath: String(format: "/tmp/spec507-%@-%02d-%@.png", run, n, name)))
    }
}
