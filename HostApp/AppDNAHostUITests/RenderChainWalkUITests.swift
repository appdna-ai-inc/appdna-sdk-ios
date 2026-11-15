// RenderChainWalkUITests.swift
//
// CHIPS, SEGMENTED CONTROLS AND REQUIRED LABELS, OPERATED.
//
// Drives a walk build of this host that is ALREADY INSTALLED under `ai.appdna.wrender` (built with a walk menu in its
// Info.plist by the walk script in the AppDNA repository; nothing about it is committed here). Frames go to the Mac's
// /tmp/wrender/ios and to the test's attachments; the report is NSLog'd under "[wrender]".
//
// The flow is dark with a green accent:
//   - chips with one-word and multi-word labels: each chip must be one line tall and as wide as its label;
//   - a segmented control authored with a green fill, and one with no fill: the selected segment must draw that colour,
//     not the system grey;
//   - required text fields, one with a label long enough to wrap: the asterisk must be part of the label's text.
// Every control is operated: chips are tapped, segments picked, fields typed into, and each step continued.
import XCTest

final class RenderChainWalkUITests: XCTestCase {

    private let bundleId = "ai.appdna.wrender"
    private var report: [String] = []

    private func log(_ s: String) { report.append(s); NSLog("[wrender] \(s)") }

    private func shot(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let s = app.screenshot()
        let a = XCTAttachment(data: s.pngRepresentation, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(atPath: "/tmp/wrender/ios", withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/wrender/ios/i-\(name).png"))
        return s
    }

    private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func text(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let e = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    /// The average colour of a small square at `point` (screen points) in `shot`, as 0–255 RGB.
    private func colour(_ shot: XCUIScreenshot, at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        guard let cg = shot.image.cgImage else { return (0, 0, 0) }
        let scale = CGFloat(cg.width) / shot.image.size.width
        let x = Int(point.x * scale) - 3, y = Int(point.y * scale) - 3
        var px = [UInt8](repeating: 0, count: 6 * 6 * 4)
        let ctx = CGContext(data: &px, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 24,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - y - 6), width: cg.width, height: cg.height))
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: px.count, by: 4) { r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2]) }
        return (r / 36, g / 36, b / 36)
    }

    func testChipsSegmentsAndRequiredLabels() throws {
        guard XCUIApplication(bundleIdentifier: bundleId).state != .unknown else { throw XCTSkip("the wrender walk build is not installed") }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate(); app.launch()
        _ = text(app, "config_fetched", timeout: 25)
        var shown = false
        for _ in 0..<4 where !shown {
            let m = button(app, "Render chain flow")
            if m.waitForExistence(timeout: 20) { m.tap() }
            shown = text(app, "Shape your plan", timeout: 10) != nil
        }
        XCTAssertTrue(shown, "the flow did not show")
        _ = shot(app, "1-opened")

        // Chips: one line each, as wide as the label.
        let labels = ["Strength", "Flexibility and mobility", "Breathing", "Cardiovascular endurance", "Rest", "Balance"]
        var heights: [CGFloat] = []
        for l in labels {
            let c = button(app, l)
            guard c.exists else { log("chip MISSING \(l)"); continue }
            heights.append(c.frame.height)
            log("chip \"\(l)\" w=\(Int(c.frame.width)) h=\(Int(c.frame.height))")
        }
        XCTAssertEqual(heights.count, labels.count, "a chip is missing")
        if let lo = heights.min(), let hi = heights.max() { XCTAssertEqual(lo, hi, accuracy: 1, "every chip is one line tall") }
        XCTAssertGreaterThan(button(app, "Cardiovascular endurance").frame.width, button(app, "Rest").frame.width * 2, "a chip is as wide as its label")
        button(app, "Flexibility and mobility").tap()
        button(app, "Cardiovascular endurance").tap()
        sleep(1)

        // Segmented: the picked segment draws its authored fill (green), or the brand accent; not system grey.
        let three = button(app, "Three"), thirty = button(app, "30 min")
        three.tap(); thirty.tap(); sleep(1)
        let s = shot(app, "2-picked")
        let green = colour(s, at: CGPoint(x: three.frame.minX + 6, y: three.frame.midY))
        let brand = colour(s, at: CGPoint(x: thirty.frame.minX + 6, y: thirty.frame.midY))
        log("segment Three fill rgb=\(green)   segment 30 min fill rgb=\(brand)")
        XCTAssertTrue(green.g > 150 && green.r < 100 && green.b < 140, "the selected segment is not the authored green: \(green)")
        XCTAssertFalse(abs(brand.r - brand.g) < 12 && abs(brand.g - brand.b) < 12, "the brand-accent segment is a grey: \(brand)")

        // Required labels: the asterisk is part of the label's text, also when it wraps.
        let long = text(app, "What is the one thing")
        log("long label: \"\(long?.label ?? "MISSING")\" h=\(Int(long?.frame.height ?? 0))")
        XCTAssertTrue(long?.label.hasSuffix("*") ?? false, "the asterisk is not part of the wrapped label")
        XCTAssertGreaterThan(long?.frame.height ?? 0, 30, "the long label did not wrap")
        let lone = app.staticTexts.matching(NSPredicate(format: "label == %@", "*")).count
        log("separate \"*\" text nodes: \(lone)")
        XCTAssertEqual(lone, 0, "an asterisk is drawn apart from its label")
        let short = text(app, "Your name")
        log("short label: \"\(short?.label ?? "MISSING")\"")

        let fields = app.textFields
        if fields.count >= 2 {
            // "\n" presses the keyboard's return key, which puts the keyboard away; the second field is then scrolled up.
            fields.element(boundBy: 0).tap(); fields.element(boundBy: 0).typeText("Run a steady five kilometres\n")
            sleep(1); app.swipeUp(velocity: .slow); sleep(1)
            fields.element(boundBy: 1).tap(); fields.element(boundBy: 1).typeText("Sam\n")
            sleep(1)
        } else { log("text fields found: \(fields.count)") }
        app.swipeUp(velocity: .slow)
        _ = shot(app, "3-filled")
        button(app, "Continue").tap()

        // The legacy form step: the same rule on its required field.
        let why = text(app, "Tell us in a sentence", timeout: 15)
        log("form label: \"\(why?.label ?? "MISSING")\" h=\(Int(why?.frame.height ?? 0))")
        XCTAssertTrue(why?.label.hasSuffix("*") ?? false, "the form step's asterisk is not part of its label")
        _ = shot(app, "4-form")
        let f = app.textFields.firstMatch
        if f.waitForExistence(timeout: 5) { f.tap(); f.typeText("It keeps me steady through the week\n"); sleep(1) }
        button(app, "Continue").tap()

        XCTAssertNotNil(text(app, "What was stored", timeout: 15), "the read-back step did not show")
        _ = shot(app, "5-readback")
        for k in ["Focus:", "Days:", "Length:", "Goal:", "Why:"] { log("readback \(text(app, k, timeout: 2)?.label ?? "\(k) MISSING")") }
        button(app, "Finish").tap()
        NSLog("[wrender] report:\n\(report.joined(separator: "\n"))")
    }

    /// A screen reader's view of the same flow: every text field is found BY ITS NAME (its label), typed into through
    /// that name, and the step continued. Before the fix the fields had no name, so `textFields[label]` found nothing.
    func testTextFieldsAreNamedByTheirLabels() throws {
        guard XCUIApplication(bundleIdentifier: bundleId).state != .unknown else { throw XCTSkip("the wrender walk build is not installed") }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate(); app.launch()
        _ = text(app, "config_fetched", timeout: 25)
        var shown = false
        for _ in 0..<4 where !shown {
            let m = button(app, "Render chain flow")
            if m.waitForExistence(timeout: 20) { m.tap() }
            shown = text(app, "Shape your plan", timeout: 10) != nil
        }
        XCTAssertTrue(shown, "the flow did not show")
        let goalName = "What is the one thing you would most like to get better at over the next three months?"
        let names = app.textFields.allElementsBoundByIndex.map(\.label)
        log("step 1 text field names: \(names)")
        XCTAssertEqual(names, [goalName, "Your name"], "each text field is named by its label")
        let goal = app.textFields[goalName], name = app.textFields["Your name"]
        XCTAssertTrue(goal.exists && name.exists, "a field cannot be found by its name")
        goal.tap(); goal.typeText("Swim a full kilometre\n"); sleep(1)
        app.swipeUp(velocity: .slow); sleep(1)
        name.tap(); name.typeText("Kim\n"); sleep(1)
        _ = shot(app, "n1-named-filled")
        button(app, "Continue").tap()
        let whyName = "Tell us in a sentence or two why this goal matters to you right now"
        let why = app.textFields[whyName]
        XCTAssertTrue(why.waitForExistence(timeout: 15), "the form step's field cannot be found by its name: \(app.textFields.allElementsBoundByIndex.map(\.label))")
        log("form text field names: \(app.textFields.allElementsBoundByIndex.map(\.label))")
        why.tap(); why.typeText("It is a quiet hour for me\n"); sleep(1)
        button(app, "Continue").tap()
        XCTAssertNotNil(text(app, "What was stored", timeout: 15))
        for k in ["Goal:", "Why:"] { log("readback \(text(app, k, timeout: 2)?.label ?? "\(k) MISSING")") }
        _ = shot(app, "n2-readback")
        button(app, "Finish").tap()
        NSLog("[wrender] report:\n\(report.joined(separator: "\n"))")
    }
}
