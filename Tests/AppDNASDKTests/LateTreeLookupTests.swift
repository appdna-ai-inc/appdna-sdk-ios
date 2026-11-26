import XCTest
import SwiftUI
@testable import AppDNASDK

/// the render harness's lookups wait for the element they expect, not only for SOME label.
///
/// A full-suite run on a loaded simulator failed `TwoScreenLayoutRenderTests` with `pinned CTA: not found; labels:
/// ["Close", "Name"]`, and earlier runs failed five location and credit tests with `no button for Continue`. Each read
/// a tree that was PART-published: `A11yTree.read` stops at the first label, and `settle()` stops when two reads 50 ms
/// apart agree — both true of a tree whose button has not been published yet. The view below manufactures that state
/// on demand (its button appears 1.5 s after it does), so the harness is tested against it rather than against luck.
@MainActor
final class LateTreeLookupTests: XCTestCase {

    private struct LateButtonView: View {
        let delay: Double
        let onTap: () -> Void
        @State private var shown = false
        var body: some View {
            VStack(spacing: 24) {
                Text("A synthetic heading")
                if shown { Button("Continue", action: onTap) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { shown = true } }
        }
    }

    private static func hasContinue(_ e: [NSObject]) -> Bool {
        e.contains { $0.accessibilityLabel == "Continue" && $0.accessibilityTraits.contains(.button) }
    }

    func testAHostedStepTapWaitsForAButtonPublishedLate() {
        var tapped = 0
        let step = HostedStep(LateButtonView(delay: 1.5, onTap: { tapped += 1 }))
        defer { step.close() }
        // Control: the state the defect needs. The tree has a label, so a plain read accepts it — and has no button yet.
        let early = A11yTree.raw([step.host.view])
        XCTAssertTrue(A11yTree.hasALabel(early), "control: the early tree has a label, so a read that waits for ANY label stops here")
        XCTAssertFalse(Self.hasContinue(early), "control: the early tree has no Continue yet, which is the part-published tree")

        XCTAssertTrue(step.tap("Continue") { $0 == "Continue" }, "the tap waits for the button and activates it")
        XCTAssertTrue(step.wait(2) { tapped == 1 }, "the button's action ran")
    }

    func testTheTwoScreenHostFindsAButtonPublishedAfterTheTreeSettled() {
        var tapped = 0
        let h = TwoScreenLayoutRenderTests.Host(AnyView(LateButtonView(delay: 1.5, onTap: { tapped += 1 })), TwoScreenLayoutRenderTests.phone)
        defer { h.close() }
        // Control: `settle()` has returned (the init ran it) and the tree it settled on is incomplete.
        let settled = A11yTree.raw([h.host.view])
        XCTAssertTrue(A11yTree.hasALabel(settled), "control: settle() returned on a tree with a label")
        XCTAssertFalse(Self.hasContinue(settled), "control: …and without the Continue the view draws a moment later")

        let button = h.button("Continue")
        XCTAssertNotNil(button, "the lookup waits for the late button; labels: \(h.labels())")
        XCTAssertTrue(h.tap(button), "and the button it found is the live one")
        XCTAssertEqual(tapped, 1)
    }

    func testALookupForAnElementThatNeverComesStillFailsWithinItsBound() {
        let h = TwoScreenLayoutRenderTests.Host(AnyView(Text("A synthetic heading")), TwoScreenLayoutRenderTests.phone)
        defer { h.close() }
        let started = Date()
        XCTAssertNil(h.eventually(1) { h.elements().first { $0.accessibilityLabel == "Never drawn" } }, "a missing element is still missing")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "and the wait is bounded")
    }
}
