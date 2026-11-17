import XCTest
@testable import AppDNASDK

/**
 The comparison table's column headers, from both shapes `columns` arrives in.

 ## The defect this locks

 `columns` is the fallback key for `table_columns`, and the two platforms accepted different shapes
 for it: iOS took a plain array of label strings, Android took an array of objects. Each dropped the
 other's shape entirely, so a table authored either way rendered its headers on exactly one
 platform. Measured on dev: 2 of 2 comparison tables carry `columns` as a STRING array — one of
 them on an ACTIVE paywall — so Android was shipping a comparison table with no column headers.

 ## Why these assertions and not a rendered frame

 The header labels draw in `PaywallTextDefaults.readable(on:)`, a colour the author does not choose
 and the rest of the page is full of, so the pixel harness cannot tell "the header drew" from "the
 page drew". The resolution moved out of the view body to be callable, which is the only reason
 this can be asserted at all — see `PaywallTableColumns`.

 The Android twin is `PaywallTableColumnsTest.kt`; the two are different code, so one green says
 nothing about the other.
 */
final class PaywallTableColumnsTests: XCTestCase {

    // MARK: - The live shape, which iOS already took and Android did not

    func testPlainStringArray() {
        let r = PaywallTableColumns.resolve(structured: nil, fallback: ["Free", "Premium"])
        XCTAssertEqual(r.labels, ["Free", "Premium"])
        XCTAssertEqual(r.highlights, [false, false], "a plain label carries no highlight")
    }

    // MARK: - The shape iOS used to drop

    func testObjectArray() {
        let r = PaywallTableColumns.resolve(
            structured: nil,
            fallback: [
                ["label": "Free"],
                ["label": "Premium", "highlighted": true],
            ],
        )
        XCTAssertEqual(r.labels, ["Free", "Premium"])
        XCTAssertEqual(r.highlights, [false, true], "the object form is the only one that can highlight")
    }

    /**
     A mixed array is honoured element by element. The alternative — refusing the whole array
     because one element has the other spelling — turns a single hand-edited entry into an erased
     header row, which is the defect this fixes rather than a stricter version of it.
     */
    func testMixedArray() {
        let r = PaywallTableColumns.resolve(
            structured: nil,
            fallback: ["Free", ["label": "Premium", "highlighted": true]],
        )
        XCTAssertEqual(r.labels, ["Free", "Premium"])
        XCTAssertEqual(r.highlights, [false, true])
    }

    // MARK: - Precedence

    func testStructuredWinsOverFallback() {
        let r = PaywallTableColumns.resolve(
            structured: [PaywallTableColumn(label: "Starter", highlighted: true, color: nil)],
            fallback: ["Free", "Premium"],
        )
        XCTAssertEqual(r.labels, ["Starter"], "table_columns is canonical and must win")
        XCTAssertEqual(r.highlights, [true])
    }

    /**
     An EMPTY `table_columns` must fall through rather than win. A section that carries
     `table_columns: []` beside a populated `columns` is exactly the half-migrated document the
     fallback exists for, and treating the empty array as an answer renders no headers.
     */
    func testEmptyStructuredFallsThrough() {
        let r = PaywallTableColumns.resolve(structured: [], fallback: ["Free", "Premium"])
        XCTAssertEqual(r.labels, ["Free", "Premium"])
    }

    // MARK: - The negative controls

    /**
     No columns at all must resolve to NO headers — not to a default pair. The console preview
     invents `['Free', 'Pro']` here (`PaywallPreview.tsx`), which is why the gap was invisible in
     the console; the SDK must not join it, or a table with no authored headers would claim two.
     */
    func testNoColumnsResolvesToNone() {
        XCTAssertEqual(PaywallTableColumns.resolve(structured: nil, fallback: nil).labels, [])
        XCTAssertEqual(PaywallTableColumns.resolve(structured: [], fallback: nil).labels, [])
        XCTAssertEqual(PaywallTableColumns.resolve(structured: nil, fallback: []).labels, [])
    }

    /// A `columns` that is a NUMBER is the icon-grid / features column count sharing the key — it
    /// must not become a header, and must not crash the cast.
    func testNumericColumnsIsNotAHeader() {
        XCTAssertEqual(PaywallTableColumns.resolve(structured: nil, fallback: 3).labels, [])
    }

    /// Labels and highlights are read positionally by the view, so they must never differ in count.
    func testLabelsAndHighlightsStayAligned() {
        for fallback in [["Free", "Premium"], ["Free", 7, ["label": "Pro"]]] as [[Any]] {
            let r = PaywallTableColumns.resolve(structured: nil, fallback: fallback)
            XCTAssertEqual(r.labels.count, r.highlights.count, "positional arrays drifted apart")
        }
    }
}
