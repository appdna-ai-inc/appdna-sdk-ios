// ConfigurationIssueReporterTests.swift
//
// A DROPPED BLOCK REACHES SOMEBODY, AND SAYS WHAT WAS WRONG.
//
// An earlier change made the decode lenient and logged each drop with its coding path. Nothing left the device,
// so a customer could not report what their console was producing and neither could we — nobody
// could answer "how often is this happening in the field".
//
// 🔴 The assertion that matters is not "something was reported". It is that the report carries the
// CODING PATH. "dropped 4 of 5" is what the first version of the log said, and it tells an engineer
// that something is wrong and nothing about what — which is how this class of defect stayed
// invisible for months.
import XCTest
@testable import AppDNASDK

private final class RecordingLifecycleDelegate: AppDNALifecycleDelegate {
    var issues: [(surface: String, id: String?, detail: String)] = []
    func onConfigurationIssue(surface: String, id: String?, detail: String) {
        issues.append((surface, id, detail))
    }
}

/// One malformed element inside an otherwise fine array.
private struct Block: Decodable { let id: String; let size: Int }
private struct Step: Decodable {
    let blocks: [Block]?
    enum CodingKeys: String, CodingKey { case blocks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decodeLenientArray(Block.self, forKey: .blocks, in: "step.blocks")
    }
}

final class ConfigurationIssueReporterTests: XCTestCase {

    private var delegate: RecordingLifecycleDelegate!

    override func setUp() {
        super.setUp()
        ConfigurationIssueReporter.resetForTesting()
        delegate = RecordingLifecycleDelegate()
        AppDNA.lifecycleDelegate = delegate
    }

    override func tearDown() {
        AppDNA.lifecycleDelegate = nil
        ConfigurationIssueReporter.resetForTesting()
        super.tearDown()
    }

    /// Decode a step whose second block has a string where an Int belongs.
    private func decodeStepWithOneBadBlock() throws -> Step {
        let json = """
        { "blocks": [ { "id": "a", "size": 1 }, { "id": "b", "size": "not an int" } ] }
        """
        return try JSONDecoder().decode(Step.self, from: Data(json.utf8))
    }

    func testTheGoodBlockSurvivesAndTheBadOneIsDropped() throws {
        let step = try decodeStepWithOneBadBlock()
        XCTAssertEqual(step.blocks?.count, 1, "the rest of the array must still render")
        XCTAssertEqual(step.blocks?.first?.id, "a")
    }

    func testTheHostIsToldWhichFieldWasWrong() throws {
        _ = try decodeStepWithOneBadBlock()

        let told = expectation(description: "delegate called")
        DispatchQueue.main.async { told.fulfill() }   // the reporter hops to main; queue behind it
        wait(for: [told], timeout: 2)

        XCTAssertEqual(delegate.issues.count, 1, "exactly one report for one decode that dropped")
        let issue = try XCTUnwrap(delegate.issues.first)
        XCTAssertEqual(issue.surface, "step.blocks")

        // 🔴 THE POINT OF THE WHOLE ISSUE. Not "a block was dropped" — WHICH key, and why.
        XCTAssertTrue(
            issue.detail.contains("[1].size"),
            "the report must name the coding path of the field that was wrong; got: \(issue.detail)"
        )
        XCTAssertFalse(
            issue.detail.isEmpty,
            "a count with no path is the thing this issue exists to stop"
        )
    }

    /**
     🔴 RATE-LIMITED, and the control is in the same test.

     One malformed document is decoded on every bootstrap and every presentation. An unbounded
     report would bill a customer for thousands of identical events and drown their crash
     reporter — so the same surface + detail is reported once per process. The second half asserts
     that a DIFFERENT problem still gets through, because a reporter that silently swallowed
     everything after the first would pass the first assertion alone.
     */
    func testTheSameProblemIsReportedOnce() throws {
        _ = try decodeStepWithOneBadBlock()
        _ = try decodeStepWithOneBadBlock()
        _ = try decodeStepWithOneBadBlock()

        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(delegate.issues.count, 1, "three identical decodes, one report")

        // The control: a different coding path is a different problem and must be reported.
        let other = """
        { "blocks": [ { "id": "a" } ] }
        """
        _ = try JSONDecoder().decode(Step.self, from: Data(other.utf8))
        let second = expectation(description: "second report")
        DispatchQueue.main.async { second.fulfill() }
        wait(for: [second], timeout: 2)

        XCTAssertEqual(
            delegate.issues.count, 2,
            "a DIFFERENT failure must still be reported — otherwise the rate limit is a mute button"
        )
    }

    /// A clean document reports nothing, so the signal means something.
    func testACleanDecodeReportsNothing() throws {
        let json = """
        { "blocks": [ { "id": "a", "size": 1 }, { "id": "b", "size": 2 } ] }
        """
        let step = try JSONDecoder().decode(Step.self, from: Data(json.utf8))
        XCTAssertEqual(step.blocks?.count, 2)

        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(delegate.issues.isEmpty, "nothing was dropped, so nothing is reported")
    }
}
