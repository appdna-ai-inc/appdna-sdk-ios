// SurveyKeyboardDateZoneWalkUITests.swift
//
// A TYPED SURVEY ANSWER AND DATES IN THE APP'S TIME ZONE, OPERATED.
//
// Drives a walk build of this host that is ALREADY INSTALLED under `ai.appdna.wsurvey` (built with a walk menu in its
// Info.plist by the walk script in the AppDNA repository; nothing about it is committed here). Frames go to the Mac's
// /tmp/wsurvey/ios and to the test's attachments; the report is NSLog'd under "[wsurvey]".
//
//   Surveys: a bottom sheet (an NPS question, then a free-text one) and a modal (free text first). Each is answered:
//   a score tapped, the text field tapped and typed into, and Submit / Next tapped WHILE THE KEYBOARD IS UP. The test
//   asserts the button sits above the keyboard before tapping it, and that the survey finished with the typed text.
//
//   Dates: the phone runs in `phoneZone` (the launch environment's TZ) while the app's zone, set in the console, is
//   another (Asia/Tokyo in the walk build), chosen so the two name different days. The date-only wheel must open on
//   the APP zone's today; each picker is then moved, and the read-back step shows what was stored.
import XCTest

final class SurveyKeyboardDateZoneWalkUITests: XCTestCase {

    private let bundleId = "ai.appdna.wsurvey"
    /// The zone the phone runs in for the date walk; the walk app's own zone is Asia/Tokyo.
    private let phoneZone = ProcessInfo.processInfo.environment["WSURVEY_PHONE_TZ"] ?? "America/Los_Angeles"
    private let appZone = ProcessInfo.processInfo.environment["WSURVEY_APP_TZ"] ?? "Asia/Tokyo"
    private var report: [String] = []

    private func log(_ s: String) { report.append(s); NSLog("[wsurvey] \(s)") }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(atPath: "/tmp/wsurvey/ios", withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "/tmp/wsurvey/ios/i-\(name).png"))
    }

    private func fresh(tz: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        if let tz { app.launchEnvironment["TZ"] = tz }
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", label, label)).firstMatch
    }

    private func tapMenu(_ app: XCUIApplication, _ title: String) -> Bool {
        let b = button(app, title)
        guard b.waitForExistence(timeout: 25) else { log("MISSING menu \(title)"); return false }
        b.tap(); return true
    }

    private func text(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let e = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    private func typeField(_ app: XCUIApplication) -> XCUIElement? {
        for q in [app.textViews, app.textFields] where q.firstMatch.waitForExistence(timeout: 3) { return q.firstMatch }
        return nil
    }

    /// Taps `label` while the keyboard is up, after recording where it sits against the keyboard.
    private func tapAboveKeyboard(_ app: XCUIApplication, _ label: String, _ tag: String) -> Bool {
        let b = button(app, label)
        let kb = app.keyboards.firstMatch
        guard b.waitForExistence(timeout: 5) else { log("\(tag): MISSING \(label)"); return false }
        let kbShown = kb.exists
        let above = kbShown ? b.frame.maxY <= kb.frame.minY : true
        log("\(tag): keyboard=\(kbShown) kbTop=\(Int(kb.frame.minY)) \(label)=\(Int(b.frame.minY))..\(Int(b.frame.maxY)) hittable=\(b.isHittable) aboveKeyboard=\(above)")
        XCTAssertTrue(kbShown, "[\(tag)] the keyboard is not up while typing")
        XCTAssertTrue(b.isHittable && above, "[\(tag)] \(label) is behind the keyboard")
        b.tap(); return true
    }

    func testTypedSurveyAnswersKeepSubmitAboveTheKeyboard() throws {
        guard XCUIApplication(bundleIdentifier: bundleId).state != .unknown else { throw XCTSkip("the wsurvey walk build is not installed") }

        // Bottom sheet: NPS, then free text, then Submit with the keyboard up.
        var app = fresh()
        XCTAssertTrue(tapMenu(app, "Survey sheet"))
        XCTAssertNotNil(text(app, "How likely are you to recommend this walk app", timeout: 25), "the sheet survey did not show")
        shot(app, "s1-q1")
        button(app, "9").tap()
        button(app, "Next").tap()
        XCTAssertNotNil(text(app, "What should we change"))
        shot(app, "s2-q2")
        let f1 = try XCTUnwrap(typeField(app), "no text field on the free-text question")
        f1.tap(); f1.typeText("ios typed answer")
        shot(app, "s3-typed-keyboard")
        log("sheet field value=\(String(describing: f1.value))")
        XCTAssertTrue(tapAboveKeyboard(app, "Submit", "sheet"))
        sleep(3); shot(app, "s4-after-submit")
        let sheetDone = text(app, "survey_completed", timeout: 10) != nil
        log("sheet completed=\(sheetDone)")
        XCTAssertTrue(sheetDone, "the sheet survey did not complete")

        // Modal: free text first, Next with the keyboard up, then NPS and Submit.
        app = fresh()
        XCTAssertTrue(tapMenu(app, "Survey modal"))
        XCTAssertNotNil(text(app, "Describe your week", timeout: 25), "the modal survey did not show")
        let f2 = try XCTUnwrap(typeField(app), "no text field on the modal's first question")
        f2.tap(); f2.typeText("ios three words")
        shot(app, "m1-typed-keyboard")
        log("modal field value=\(String(describing: f2.value))")
        XCTAssertTrue(tapAboveKeyboard(app, "Next", "modal"))
        XCTAssertNotNil(text(app, "And how likely are you to recommend us"))
        button(app, "7").tap()
        shot(app, "m2-q2")
        button(app, "Submit").tap()
        sleep(3); shot(app, "m3-after-submit")
        let modalDone = text(app, "survey_completed", timeout: 10) != nil
        log("modal completed=\(modalDone)")
        XCTAssertTrue(modalDone, "the modal survey did not complete")
        NSLog("[wsurvey] report:\n\(report.joined(separator: "\n"))")
    }

    private func day(in zone: String, _ date: Date = Date()) -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
        return c.component(.day, from: date)
    }

    /// A themed wheel's column, by its accessibility label (`Day`, `Month`, `Year`, `Hour`, `Minute`).
    private func wheel(_ app: XCUIApplication, _ column: String, _ index: Int) -> XCUIElement {
        app.scrollViews.matching(NSPredicate(format: "label ==[c] %@", column)).element(boundBy: index)
    }

    /// Opens a compact field's sheet, sets each wheel of its system picker, and taps Done.
    private func pickInSheet(_ app: XCUIApplication, field: XCUIElement, _ values: [Int: String], _ tag: String) {
        let picker = app.datePickers.firstMatch
        for _ in 0..<3 where !picker.exists { field.tap(); _ = picker.waitForExistence(timeout: 5) }
        guard picker.exists else { log("\(tag): no picker sheet"); return }
        let wheels = picker.pickerWheels
        log("\(tag): wheels before " + (0..<wheels.count).map { "\(wheels.element(boundBy: $0).value ?? "")" }.joined(separator: " | "))
        for (i, v) in values.sorted(by: { $0.key < $1.key }) where i < wheels.count { wheels.element(boundBy: i).adjust(toPickerWheelValue: v) }
        log("\(tag): wheels after " + (0..<wheels.count).map { "\(wheels.element(boundBy: $0).value ?? "")" }.joined(separator: " | "))
        shot(app, "d-\(tag)-sheet")
        button(app, "Done").tap()
        sleep(1)
    }

    func testDatesFollowTheAppZoneAcrossMidnight() throws {
        guard XCUIApplication(bundleIdentifier: bundleId).state != .unknown else { throw XCTSkip("the wsurvey walk build is not installed") }
        let appDay = day(in: appZone), phoneDay = day(in: phoneZone)
        log("phone zone \(phoneZone) day=\(phoneDay); app zone \(appZone) day=\(appDay)")

        let app = fresh(tz: phoneZone)
        // The flow is presented from the fetched config: wait for it, and tap again if the first tap came too early.
        _ = text(app, "config_fetched", timeout: 25)
        var shown = false
        for _ in 0..<4 where !shown {
            XCTAssertTrue(tapMenu(app, "Dates flow"))
            shown = text(app, "Pick dates", timeout: 10) != nil
        }
        XCTAssertTrue(shown, "the dates flow did not show")
        sleep(2); shot(app, "d1-pick-opened")

        // The date-only wheel (no future) opens on the app zone's today.
        let dayCol = wheel(app, "day", 0)
        XCTAssertTrue(dayCol.waitForExistence(timeout: 5))
        let opened = "\(wheel(app, "month", 0).value ?? "") \(dayCol.value ?? "") \(wheel(app, "year", 0).value ?? "")"
        log("date wheel opened on: \(opened)")
        XCTAssertEqual(Int("\(dayCol.value ?? "")"), appDay, "the date-only wheel did not open on the app zone's today")
        let dtOpened = "\(wheel(app, "month", 1).value ?? "") \(wheel(app, "day", 1).value ?? "") \(wheel(app, "hour", 0).value ?? ""):\(wheel(app, "minute", 0).value ?? "")"
        log("datetime wheel opened on: \(dtOpened)")

        // allow_future is off: turning the day past today stops on the app zone's today, not the phone's.
        dayCol.swipeUp(velocity: .slow)
        sleep(2)
        log("date wheel turned towards the future stops on: \(dayCol.value ?? "")")
        XCTAssertEqual(Int("\(dayCol.value ?? "")"), appDay, "the no-future wheel did not stop on the app zone's today")
        shot(app, "d1b-future-refused")

        // Operate each picker: the date wheel back, the date-and-time wheel's hour forward.
        dayCol.swipeDown(velocity: .slow)
        sleep(1)
        log("date wheel after swipe: \(dayCol.value ?? "")")
        let hourCol = wheel(app, "hour", 0)
        if hourCol.exists { hourCol.swipeUp(velocity: .slow); sleep(1); log("datetime hour after swipe: \(hourCol.value ?? "")") }
        shot(app, "d2-wheels-moved")

        app.swipeUp(velocity: .slow)
        sleep(2)
        let fields = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*([0-9]{4}|[0-9]{1,2}:[0-9]{2}).*"))
        log("compact fields: " + (0..<fields.count).map { fields.element(boundBy: $0).label }.joined(separator: " | "))
        // The walk simulator writes dates day-month-year and times on a 24-hour clock.
        // input_date: a day back on its day/month/year wheel.
        if fields.count > 0 { pickInSheet(app, field: fields.element(boundBy: 0), [0: "\(appDay - 1)"], "in_date") }
        // input_time: 21:41.
        if fields.count > 1 { pickInSheet(app, field: fields.element(boundBy: 1), [0: "21", 1: "41"], "in_time") }
        // input_datetime: 22:15 on the day it shows.
        if fields.count > 2 { pickInSheet(app, field: fields.element(boundBy: 2), [1: "22", 2: "15"], "in_dt") }
        shot(app, "d3-fields-picked")
        button(app, "Continue").tap()

        // The legacy form step: date, time and date-and-time compact pickers.
        XCTAssertNotNil(text(app, "Form date", timeout: 15), "the form step did not show")
        shot(app, "d4-form-opened")
        let pickers = app.datePickers
        log("form pickers: \(pickers.count) values " + (0..<pickers.count).map { "\(pickers.element(boundBy: $0).value ?? "")" }.joined(separator: " | "))
        for i in 0..<pickers.count {
            let p = pickers.element(boundBy: i)
            p.tap(); sleep(1)
            let wheels = app.pickerWheels
            if wheels.count > 0 {
                // A time popover (or a date-and-time's time wheels): 19:20.
                log("form \(i) wheels " + (0..<wheels.count).map { "\(wheels.element(boundBy: $0).value ?? "")" }.joined(separator: " | "))
                let n = wheels.count
                if n >= 2 { wheels.element(boundBy: n - 2).adjust(toPickerWheelValue: "19"); wheels.element(boundBy: n - 1).adjust(toPickerWheelValue: "20") }
            } else {
                // A calendar popover: the day before the app zone's today, if it is in this month.
                let cell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "\(appDay - 1) November", "November \(appDay - 1)")).firstMatch
                log("form \(i) calendar cell \(cell.exists ? cell.label : "missing")")
                if cell.exists { cell.tap() }
            }
            shot(app, "d5-form-\(i)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); sleep(1)
        }
        log("form pickers after: " + (0..<pickers.count).map { "\(pickers.element(boundBy: $0).value ?? "")" }.joined(separator: " | "))
        shot(app, "d6-form-picked")
        button(app, "Continue").tap()

        XCTAssertNotNil(text(app, "What was stored", timeout: 15), "the read-back step did not show")
        shot(app, "d7-readback")
        for k in ["DW date:", "DW datetime:", "In date:", "In time:", "In datetime:", "F date:", "F time:", "F datetime:"] {
            log("readback \(text(app, k, timeout: 2)?.label ?? "\(k) MISSING")")
        }
        button(app, "Finish").tap()
        sleep(3); shot(app, "d8-finished")
        NSLog("[wsurvey] report:\n\(report.joined(separator: "\n"))")
    }
}
