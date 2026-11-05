import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 OPERATES the real message views through the accessibility tree (the `HostedStep` harness): the close
 text is found by its label and activated, the authored buttons are activated, and the controller both
 hosts present is read. The shared fixture pins the rule and `MessageDismissRenderTests` the pixels; this
 is whether the controls exist and do what they say. Every "it is gone" has its control in the same test.
 A tap on a modal's backdrop is not reachable this way: it is no accessibility element.
*/
@MainActor
final class MessageDismissOperateTests: XCTestCase {

    private func config(_ type: String, _ extra: String) throws -> MessageConfig {
        let json = """
        { "name": "synthetic", "message_type": "\(type)",
          "content": { "title": "A synthetic title", "cta_text": "Primary action", "secondary_cta_text": "Secondary action",
                       "background_color": "#FFFFFF"\(extra) },
          "trigger_rules": { "event": "e" } }
        """
        return try JSONDecoder().decode(MessageConfig.self, from: Data(json.utf8))
    }

    private final class Calls { var cta = 0; var dismiss = 0 }

    private func show(_ c: MessageConfig) -> (HostedStep, Calls) {
        let calls = Calls()
        let hosted = HostedStep(MessageRenderer(messageId: "m", config: c, onCTATap: { calls.cta += 1 }, onDismiss: { calls.dismiss += 1 }))
        hosted.spin(0.6)
        return (hosted, calls)
    }

    func testDismissTextIsGatedLikeTheCloseControl() throws {
        for type in ["modal", "fullscreen"] {
            // CONTROL: allowed → the harness sees it, and activating it dismisses.
            let (a, aCalls) = show(try config(type, #", "dismiss_allowed": true, "dismiss_text": "Not now""#))
            XCTAssertTrue(a.has(label: "Not now"), "[\(type)] control; labels: \(a.labels())")
            a.tap("dismiss text") { $0 == "Not now" }
            XCTAssertEqual(aCalls.dismiss, 1, "[\(type)] control: it dismisses")
            a.close()

            let (b, _) = show(try config(type, #", "dismiss_allowed": false, "dismiss_text": "Not now""#))
            XCTAssertFalse(b.has(label: "Not now"), "[\(type)] not dismissable: \(b.labels())")
            b.close()

            let (d, _) = show(try config(type, #", "dismiss_delay": 2, "dismiss_text": "Not now""#))
            XCTAssertFalse(d.has(label: "Not now"), "[\(type)] inside the delay: \(d.labels())")
            XCTAssertTrue(d.wait(4) { d.has(label: "Not now") }, "[\(type)] it appears after the delay")
            d.close()
        }
    }

    func testAuthoredButtonsStayAndWorkWhenNotDismissable() throws {
        for type in ["modal", "fullscreen", "banner", "tooltip"] {
            let (h, calls) = show(try config(type, #", "dismiss_allowed": false"#))
            XCTAssertTrue(h.tap("secondary CTA") { $0 == "Secondary action" }, "[\(type)]")
            let (h2, calls2) = (h, calls)
            XCTAssertEqual(calls2.dismiss, 1, "[\(type)] the secondary CTA closes a non-dismissable message")
            XCTAssertTrue(h2.tap("CTA") { $0 == "Primary action" }, "[\(type)]")
            XCTAssertEqual(calls2.cta, 1, "[\(type)] the CTA still works")
            h.close()
        }
    }

    func testTheControllerRefusesSystemDismissalOnlyWhenNotDismissable() throws {
        func host(_ c: MessageConfig) -> UIViewController { MessageHosting.makeHost(rootView: EmptyView(), config: c) }
        XCTAssertFalse(host(try config("modal", #", "dismiss_allowed": true"#)).isModalInPresentation, "control")
        XCTAssertFalse(host(try config("modal", "")).isModalInPresentation, "absent → dismissable")
        XCTAssertTrue(host(try config("modal", #", "dismiss_allowed": false"#)).isModalInPresentation)
        XCTAssertTrue(host(try config("fullscreen", #", "dismiss_allowed": false"#)).isModalInPresentation)
        XCTAssertEqual(host(try config("fullscreen", "")).modalPresentationStyle, .fullScreen)
        XCTAssertEqual(host(try config("banner", "")).modalPresentationStyle, .overCurrentContext)
        // No button at all: the switch cannot trap the user, so the controller does not refuse either.
        let noButton = try JSONDecoder().decode(MessageConfig.self, from: Data(#"{ "message_type": "modal", "content": { "title": "t", "dismiss_allowed": false } }"#.utf8))
        XCTAssertFalse(host(noButton).isModalInPresentation)
    }
}
