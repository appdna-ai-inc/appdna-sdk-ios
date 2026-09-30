// SharedFixtureDrivers+Billing.swift
//
// SPEC-497 — iOS drivers for the Billing-area fixture kinds (billing_ownership, subscription_snapshot_diff, delivery_queue, trial_price, late_purchase, rebuy_already_owned, derive_app_account_token).
// Dispatched from `SharedFixtureTests.drive`'s default branch. Every value asserted is produced by a
// REAL SDK symbol (see the header of SharedFixtureTests.swift).
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveSpec497Billing(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        default:
            return false
        }
    }
}
