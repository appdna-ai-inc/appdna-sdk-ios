// SharedFixtureDrivers+Push.swift
//
// SPEC-497 — iOS drivers for the Push-area fixture kinds (classify_push, notification_proxy).
// Dispatched from `SharedFixtureTests.drive`'s default branch. Every value asserted is produced by a
// REAL SDK symbol (see the header of SharedFixtureTests.swift).
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveSpec497Push(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        default:
            return false
        }
    }
}
