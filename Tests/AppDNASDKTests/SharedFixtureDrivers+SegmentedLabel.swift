import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // resolve_segmented_label REAL: the constant `FormInputSegmentedBlock` limits its labels with
    // (`SegmentedLabelWrapRenderTests` proves the view draws it).
    func runSegmentedLabel(_ f: Fixture, _ h: Harness) {
        h.state["max_lines"] = segmentedLabelMaxLines
    }
}
