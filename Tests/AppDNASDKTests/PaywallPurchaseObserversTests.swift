// PaywallPurchaseObserversTests.swift
//
// SPEC-497 round 11 — `PaywallRenderer`'s post-purchase observers live exactly as long as the view.
// They used to be removed in `.onDisappear`, which also fires while a host full-screen cover hides the
// paywall: a `.paywallPurchaseEnded` posted then reached no one and the CTA stayed spinning. The holder has
// no "disappear" path at all — only `deinit` removes the observers.

import XCTest
@testable import AppDNASDK

final class PaywallPurchaseObserversTests: XCTestCase {
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
    }

    private func register(_ holder: PaywallPurchaseObservers,
                          success: @escaping () -> Void = {},
                          ended: @escaping () -> Void = {},
                          failure: @escaping () -> Void = {}) {
        holder.register(onSuccess: { _ in success() }, onEnded: { _ in ended() }, onFailure: { _ in failure() })
    }

    /// A post made at any point while the holder is alive (e.g. while a cover hides the paywall) still resets
    /// the CTA: both the ended and the failure paths are delivered.
    func testPostsReachTheBlocksForAsLongAsTheHolderLives() {
        let holder = PaywallPurchaseObservers(center: center)
        let ended = expectation(description: "ended delivered")
        let failed = expectation(description: "failure delivered")
        register(holder, ended: { ended.fulfill() }, failure: { failed.fulfill() })
        XCTAssertEqual(holder.registeredCount, 3)

        center.post(name: .paywallPurchaseEnded, object: nil)
        center.post(name: .paywallPurchaseFailure, object: nil, userInfo: ["message": "x"])
        wait(for: [ended, failed], timeout: 2)
    }

    /// The observers are removed at `deinit` — the I4 m3 leak stays fixed. NEGATIVE CONTROL: without the
    /// `removeAll()` in `deinit`, the block-based observers outlive the holder and these posts are delivered.
    ///
    /// One inverted expectation PER NOTIFICATION NAME: a single shared one with `expectedFulfillmentCount = 3`
    /// only failed when all three leaked, so a holder that removed two tokens and leaked the third passed.
    func testObserversAreRemovedAtDeinit() {
        var holder: PaywallPurchaseObservers? = PaywallPurchaseObservers(center: center)
        weak var weakHolder = holder
        let successLeaked = expectation(description: "success not delivered after deinit")
        let endedLeaked = expectation(description: "ended not delivered after deinit")
        let failureLeaked = expectation(description: "failure not delivered after deinit")
        [successLeaked, endedLeaked, failureLeaked].forEach { $0.isInverted = true }
        register(holder!, success: { successLeaked.fulfill() }, ended: { endedLeaked.fulfill() },
                 failure: { failureLeaked.fulfill() })
        holder = nil
        XCTAssertNil(weakHolder, "the blocks must not keep the holder alive")

        center.post(name: .paywallPurchaseSuccess, object: nil)
        center.post(name: .paywallPurchaseEnded, object: nil)
        center.post(name: .paywallPurchaseFailure, object: nil)
        wait(for: [successLeaked, endedLeaked, failureLeaked], timeout: 0.5)
    }

    /// A repeated `onAppear` replaces the observers rather than stacking a second set.
    func testRegisterAgainReplacesTheObservers() {
        let holder = PaywallPurchaseObservers(center: center)
        let first = expectation(description: "first set not delivered")
        first.isInverted = true
        let second = expectation(description: "second set delivered once")
        second.expectedFulfillmentCount = 1
        second.assertForOverFulfill = true
        register(holder, ended: { first.fulfill() })
        register(holder, ended: { second.fulfill() })
        XCTAssertEqual(holder.registeredCount, 3)

        center.post(name: .paywallPurchaseEnded, object: nil)
        wait(for: [first, second], timeout: 0.5)
    }
}

/// SPEC-497 round 12 — source gate: the blocks `PaywallRenderer` passes to `purchaseObservers.register(…)`
/// never capture the view. The holder is the view's `@StateObject`, so a block that captures it makes a cycle
/// (holder → token → block → view → holder) and `deinit` — the only place the observers are removed — never
/// runs. In a SwiftUI `struct` a capture needs no `self.`: naming a stored property or method bare
/// (`isPurchasing = false`) captures the view too. So the gate flags `self` AND every bare member name.
final class PaywallRendererObserverCaptureGateTests: XCTestCase {

    private func rendererSource() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Sources/AppDNASDK/Paywalls/PaywallRenderer.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("PaywallRenderer.swift not found above \(#filePath) — the source tree is not next to the tests")
    }

    /// The text between the parentheses of the `purchaseObservers.register(` call, comments blanked.
    static func registerArguments(in source: String) -> String? {
        let code = NotificationPostChokepointTests.stripComments(source)
        guard let open = code.range(of: "purchaseObservers.register(") else { return nil }
        var depth = 1
        var i = open.upperBound
        while i < code.endIndex {
            switch code[i] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[open.upperBound..<i]) }
            default: break
            }
            i = code.index(after: i)
        }
        return nil
    }

    /// Stored properties and methods declared directly in `struct PaywallRenderer` (4-space indent, up to
    /// the next top-level type).
    static func viewMembers(in source: String) -> Set<String> {
        guard let start = source.range(of: "struct PaywallRenderer: View {") else { return [] }
        var body = String(source[start.upperBound...])
        if let next = body.range(of: #"\n(private |fileprivate )?(struct|final class|class|enum|extension) "#,
                                 options: .regularExpression) {
            body = String(body[..<next.lowerBound])
        }
        let pattern = #"(?m)^    (?:@\w+(?:\([^)\n]*\))? )*(?:(?:private|fileprivate|internal|static|mutating) )*(?:let|var|func) (\w+)"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = body as NSString
        return Set(re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        })
    }

    /// Every capture of the view in `arguments`: `self`, or a member named bare (not after `.` or `$`).
    static func viewCaptures(in arguments: String, members: Set<String>) -> [String] {
        let ns = arguments as NSString
        var hits: [String] = []
        for name in members.union(["self"]).sorted() {
            let pattern = #"(?<![.$\w])"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            let re = try! NSRegularExpression(pattern: pattern)
            if re.firstMatch(in: arguments, range: NSRange(location: 0, length: ns.length)) != nil {
                hits.append(name)
            }
        }
        return hits
    }

    func testRegisterBlocksNeverCaptureTheView() throws {
        let source = try rendererSource()
        let arguments = try XCTUnwrap(Self.registerArguments(in: source),
                                      "PaywallRenderer no longer calls purchaseObservers.register( — update this gate")
        let members = Self.viewMembers(in: source)
        // Sanity: the scans found what they must, so an empty result below means something.
        XCTAssertTrue(members.isSuperset(of: ["isPurchasing", "showErrorBanner", "purchaseObservers", "config", "body"]),
                      "member scan is broken: \(members.sorted())")
        XCTAssertTrue(arguments.contains("onEnded:") && arguments.contains("onFailure:"), "argument extraction is broken")
        XCTAssertEqual(Self.viewCaptures(in: arguments, members: members), [],
                       "a purchaseObservers.register block captures the view — pass a Binding (`$x`) instead")
    }

    /// NEGATIVE CONTROL for the gate itself: an explicit `self.` capture, and an implicit one by a bare member.
    func testGateFlagsExplicitAndImplicitViewCaptures() {
        let members: Set<String> = ["isPurchasing", "errorMessage"]
        XCTAssertEqual(Self.viewCaptures(in: "onEnded: { _ in self.isPurchasing = false }", members: members),
                       ["self"])
        XCTAssertEqual(Self.viewCaptures(in: "onEnded: { _ in isPurchasing = false }", members: members),
                       ["isPurchasing"])
        XCTAssertEqual(Self.viewCaptures(in: "onEnded: { _ in p.wrappedValue = false; x.errorMessage = $isPurchasing }",
                                         members: members), [])
    }
}
