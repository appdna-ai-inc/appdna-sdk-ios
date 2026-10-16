// SharedFixtureDrivers+Style.swift
//
// iOS driver for the styling fixture kinds. Dispatched from `SharedFixtureTests.drive`'s default
// branch. Every value asserted is produced by a REAL SDK symbol:
//
//   parse_colour   REAL: `Color(hex:)` in Paywalls/PaywallHelperViews.swift — the SDK's only colour
//                  parser on this platform, read back through UIColor so the fixture can compare
//                  0-255 channels against Android's.
//
// #885. The pairing this fixture exists for: Android's `StyleEngine.parseColor` and this
// initialiser must answer the same thing for the same string. They did not. Android's paywall and
// survey renderers each carried a private copy that read 8-char hex as ARGB rather than RGBA and
// fell back to black / white rather than transparent, and this side rendered a six-letter CSS
// colour name as opaque black where Android returned transparent.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    func driveStyle(_ f: Fixture, _ h: Harness) async -> Bool {
        switch f.action.kind {
        case "parse_colour": runParseColour(f, h)
        default:
            return false
        }
        return true
    }

    // MARK: parse_colour

    private func runParseColour(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] parse_colour needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            guard let value = c.objectValue?["value"]?.stringValue else {
                XCTFail("[\(f.id)] parse_colour case without a string value")
                return NSNull()
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            // `getRed` returns false only for a colour outside a compatible colour space; every
            // value `Color(hex:)` can produce is sRGB or `.clear`, so a false here is a real defect
            // rather than a quirk to tolerate.
            guard UIColor(Color(hex: value)).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                XCTFail("[\(f.id)] parse_colour: '\(value)' produced a colour with no sRGB components")
                return NSNull()
            }
            return [Int((r * 255).rounded()), Int((g * 255).rounded()),
                    Int((b * 255).rounded()), Int((a * 255).rounded())]
        }
    }
}
