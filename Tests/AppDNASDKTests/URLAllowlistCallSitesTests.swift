import XCTest
@testable import AppDNASDK

/**
 The scheme allowlist, asserted at the CALL SITES — the iOS sibling of Android's
 `UrlAllowlistCallSitesTest`.

 🔴 Android has had this gate since `PaywallActivity` was found building
 `Intent(ACTION_VIEW, Uri.parse(configString))` by hand on the money path, and iOS never grew one.
 So the banner's "Learn more" shipped as `Link(linkText, destination: URL(string: authored))`,
 which hands a CONFIG-SUPPLIED url straight to the system with no scheme check at all — and the
 same line was, separately, the reason the link opened nothing on a device.

 `URLSafety`'s own comment already states the rule: "Every config-driven open goes through here
 now." A rule nothing enforces is a rule that lasts until the next renderer.

 These tests read the SDK's own source. That is deliberate and is the only thing that can work
 here: the call sites that matter are inside SwiftUI view builders, which a unit test cannot tap,
 and the defect is the ABSENCE of a call rather than a wrong result from one.
 */
final class URLAllowlistCallSitesTests: XCTestCase {

    /// Every `.swift` under `Sources/`, found from this file's own location so it works from any
    /// derived-data path.
    private func sdkSources() throws -> [(path: String, text: String)] {
        var dir = URL(fileURLWithPath: #filePath)
        // …/Tests/AppDNASDKTests/URLAllowlistCallSitesTests.swift → the package root
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let sources = dir.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else {
            throw XCTSkip("Sources/ is not readable from \(sources.path) — this gate reads the tree")
        }
        var out: [(String, String)] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let full = sources.appendingPathComponent(rel)
            if let text = try? String(contentsOf: full, encoding: .utf8) {
                out.append((rel, text))
            }
        }
        XCTAssertGreaterThan(out.count, 50, "the sweep found almost no source files, so it proves nothing")
        return out
    }

    /**
     The file with its comments blanked — BOTH kinds.

     🔴 The first version stripped only `//`, and the gate's own first run failed on the block
     comment that explains why this gate exists, which contains the words `Link(linkText,
     destination:)`. That is the same comment-blindness that cost `check:page-reachable` 31
     phantom orphans, and it is the reason a gate gets ignored: it was loud, and it was wrong.

     Newlines are preserved so reported line numbers still point at the real line.
     */
    private func blankingComments(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        var inBlock = false
        var inLine = false
        var inString = false
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : nil
            if inBlock {
                if c == "*" && next == "/" { inBlock = false; out += "  "; i = text.index(i, offsetBy: 2); continue }
                out.append(c == "\n" ? "\n" : " ")
            } else if inLine {
                if c == "\n" { inLine = false; out.append("\n") } else { out.append(" ") }
            } else if inString {
                // Only to stop a `//` or `/*` inside a string literal opening a comment.
                out.append(c)
                if c == "\\" , next != nil { out.append(next!); i = text.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
            } else if c == "/" && next == "*" {
                inBlock = true; out += "  "; i = text.index(i, offsetBy: 2); continue
            } else if c == "/" && next == "/" {
                inLine = true; out += "  "; i = text.index(i, offsetBy: 2); continue
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i = text.index(after: i)
        }
        return out
    }

    /**
     No SwiftUI `Link(` anywhere in the SDK.

     It is a blanket ban rather than "a `Link` whose destination is config-derived", because the
     two are indistinguishable from a line of source and the safe case costs nothing: a `Button`
     calling `URLSafety.open` renders identically and gets the scheme check for free.
     */
    func testNoSwiftUILinkInSDKSource() throws {
        var offenders: [String] = []
        for (path, text) in try sdkSources() {
            for (i, line) in blankingComments(text).components(separatedBy: "\n").enumerated() {
                let code = line
                guard code.contains("Link(") else { continue }
                // `NavigationLink(`, `ShareLink(` and the like are different types.
                if code.range(of: "(?<![A-Za-z])Link\\(", options: .regularExpression) == nil { continue }
                offenders.append("\(path):\(i + 1): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "A SwiftUI `Link` hands its destination to the system with NO scheme check, and on a "
                + "device inside an onboarding step it opens nothing at all. Use a Button "
                + "calling `URLSafety.open`.\n" + offenders.joined(separator: "\n"),
        )
    }

    /**
     Every file that opens a URL also names `URLSafety`.

     Coarse on purpose. The precise question — "is THIS url config-derived?" — cannot be answered
     from a line, and the coarse one has no false negatives that matter: a file that opens a URL
     and has never heard of the allowlist is the shape of every bypass found so far.
     */
    func testEveryURLOpenerFileKnowsAboutTheAllowlist() throws {
        /// Files that open a URL the SDK BUILT ITSELF, from no config: the App Store review link
        /// and the OS settings deep link. Neither can carry an attacker's scheme.
        let selfBuiltOnly: Set<String> = [
            "AppDNASDK/Feedback/ReviewPromptManager.swift",
            "AppDNASDK/Onboarding/PermissionManager.swift",
            "AppDNASDK/Core/URLSafety.swift",
        ]
        var offenders: [String] = []
        for (path, text) in try sdkSources() where !selfBuiltOnly.contains(path) {
            let opensAURL = blankingComments(text)
                .components(separatedBy: "\n")
                .contains { $0.contains("UIApplication.shared.open") }
            guard opensAURL else { continue }
            if !text.contains("URLSafety") {
                offenders.append(path)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "These files hand a URL to the system and never mention `URLSafety`. Every "
                + "config-driven open goes through it — that is the helper's own rule, and the "
                + "money path once ignored it in three places.\n" + offenders.joined(separator: "\n"),
        )
    }

    /**
     🔴 THE SCANNER CAN SEE AN OFFENDER — the negative control for the two sweeps above.

     "No offenders found" is the same sentence whether the tree is clean or the scanner is blind,
     and this gate's FIRST run proved it can be blind in the other direction: it stripped `//` and
     not a block comment, so it reported the very comment explaining why it exists. A comment must
     not be read as code, and code must not be hidden by sitting near one.
     */
    func testTheScannerSeesCodeAndIgnoresComments() {
        let slashes = "//"
        let openBlock = "/" + "*"
        let closeBlock = "*" + "/"
        let sample = [
            slashes + " Link(a, destination: b)",
            openBlock + " Link(c, destination: d)",
            "   still inside the block " + closeBlock,
            "let s = \"" + openBlock + " not a comment " + closeBlock + " Link(no)\"",
            "Link(real, destination: url)",
        ].joined(separator: "\n")

        let scanned = blankingComments(sample).components(separatedBy: "\n")
        XCTAssertEqual(scanned.count, 5, "line numbers must survive, so blanked lines stay lines")
        XCTAssertFalse(scanned[0].contains("Link("), "a line comment is not code")
        XCTAssertFalse(scanned[1].contains("Link("), "a block comment is not code")
        XCTAssertFalse(scanned[2].contains("inside"), "a block comment continues onto its own lines")
        XCTAssertTrue(scanned[3].contains("Link(no)"), "a comment INSIDE a string literal is a string")
        XCTAssertTrue(scanned[4].contains("Link(real"), "real code survives — without this the sweep is vacuous")
    }

    /// The helper still refuses what it is there to refuse, so the tests above are not
    /// guarding an empty box.
    func testTheAllowlistItselfStillRefusesDangerousSchemes() {
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<b>x</b>"] {
            XCTAssertNil(URLSafety.sanitized(raw), "\(raw) must be refused")
        }
        XCTAssertNotNil(URLSafety.sanitized("https://example.com/help"))
    }
}
