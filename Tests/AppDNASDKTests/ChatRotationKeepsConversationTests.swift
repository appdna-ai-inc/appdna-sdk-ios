// ChatRotationKeepsConversationTests.swift
//
// A rotation (a size and size-class change) keeps an interactive chat step's state. The flow host is
// rendered in a real key window, text is typed into the chat's composer, and the window is turned to
// landscape and back; the composer must still hold the text.
//
// The composer's text is read because it is the part of the chat's state a test can see: the bubbles
// sit in a lazy stack that publishes no accessibility elements in a package test. Every part of the
// conversation (the bubbles, the turn count, the quick replies, the composer) is `@State` of the same
// `ChatStepView`, so they are kept or lost together: a rotation that kept the composer kept the
// conversation, and one that rebuilt the view would empty the composer.
//
// The step has no webhook, so nothing leaves the test. The negative control builds the flow host
// afresh, which is what losing the step's state looks like: the composer is empty.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class ChatRotationKeepsConversationTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func flow() throws -> OnboardingFlowConfig {
        let json = #"{"id":"chat_rotation_probe","name":"Chat rotation probe","version":1,"steps":[{"id":"s_chat","type":"interactive_chat","config":{"title":"Chat","chat_config":{"max_user_turns":5,"auto_messages":[{"id":"am_hello","turn":0,"delay_ms":0,"content":"Hello from the guide"}]}}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
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

    private func field(_ v: UIView) -> UITextField? {
        if let tf = v as? UITextField { return tf }
        for s in v.subviews { if let f = field(s) { return f } }
        return nil
    }

    /// Types as a keystroke does: the text, then the field's own editingChanged targets (a package
    /// test has no UIApplication, so `sendActions` dispatches nothing) and its change notification.
    private func type(_ text: String, in hosted: HostedStep) {
        guard let tf = field(hosted.host.view) else { return XCTFail("no composer") }
        _ = tf.becomeFirstResponder()
        tf.text = text
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
        NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: tf)
        _ = tf.delegate?.textField?(tf, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "")
        tf.delegate?.textFieldDidChangeSelection?(tf)
        hosted.spin(0.3)
    }

    private func turn(_ hosted: HostedStep, landscape: Bool) {
        hosted.window.frame = landscape ? CGRect(x: 0, y: 0, width: 852, height: 393) : CGRect(x: 0, y: 0, width: 393, height: 852)
        if #available(iOS 17.0, *) {
            hosted.host.traitOverrides.verticalSizeClass = landscape ? .compact : .regular
            hosted.host.traitOverrides.horizontalSizeClass = landscape ? .regular : .compact
        }
        hosted.host.view.setNeedsLayout()
        hosted.host.view.layoutIfNeeded()
        hosted.spin(0.5)
    }

    func testARotationKeepsTheChatState() throws {
        let f = try flow()
        let hosted = HostedStep(host(f))
        defer { hosted.close() }
        XCTAssertTrue(hosted.wait(5) { self.field(hosted.host.view) != nil }, "the chat's composer is on screen")

        type("And trai", in: hosted)
        XCTAssertEqual(field(hosted.host.view)?.text, "And trai", "the typing landed in the composer")
        XCTAssertFalse(hosted.has(label: "Type your message..."), "control: the placeholder goes once the composer holds text")

        turn(hosted, landscape: true)
        XCTAssertEqual(hosted.window.bounds.width, 852, "the window is landscape")
        XCTAssertEqual(field(hosted.host.view)?.text, "And trai", "a rotation keeps the chat's state")
        turn(hosted, landscape: false)
        XCTAssertEqual(field(hosted.host.view)?.text, "And trai", "and turning back keeps it")
        XCTAssertFalse(hosted.has(label: "Type your message..."))

        // Negative control: a flow host built afresh starts with an empty composer.
        hosted.close()
        let fresh = HostedStep(host(f))
        defer { fresh.close() }
        XCTAssertTrue(fresh.wait(5) { self.field(fresh.host.view) != nil })
        XCTAssertEqual(field(fresh.host.view)?.text ?? "", "", "control: a rebuilt host has lost the chat's state")
        XCTAssertTrue(fresh.has(label: "Type your message..."))
    }
}
