// Spec497Round2NativeFixTests.swift
//
// iOS fixes without a better home:
//   - the re-buy fixture driver's positive control (`alreadyOwned == false` delivers exactly once);
//   - nothing in the SDK posts a notification except through `NotificationCenterSlot`, so a push
//     fixture's `notification_posted` (read from the slot) means something;
//   - the interactive map never overrides the user's pan / zoom (`MapCameraGate`).
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

// MARK: -

final class RebuyDriverPositiveControlTests: XCTestCase {

    private final class Spy: AppDNABillingDelegate {
        var completed: [String] = []
        func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
            completed.append("\(productId)|\(transaction.transactionId)")
        }
    }

    private func run(preCall: Set<String>) async -> (owned: Bool, spy: Spy, events: [String]) {
        let keychain = KeychainStore(service: "ai.appdna.sdk.test.rebuy.\(UUID().uuidString)")
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        var events: [String] = []
        tracker.eventSink = { events.append($0.event_name) }
        let spy = Spy()
        let owned = await SharedFixtureTests.driveRebuy(
            preCallIds: preCall,
            transactionId: "2000000000000001",
            productId: "lifetime",
            price: 9.99,
            currency: "USD",
            tracker: tracker,
            delegate: spy
        )
        return (owned, spy, events)
    }

    /// The positive control: a NEW purchase through the same driver delivers exactly one
    /// `onPurchaseCompleted` and books one `purchase_completed`. Without it, a driver that never
    /// delivered would pass `ios_rebuy_already_owned_restored` (which expects no delivery) vacuously.
    func testANewPurchaseDeliversExactlyOnce() async {
        let r = await run(preCall: [])
        XCTAssertFalse(r.owned)
        XCTAssertEqual(r.spy.completed, ["lifetime|2000000000000001"])
        XCTAssertEqual(r.events, ["purchase_completed"])
    }

    func testARebuyDeliversNothingAndBooksNoRevenue() async {
        let r = await run(preCall: ["2000000000000001"])
        XCTAssertTrue(r.owned)
        XCTAssertEqual(r.spy.completed, [])
        XCTAssertEqual(r.events, ["purchase_restored"])
    }
}

// MARK: -

/// Every `UNUserNotificationCenter` `add(` in `Sources/` must be the one inside
/// `SystemNotificationCenterSlot`. The push fixtures read `notification_posted` from the slot; a post
/// that went around it would make that assertion meaningless.
final class NotificationPostChokepointTests: XCTestCase {

    /// `packages/appdna-sdk-ios/Sources` (every module — the slot lives in AppDNANotificationExtension),
    /// found by walking up from this file.
    private func sourcesRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Sources/AppDNASDK")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.deletingLastPathComponent() }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Sources/AppDNASDK not found above \(#filePath) — the source tree is not next to the tests")
    }

    /// Source with `//` line comments and `/* */` blocks blanked (string contents are left: a `.add(`
    /// inside a string literal would be flagged, which is the safe direction).
    static func stripComments(_ src: String) -> String {
        var out = ""
        var i = src.startIndex
        while i < src.endIndex {
            let rest = src[i...]
            if rest.hasPrefix("//") {
                let end = src[i...].firstIndex(of: "\n") ?? src.endIndex
                i = end
                continue
            }
            if rest.hasPrefix("/*") {
                let end = src.range(of: "*/", range: i..<src.endIndex)?.upperBound ?? src.endIndex
                out += String(repeating: " ", count: src[i..<end].filter { $0 != "\n" }.count)
                i = end
                continue
            }
            out.append(src[i])
            i = src.index(after: i)
        }
        return out
    }

    /// Offsets of every `add(` made on a notification center in `code`: `UNUserNotificationCenter
    /// .current().add(`, or `<name>.add(` where `<name>` is bound to `UNUserNotificationCenter.current()`
    /// or typed `UNUserNotificationCenter` (e.g. a delegate callback's `center`).
    static func centerAddOffsets(in code: String) -> [Int] {
        let ns = code as NSString
        var aliases = Set<String>()
        let aliasPatterns = [
            #"\b(?:let|var)\s+(\w+)\s*(?::\s*UNUserNotificationCenter\s*)?=\s*UNUserNotificationCenter\s*\.\s*current\s*\(\s*\)"#,
            #"\b(\w+)\s*:\s*UNUserNotificationCenter\b"#,
        ]
        for p in aliasPatterns {
            let re = try! NSRegularExpression(pattern: p)
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                aliases.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        var receivers = [#"UNUserNotificationCenter\s*\.\s*current\s*\(\s*\)"#]
        receivers += aliases.map { #"\b"# + NSRegularExpression.escapedPattern(for: $0) }
        let re = try! NSRegularExpression(pattern: "(?:" + receivers.joined(separator: "|") + #")\s*\.\s*add\s*\("#)
        return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
    }

    /// The `{…}` body range of `final class SystemNotificationCenterSlot`, or nil.
    static func slotBody(in code: String) -> NSRange? {
        let ns = code as NSString
        let head = ns.range(of: "class SystemNotificationCenterSlot")
        guard head.location != NSNotFound else { return nil }
        let open = ns.range(of: "{", range: NSRange(location: head.location, length: ns.length - head.location))
        guard open.location != NSNotFound else { return nil }
        var depth = 0
        for i in open.location..<ns.length {
            let c = ns.character(at: i)
            if c == 123 { depth += 1 } else if c == 125 {
                depth -= 1
                if depth == 0 { return NSRange(location: open.location, length: i - open.location + 1) }
            }
        }
        return nil
    }

    func testTheRuleFlagsAPostThatBypassesTheSlot() {
        let bypass = """
        final class Poster {
            func post(_ r: UNNotificationRequest) { UNUserNotificationCenter.current().add(r) }
            func viaAlias(_ r: UNNotificationRequest) {
                let nc = UNUserNotificationCenter.current()
                nc.add(r, withCompletionHandler: nil)
            }
            func userNotificationCenter(_ center: UNUserNotificationCenter, r: UNNotificationRequest) async throws {
                try await center.add(r)
            }
            func unrelated(path: GMSMutablePath) { path.add(x) }
        }
        """
        XCTAssertEqual(Self.centerAddOffsets(in: Self.stripComments(bypass)).count, 3)
        XCTAssertEqual(Self.centerAddOffsets(in: "// UNUserNotificationCenter.current().add(r)").count, 1,
                       "raw text still matches — stripComments is what exempts comments")
        XCTAssertEqual(Self.centerAddOffsets(in: Self.stripComments("// UNUserNotificationCenter.current().add(r)")).count, 0)
    }

    func testOnlyTheSlotPostsANotification() throws {
        let root = try sourcesRoot()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var inSlot = 0
        var offenders: [String] = []
        for url in files {
            let code = Self.stripComments(try String(contentsOf: url, encoding: .utf8))
            let slot = Self.slotBody(in: code)
            for offset in Self.centerAddOffsets(in: code) {
                if let slot, NSLocationInRange(offset, slot) {
                    inSlot += 1
                } else {
                    let line = (code as NSString).substring(to: offset).components(separatedBy: "\n").count
                    offenders.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "post through NotificationCenterSlot.add(_:) instead, so notification_posted is observable")
        XCTAssertEqual(inSlot, 1, "the slot's own add is the one allowed post — the scan must still see it")
    }
}

// MARK: - I10

final class MapCameraGateTests: XCTestCase {

    private let a = MapInteractivePlan.Camera.center(lat: 47.6, lng: -122.3, zoom: 12)
    private let b = MapInteractivePlan.Camera.center(lat: 40.7, lng: -74.0, zoom: 10)

    func testTheCameraWaitsForASize() {
        var gate = MapCameraGate()
        XCTAssertTrue(gate.request(a))
        XCTAssertNil(gate.take(width: 0, height: 240))
        XCTAssertEqual(gate.take(width: 390, height: 240), a)
    }

    /// The rule: once applied, re-requesting the SAME camera (each `updateUIView`, a style change, a
    /// recomposition) moves nothing — so whatever the user panned / zoomed to stays. NEGATIVE CONTROL:
    /// with no `applied` check, the second request would return `a` and snap the map back.
    func testReRequestingTheAppliedCameraNeverOverridesTheUsersPan() {
        var gate = MapCameraGate()
        XCTAssertTrue(gate.request(a))
        XCTAssertEqual(gate.take(width: 390, height: 240), a)
        // … the user pans; SwiftUI then re-renders with an unchanged plan:
        for _ in 0..<3 {
            XCTAssertFalse(gate.request(a))
            XCTAssertNil(gate.take(width: 390, height: 240))
        }
    }

    /// A camera INPUT change (e.g. host `mapRoutes` arriving after first paint) does move it — once.
    func testAChangedCameraInputMovesItOnce() {
        var gate = MapCameraGate()
        _ = gate.request(a)
        _ = gate.take(width: 390, height: 240)
        XCTAssertTrue(gate.request(b))
        XCTAssertEqual(gate.take(width: 390, height: 240), b)
        XCTAssertFalse(gate.request(b))
        XCTAssertNil(gate.take(width: 390, height: 240))
    }
}
