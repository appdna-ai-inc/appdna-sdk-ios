// RotationKeepsTypedTextTests.swift
//
// A rotation (a size and size-class change) keeps the text the user typed on the open step and has
// not submitted yet: the flow host is rendered in a real key window, text is typed into the step's
// UIKit text field, the window is turned to landscape with a compact vertical size class and back,
// and the field must still show the text.
//
// What the field shows after the turn is the step's state, not text left behind in the UIKit view:
// the size-class change re-renders the step, and a re-render writes the bound value into the field
// (`UIKitTextField.updateUIView`; SwiftUI's `TextField` does the same). A step that lost its state
// would show an empty field.
//
// The negative control in each test rebuilds the flow host from scratch in the same window, which
// is what losing the step's state looks like: the field comes back empty. It proves the harness can
// see a loss.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class RotationKeepsTypedTextTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func flow(_ stepJSON: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"rotation_probe","name":"Rotation probe","version":1,"steps":["# + stepJSON
            + #",{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    private func host(_ flow: OnboardingFlowConfig) -> AnyView {
        AnyView(OnboardingFlowHost(
            flow: flow,
            delegate: nil,
            eventTracker: nil,
            onStepViewed: { _, _ in },
            onStepCompleted: { _, _, _ in },
            onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in },
            onFlowDismissed: { _, _ in }
        ))
    }

    /// A flow host in a real key window, which can be turned to landscape.
    @MainActor
    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow

        init(_ view: AnyView) {
            _ = A11yAutomation.enabled
            host = UIHostingController(rootView: view)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            spin(0.5)
        }

        func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

        func field() -> UITextField? {
            func find(_ v: UIView) -> UITextField? {
                if let tf = v as? UITextField { return tf }
                for s in v.subviews { if let f = find(s) { return f } }
                return nil
            }
            return find(host.view)
        }

        /// Types as a keystroke does: the text, then the field's change notifications and actions.
        func type(_ text: String) {
            guard let tf = field() else { return XCTFail("no text field") }
            _ = tf.becomeFirstResponder()
            tf.text = text
            for target in tf.allTargets {
                for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                    _ = (target as NSObject).perform(Selector(action), with: tf)
                }
            }
            tf.delegate?.textFieldDidChangeSelection?(tf)
            NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: tf)
            spin(0.2)
        }

        /// A rotation to landscape: the window's size and the vertical size class change.
        func rotateToLandscape() {
            window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
            if #available(iOS 17.0, *) {
                host.traitOverrides.verticalSizeClass = .compact
                host.traitOverrides.horizontalSizeClass = .regular
            }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spin(0.5)
        }

        /// Back to portrait, as the user turns the phone back.
        func rotateToPortrait() {
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            if #available(iOS 17.0, *) {
                host.traitOverrides.verticalSizeClass = .regular
                host.traitOverrides.horizontalSizeClass = .compact
            }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spin(0.5)
        }

        func close() { window.isHidden = true }
    }

    private func assertKept(stepJSON: String) throws {
        let f = try flow(stepJSON)
        let hosted = Hosted(host(f))
        defer { hosted.close() }

        hosted.type("Ada Lovelace")
        XCTAssertEqual(hosted.field()?.text, "Ada Lovelace", "the typing landed in the field")

        hosted.rotateToLandscape()
        XCTAssertEqual(hosted.window.bounds.width, 852, "the window is landscape")
        XCTAssertEqual(hosted.field()?.text, "Ada Lovelace", "a rotation must keep the typed text")

        hosted.rotateToPortrait()
        XCTAssertEqual(hosted.field()?.text, "Ada Lovelace", "and turning back keeps it")

        // Negative control: the same flow host built again in the same window loses the step's state.
        hosted.host.rootView = AnyView(host(f).id(UUID()))
        hosted.spin(0.5)
        XCTAssertEqual(hosted.field()?.text ?? "", "", "control: a rebuilt host shows an empty field")
    }

    func testARotationKeepsTheTextTypedIntoAnInputBlock() throws {
        try assertKept(
            stepJSON: #"{"id":"s_blocks","type":"custom","config":{"content_blocks":[{"id":"b_name","type":"input_text","field_id":"name","field_label":"Name"},{"id":"b_go","type":"button","text":"Continue","action":"next","zone":"bottom"}]}}"#
        )
    }

    func testARotationKeepsTheTextTypedIntoAFormField() throws {
        try assertKept(
            stepJSON: #"{"id":"s_form","type":"form","config":{"cta_text":"Continue","fields":[{"id":"city","type":"text","label":"City"}]}}"#
        )
    }
}
