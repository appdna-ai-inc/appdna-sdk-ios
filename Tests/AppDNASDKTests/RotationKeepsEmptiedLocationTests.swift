// RotationKeepsEmptiedLocationTests.swift
//
// A location field the user emptied stays empty across a rotation. The form step seeds its fields
// from the step's submitted answers when it appears; a size and size-class change must not seed them
// again, or a field the user cleared would come back holding the old answer (Google's line).
//
// The form step is rendered in a real key window with a submitted Google answer, the field is cleared
// twice as a keystroke clears it (the first clear restarts from the typed query, the second empties
// it), and the window is turned to landscape and back. The negative control rebuilds the step in the
// same window, which is what a reseed looks like: the field shows the submitted answer again.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class RotationKeepsEmptiedLocationTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private let google: [String: Any] = [
        "formatted_address": "Synthetic Line 1, Town", "address": "Synthetic Line 1, Town",
        "place_id": "place_synthetic", "raw_query": "typed q",
    ]

    private func step() throws -> AnyView {
        let config = try JSONDecoder().decode(
            StepConfig.self,
            from: Data(#"{"fields":[{"id":"where","type":"location","label":"Where"}]}"#.utf8)
        )
        return AnyView(FormStepView(config: config, onNext: { _ in }, apiClient: nil, savedValues: ["where": google]))
    }

    private func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func field(_ host: UIViewController) -> UITextField? {
        func find(_ v: UIView) -> UITextField? {
            if let tf = v as? UITextField { return tf }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return find(host.view)
    }

    /// Replaces the field's text as a keystroke does, with the field's change actions and notifications.
    private func setText(_ text: String, in host: UIViewController) {
        guard let tf = field(host) else { return XCTFail("no text field") }
        _ = tf.becomeFirstResponder()
        tf.text = text
        // A package test runs with no UIApplication, so `sendActions` dispatches nothing: the field's
        // own editingChanged targets are invoked directly instead.
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
        spin(0.3)
    }

    private func turn(_ host: UIViewController, _ window: UIWindow, landscape: Bool) {
        window.frame = landscape ? CGRect(x: 0, y: 0, width: 852, height: 393) : CGRect(x: 0, y: 0, width: 393, height: 852)
        if #available(iOS 17.0, *) {
            host.traitOverrides.verticalSizeClass = landscape ? .compact : .regular
            host.traitOverrides.horizontalSizeClass = landscape ? .regular : .compact
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        spin(0.5)
    }

    func testALocationFieldTheUserEmptiedStaysEmptyAcrossARotation() throws {
        _ = A11yAutomation.enabled
        let host = UIHostingController(rootView: try step())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        spin(0.5)

        XCTAssertEqual(field(host)?.text, "Synthetic Line 1, Town", "the field shows the submitted answer")
        setText("", in: host)
        XCTAssertEqual(field(host)?.text, "typed q", "the first clear restarts from the typed query")
        setText("", in: host)
        XCTAssertEqual(field(host)?.text ?? "", "", "the second clear empties the field")

        turn(host, window, landscape: true)
        XCTAssertEqual(field(host)?.text ?? "", "", "a rotation must not seed the emptied field again")
        turn(host, window, landscape: false)
        XCTAssertEqual(field(host)?.text ?? "", "", "nor turning back")

        // Negative control: the step built again in the same window seeds from the submitted answer.
        host.rootView = AnyView(try step().id(UUID()))
        spin(0.5)
        XCTAssertEqual(field(host)?.text, "Synthetic Line 1, Town", "control: a rebuilt step shows the submitted answer")
    }
}
