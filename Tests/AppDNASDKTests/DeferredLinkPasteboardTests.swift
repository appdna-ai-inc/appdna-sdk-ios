// DeferredLinkPasteboardTests.swift
//
// THE FIRST-LAUNCH CHECK READS THE PASTEBOARD ONLY WHEN IT HOLDS A LINK.
//
// Reading another app's pasteboard content makes iOS 16+ show "<App> would like to paste from
// <other app>" and blocks the reading thread until the user answers. The deferred deep link check
// used to read on every first launch, so every host app showed that alert to any user who had
// copied anything. It now asks the two prompt-free questions first — `hasStrings` and
// `detectPatterns(.probableWebURL)` — and reads only when both say yes.
//
// These drive the REAL manager with a recording pasteboard, so "was `.string` touched?" is
// observed rather than inferred, and the thread it was touched on is recorded too.
import XCTest
import UIKit
@testable import AppDNASDK

final class DeferredLinkPasteboardTests: XCTestCase {

    private let firstLaunchKey = "ai.appdna.sdk.first_launch_completed"
    private let attemptsKey = "ai.appdna.sdk.ddl_failed_attempts"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: firstLaunchKey)
        UserDefaults.standard.removeObject(forKey: attemptsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: firstLaunchKey)
        UserDefaults.standard.removeObject(forKey: attemptsKey)
        super.tearDown()
    }

    private func check(_ pb: RecordingPasteboard) {
        let done = expectation(description: "checkDeferredDeepLink called back")
        DeferredDeepLinkManager(orgId: "org", appId: "app", eventTracker: nil, pasteboard: pb)
            .checkDeferredDeepLink { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testArbitraryTextIsNeverRead() {
        let pb = RecordingPasteboard(hasStrings: true, probableURL: false, text: "a shopping list someone copied")
        check(pb)
        XCTAssertEqual(pb.detectCalls, 1, "the prompt-free probe must be asked")
        XCTAssertEqual(pb.stringReads, 0, "text that is not a link must never be read — the read is what prompts")
        XCTAssertEqual(pb.clears, 0, "someone else's text must not be cleared")
    }

    func testAnEmptyPasteboardIsNotEvenProbed() {
        let pb = RecordingPasteboard(hasStrings: false, probableURL: false, text: nil)
        check(pb)
        XCTAssertEqual(pb.detectCalls, 0)
        XCTAssertEqual(pb.stringReads, 0)
    }

    /// 🔴 RED CONTROL for the two tests above: the same harness DOES see a read when the gate
    /// opens, and that read is off the main thread. Without this, a recorder that never counted
    /// would make "never read" pass for the worst reason.
    func testOurLinkIsReadOffTheMainThreadAndCleared() {
        let pb = RecordingPasteboard(hasStrings: true, probableURL: true,
                                     text: "https://links.example.com/?appdna_visitor=v_123")
        check(pb)
        XCTAssertEqual(pb.stringReads, 1, "our link must still be read")
        XCTAssertEqual(pb.readOnMainThread, false, "the read must never block the main thread")
        XCTAssertEqual(pb.clears, 1, "our marker is one-time and must be cleared")
    }

    func testSomeoneElsesLinkIsReadButNotCleared() {
        let pb = RecordingPasteboard(hasStrings: true, probableURL: true, text: "https://news.example.org/article/42")
        check(pb)
        XCTAssertEqual(pb.stringReads, 1)
        XCTAssertEqual(pb.clears, 0, "a link that is not ours stays where the user put it")
    }

    /// The real system probe, against content THIS process put there (so reading never prompts).
    /// Pins what `detectPatterns(.probableWebURL)` actually says about each shape the gate
    /// depends on — the fixture's `probable_url` inputs are only honest if iOS agrees with them.
    func testTheSystemProbeClassifiesOurShapes() {
        let cases: [(String, Bool)] = [
            ("https://links.example.com/?appdna_visitor=v_123", true),
            ("a shopping list someone copied", false),
        ]
        for (text, expected) in cases {
            UIPasteboard.general.string = text
            let done = expectation(description: "detect \(text)")
            var got: Bool?
            SystemPasteboard().detectProbableWebURL { got = $0; done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(got, expected, "detectPatterns(.probableWebURL) on \"\(text)\"")
        }
        // Pinned: iOS does NOT call the legacy `appdna:visitor:<id>` marker a web link, so on iOS
        // it can no longer be read without a prompt — which is why the docs tell a web page to copy
        // the URL form. If a future iOS starts classifying it, this fails and the docs can relax.
        UIPasteboard.general.string = "appdna:visitor:3f2c9a10-7b1e-4c55-9d1a-0a1b2c3d4e5f"
        let legacy = expectation(description: "legacy")
        var legacyIsURL: Bool?
        SystemPasteboard().detectProbableWebURL { legacyIsURL = $0; legacy.fulfill() }
        wait(for: [legacy], timeout: 5)
        XCTAssertEqual(legacyIsURL, false, "the legacy marker's classification changed — revisit the docs")
        UIPasteboard.general.string = ""
    }
}

/// A pasteboard that records what was asked of it, and from which thread.
final class RecordingPasteboard: PasteboardReading {
    private let lock = NSLock()
    private let _hasStrings: Bool
    private let probableURL: Bool
    private let text: String?
    private(set) var detectCalls = 0
    private(set) var stringReads = 0
    private(set) var clears = 0
    private(set) var readOnMainThread: Bool?

    init(hasStrings: Bool, probableURL: Bool, text: String?) {
        self._hasStrings = hasStrings
        self.probableURL = probableURL
        self.text = text
    }

    var hasStrings: Bool { _hasStrings }

    func detectProbableWebURL(completion: @escaping (Bool) -> Void) {
        lock.lock(); detectCalls += 1; lock.unlock()
        // The system calls back on an arbitrary queue; the main queue is the worst case.
        DispatchQueue.main.async { completion(self.probableURL) }
    }

    var string: String? {
        lock.lock(); defer { lock.unlock() }
        stringReads += 1
        readOnMainThread = Thread.isMainThread
        return text
    }

    func clear() { lock.lock(); clears += 1; lock.unlock() }
}
