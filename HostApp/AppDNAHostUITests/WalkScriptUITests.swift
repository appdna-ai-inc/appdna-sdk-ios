// WalkScriptUITests.swift — a SCRIPTED device walk on the simulator: launch, tap, swipe, type, screenshot and read the
// accessibility tree, step by step, from a JSON script on the HOST.
//
// A simulator has no tap verb, and a walk that cannot tap can only prove that a surface was drawn — not that its
// button advances, its banner dismisses or its notification arrives (CLAUDE.md Rules 23/24). Each walk-specific UI
// test hard-codes its surface; this one reads the steps at run time, so one `build-for-testing` serves any number of
// walks, each a `test-without-building` run of a new script.
//
// The script is read from the path in `WALK_SCRIPT_PATH` (default `/tmp/walk-script/script.json`; a simulator process
// reads the host's filesystem). Frames and the log go next to it. It SKIPS when there is no script, so a stock run of
// the UI-test target is unchanged. Nothing here names a surface: the ids, labels and launch arguments are in the
// script, which never enters this repository (`packages/appdna-sdk-ios/**` is a public mirror).
//
// Steps (one JSON object each, run in order):
//   {"launch": ["-arg", "value", …]}         (re)launch the host with these launch arguments
//   {"tap": "Label"} / {"tapContains": "La"} tap the first on-screen element whose label equals / contains it
//                                            (`"nth": 2` taps the third, for options that repeat across groups)
//   {"tapXY": [0.5, 0.9]}                    tap a normalised point of the window
//   {"swipe": "up"|"down"|"left"|"right"}    swipe the window
//   {"type": "words"}                        type into the focused field
//   {"wait": 2.5}                            sleep
//   {"waitFor": "Label", "timeout": 30}      wait for an element with that label; logs FOUND / MISSING
//   {"expect": "Label"} / {"expectGone": "Label"}   log PASS / FAIL for presence / absence
//   {"shot": "name"}                         screenshot → <dir>/<name>.png
//   {"tree": "name"}                         the app's element tree (debugDescription) → <dir>/<name>.txt
//   {"springboardTap": "Label", "timeout": 20}      tap an element in SpringBoard (an alert, a notification);
//                                                   `"exact": true` matches the whole label
//   {"springboardExpect": "Label", "timeout": 20}   log PASS / FAIL for an element in SpringBoard
//   {"background": true} / {"activate": true}       send the host to the home screen / bring it back
import XCTest

final class WalkScriptUITests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private lazy var scriptPath = ProcessInfo.processInfo.environment["WALK_SCRIPT_PATH"] ?? "/tmp/walk-script/script.json"
    private lazy var dir = (scriptPath as NSString).deletingLastPathComponent
    private var logLines: [String] = []
    /// Each log line carries the seconds since the run started, so a walk can TIME what it sees (a control that
    /// appears after a delay, a message that closes itself) instead of only recording that it saw it.
    private let started = Date()

    private func log(_ s: String) {
        let line = String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + s
        logLines.append(line)
        print("[walk-script] \(line)")
        try? logLines.joined(separator: "\n").write(toFile: "\(dir)/walk.log", atomically: true, encoding: .utf8)
    }

    private func element(_ root: XCUIApplication, label: String, contains: Bool, nth: Int = 0) -> XCUIElement? {
        let pred = contains ? NSPredicate(format: "label CONTAINS %@", label) : NSPredicate(format: "label == %@", label)
        // On screen, by FRAME: `isHittable` on a static text whose activation point XCTest cannot compute records a
        // failure that ends the run, so it is never asked.
        let screen = root.windows.firstMatch.frame
        for q in [root.buttons, root.staticTexts, root.otherElements, root.cells, root.links, root.images, root.textFields, root.switches] {
            let m = q.matching(pred)
            var seen = 0
            for i in 0..<min(m.count, 12) {
                let e = m.element(boundBy: i)
                if e.exists && !e.frame.isEmpty && (screen.isEmpty || screen.intersects(e.frame)) {
                    if seen == nth { return e }
                    seen += 1
                }
            }
        }
        let any = root.descendants(matching: .any).matching(pred).firstMatch
        return any.exists ? any : nil
    }

    func testRunTheWalkScript() throws {
        guard let data = FileManager.default.contents(atPath: scriptPath),
              let steps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw XCTSkip("no walk script at \(scriptPath)")
        }
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        log("script: \(steps.count) step(s)")

        for (n, step) in steps.enumerated() {
            let timeout = (step["timeout"] as? Double) ?? 20
            if let args = step["launch"] as? [String] {
                app.terminate()
                app.launchArguments = args
                app.launch()
                log("\(n) launch \(args.count) arg(s)")
            } else if let label = step["tap"] as? String ?? step["tapContains"] as? String {
                let contains = step["tapContains"] != nil
                let deadline = Date().addingTimeInterval(timeout)
                var hit: XCUIElement?
                while hit == nil && Date() < deadline {
                    hit = element(app, label: label, contains: contains, nth: (step["nth"] as? Int) ?? 0)
                    if hit == nil { Thread.sleep(forTimeInterval: 0.5) }
                }
                if let hit { hit.tap(); log("\(n) tap OK \"\(label)\"") } else { log("\(n) tap MISSING \"\(label)\"") }
            } else if let xy = step["tapXY"] as? [Double], xy.count == 2 {
                app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap()
                log("\(n) tapXY \(xy)")
            } else if let dir = step["swipe"] as? String {
                switch dir {
                case "up": app.swipeUp()
                case "down": app.swipeDown()
                case "left": app.swipeLeft()
                default: app.swipeRight()
                }
                log("\(n) swipe \(dir)")
            } else if let text = step["type"] as? String {
                app.typeText(text)
                log("\(n) typed \"\(text)\"")
            } else if let s = step["wait"] as? Double {
                Thread.sleep(forTimeInterval: s)
                log("\(n) wait \(s)")
            } else if let label = step["waitFor"] as? String {
                let deadline = Date().addingTimeInterval(timeout)
                var found = false
                while !found && Date() < deadline {
                    found = element(app, label: label, contains: true) != nil
                    if !found { Thread.sleep(forTimeInterval: 0.5) }
                }
                log("\(n) waitFor \(found ? "FOUND" : "MISSING") \"\(label)\"")
            } else if let label = step["expect"] as? String {
                log("\(n) expect \(element(app, label: label, contains: true) != nil ? "PASS" : "FAIL") present \"\(label)\"")
            } else if let label = step["expectGone"] as? String {
                log("\(n) expect \(element(app, label: label, contains: true) == nil ? "PASS" : "FAIL") gone \"\(label)\"")
            } else if let name = step["shot"] as? String {
                let png = XCUIScreen.main.screenshot().pngRepresentation
                let ok = FileManager.default.createFile(atPath: "\(dir)/\(name).png", contents: png)
                log("\(n) shot \(name) \(ok ? "saved" : "NOT SAVED")")
            } else if let name = step["tree"] as? String {
                try? app.debugDescription.write(toFile: "\(dir)/\(name).txt", atomically: true, encoding: .utf8)
                log("\(n) tree \(name)")
            } else if let label = step["springboardTap"] as? String {
                // `"exact": true` for an alert's buttons, where "Allow" is also inside "Don’t Allow".
                let fmt = (step["exact"] as? Bool) == true ? "label == %@" : "label CONTAINS %@"
                let e = springboard.descendants(matching: .any).matching(NSPredicate(format: fmt, label)).firstMatch
                if e.waitForExistence(timeout: timeout) { e.tap(); log("\(n) springboard tap OK \"\(label)\"") } else { log("\(n) springboard tap MISSING \"\(label)\"") }
            } else if let label = step["springboardExpect"] as? String {
                let e = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                log("\(n) springboard expect \(e.waitForExistence(timeout: timeout) ? "PASS" : "FAIL") \"\(label)\"")
            } else if step["background"] != nil {
                XCUIDevice.shared.press(.home)
                log("\(n) background")
            } else if step["activate"] != nil {
                app.activate()
                log("\(n) activate")
            } else {
                log("\(n) unknown step \(step)")
            }
        }
        log("done")
    }
}
