// PendingMessageFollowTests.swift
//
// A journey's in-app step to an anonymous user was marked sent and never drawn: the listener started only at
// identify. These tests pin the rule (`listenIds`) and run the shared fixture's script through the real listener
// twice — once as the SDK now follows identity, once with the previous rule (nothing before identify, the user id
// only after it) as the RED CONTROL: the same harness must see that rule lose the anonymous deliveries, or a green
// run of the fixture proves nothing.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

final class PendingMessageFollowTests: XCTestCase {

    private func fixtureAction() throws -> [String: SharedFixtureTests.AnyJSON] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var file: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(
                "sdk-shared-fixtures/action_dispatch/pending_messages_follow_identity.fixture.json")
            let sibling = dir.appendingPathComponent(
                "packages/sdk-shared-fixtures/action_dispatch/pending_messages_follow_identity.fixture.json")
            if FileManager.default.fileExists(atPath: candidate.path) { file = candidate; break }
            if FileManager.default.fileExists(atPath: sibling.path) { file = sibling; break }
            dir.deleteLastPathComponent()
        }
        if file == nil, let env = ProcessInfo.processInfo.environment["APPDNA_SDK_FIXTURES_DIR"] {
            file = URL(fileURLWithPath: env).appendingPathComponent("action_dispatch/pending_messages_follow_identity.fixture.json")
        }
        let url = try XCTUnwrap(file, "pending_messages_follow_identity.fixture.json not found")
        let root = try JSONDecoder().decode(SharedFixtureTests.AnyJSON.self, from: Data(contentsOf: url))
        return try XCTUnwrap(root.objectValue?["action"]?.objectValue)
    }

    func testListenIdsFollowIdentity() {
        XCTAssertEqual(PendingMessageListener.listenIds(anonId: "a", userId: nil), ["a"])
        XCTAssertEqual(PendingMessageListener.listenIds(anonId: "a", userId: "u"), ["a", "u"])
        XCTAssertEqual(PendingMessageListener.listenIds(anonId: "a", userId: "a"), ["a"])
        XCTAssertEqual(PendingMessageListener.listenIds(anonId: "a", userId: ""), ["a"])
        XCTAssertEqual(PendingMessageListener.listenIds(anonId: nil, userId: "u"), ["u"])
    }

    func testFixtureScriptShowsAnonymousAndIdentifiedDeliveriesOnce() throws {
        let state = try XCTUnwrap(SharedFixtureTests.runPendingFollowScript(try fixtureAction()))
        XCTAssertEqual(state["presented"] as? [String], ["anon-1/d1", "user-1/d2", "anon-1/d3", "anon-1/d5"])
        XCTAssertEqual(state["unconsumed"] as? [String], ["user-1/d4"])
    }

    /// RED CONTROL — the previous rule through the same listener and rig: only the delivery addressed to the user id
    /// after identify is drawn; the one written before launch, the anonymous enrolment's later step and the one after
    /// sign-out are all lost, and stay unconsumed.
    func testRedControlUserOnlyRuleLosesAnonymousDeliveries() throws {
        let state = try XCTUnwrap(SharedFixtureTests.runPendingFollowScript(try fixtureAction(), legacyUserOnly: true))
        XCTAssertEqual(state["presented"] as? [String], ["user-1/d2"])
        XCTAssertEqual(state["unconsumed"] as? [String], ["anon-1/d1", "anon-1/d3", "anon-1/d5", "user-1/d4"])
    }
}
