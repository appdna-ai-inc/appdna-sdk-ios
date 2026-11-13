// ShareActionTests.swift
//
// #1797 — the `share` action, on every surface that can author it:
//
//   - the pure rules (`ShareAction.payload`, `ShareAction.activityItems`);
//   - an onboarding `button` and a Multi-buttons CHILD button, tapped through the accessibility tree
//     of a real step in a real key window: the sheet is presented with the trimmed payload, and the
//     step does NOT advance (no `onNext`);
//   - the in-app message `cta_action: { type: "share", text, url }` decode, and the shared
//     `MessageCTAShare.payload` both message presenters call;
//   - a paywall `extra_buttons[]` entry `action: "share"` + `share_text` + `url`, decoded AND tapped in
//     a real `PaywallRenderer`: the sheet is presented, the paywall stays.
//
// The presentation step (`ShareAction.presenter`) is replaced by a recorder: a package test has no
// connected scene to present a real `UIActivityViewController` into. Everything up to that call is
// the production tap path. All copy and links are synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

// MARK: - The pure rules

final class ShareActionPayloadTests: XCTestCase {

    /// RED CONTROL: drop the `trimmingCharacters` in `ShareAction.trimmed` → the first assertion
    /// fails (the untrimmed text and link come back).
    func testPayloadTrimsBothHalves() {
        XCTAssertEqual(
            ShareAction.payload(text: "  Synthetic text  ", url: " https://example.com/invite "),
            SharePayload(text: "Synthetic text", url: "https://example.com/invite")
        )
    }

    /// RED CONTROL: make `payload` return `SharePayload(text: t, url: u)` unconditionally (drop the
    /// `if t == nil && u == nil { return nil }`) → the three nil assertions fail.
    func testBlankHalvesAreAbsentAndBothBlankIsNothing() {
        XCTAssertEqual(ShareAction.payload(text: "   ", url: "https://example.com/x"),
                       SharePayload(text: nil, url: "https://example.com/x"))
        XCTAssertEqual(ShareAction.payload(text: "Only text", url: " \n "),
                       SharePayload(text: "Only text", url: nil))
        XCTAssertNil(ShareAction.payload(text: "   ", url: nil))
        XCTAssertNil(ShareAction.payload(text: nil, url: nil))
        XCTAssertNil(ShareAction.payload(text: "", url: "  "))
    }

    func testActivityItemsTextThenLink() throws {
        let items = ShareAction.activityItems(SharePayload(text: "Synthetic text", url: "https://example.com/invite"))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0] as? String, "Synthetic text")
        XCTAssertEqual(items[1] as? URL, URL(string: "https://example.com/invite"))
    }

    func testActivityItemsTextOnly() {
        let items = ShareAction.activityItems(SharePayload(text: "Synthetic text", url: nil))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0] as? String, "Synthetic text")
    }

    func testActivityItemsLinkOnly() {
        let items = ShareAction.activityItems(SharePayload(text: nil, url: "https://example.com/invite"))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0] as? URL, URL(string: "https://example.com/invite"))
    }

    /// A link that is not a URL with a scheme is shared as the string authored.
    /// RED CONTROL: drop `parsed.scheme != nil` in `activityItems` → on iOS 17+ `URL(string:)`
    /// accepts "not a link" (percent-encoded), so `items[0] as? String` is nil and this fails.
    func testActivityItemsNonURLLinkIsTheString() {
        let items = ShareAction.activityItems(SharePayload(text: nil, url: "not a link"))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0] as? String, "not a link")
        XCTAssertNil(items[0] as? URL)
    }

    /// `share` is not an advancing press: a button-pressed rule must not see it.
    /// RED CONTROL: add `ShareAction.actionName` to `OnboardingPressedButton.advances` → fails.
    func testShareIsNotAnAdvancingPress() {
        XCTAssertFalse(OnboardingPressedButton.advances(action: ShareAction.actionName))
    }

    /// RED CONTROL: remove `self.share_text = …` / `self.share_url = …` from `ContentBlock.init(from:)`
    /// → both are nil and this fails.
    func testContentBlockDecodesShareFields() throws {
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(
            #"{"id":"b","type":"button","text":"Share","action":"share","share_text":"Synthetic text","share_url":"https://example.com/x"}"#.utf8
        ))
        XCTAssertEqual(block.action, "share")
        XCTAssertEqual(block.share_text, "Synthetic text")
        XCTAssertEqual(block.share_url, "https://example.com/x")
        XCTAssertEqual(ShareAction.authoredText(of: block), "Synthetic text")
    }

    /// A Screens content-block button authored `share` before #1797 carried its text in
    /// `action_value`; with neither new field it still shares that.
    func testLegacyActionValueIsTheTextOnlyWithNeitherField() throws {
        let legacy = try JSONDecoder().decode(ContentBlock.self, from: Data(
            #"{"id":"b","type":"button","action":"share","action_value":"Legacy text"}"#.utf8
        ))
        XCTAssertEqual(ShareAction.authoredText(of: legacy), "Legacy text")
        let linkOnly = try JSONDecoder().decode(ContentBlock.self, from: Data(
            #"{"id":"b","type":"button","action":"share","action_value":"ignored","share_url":"https://example.com/x"}"#.utf8
        ))
        XCTAssertNil(ShareAction.authoredText(of: linkOnly), "a share_url makes it a new-shape share")
    }
}

// MARK: - Onboarding: the production tap path

@MainActor
final class OnboardingShareTapTests: XCTestCase {

    private var savedPresenter: ((SharePayload, UIViewController?) -> Void)?
    private var presented: [SharePayload] = []

    override func setUp() {
        super.setUp()
        presented = []
        savedPresenter = ShareAction.presenter
        ShareAction.presenter = { [weak self] payload, _ in self?.presented.append(payload) }
        OnboardingPressedButton.shared.clear()
    }

    override func tearDown() {
        if let savedPresenter { ShareAction.presenter = savedPresenter }
        OnboardingPressedButton.shared.clear()
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func host(_ json: String, onNext: @escaping ([String: Any]?) -> Void) throws -> HostedStep {
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        return HostedStep(OnboardingStepRouter(step: step, onNext: onNext, onSkip: {}))
    }

    /// A top-level `share` button: the sheet gets the trimmed payload; the step stays. Then the
    /// Continue beside it IS tapped and DOES advance — the control that this harness can see an
    /// advance at all, so "no onNext" is not a blind pass.
    ///
    /// RED CONTROL (presentation): delete the `else if block.action == ShareAction.actionName { … }`
    /// branch in `ContentBlockRendererView.buttonBlock` → `presented` is empty and the first
    /// `XCTAssertEqual(presented, …)` fails.
    /// RED CONTROL (stays): delete that branch AND the `case ShareAction.actionName:` arm of
    /// `OnboardingRenderer.handleBlockAction` → the tap falls to `default`, which advances, and
    /// `XCTAssertTrue(payloads.isEmpty, …)` fails.
    func testATopLevelShareButtonPresentsTheSheetAndStays() throws {
        var payloads: [[String: Any]?] = []
        let step = try host(
            #"{"id":"milestone","type":"custom","config":{"content_blocks":["#
            + #"{"id":"share","type":"button","text":"Share progress","action":"share","share_text":"  Synthetic progress  ","share_url":" https://example.com/invite ","zone":"bottom"},"#
            + #"{"id":"go","type":"button","text":"Continue","action":"next","zone":"bottom"}]}}"#,
            onNext: { payloads.append($0) }
        )
        defer { step.close() }

        step.tap("the share button") { $0 == "Share progress" }
        step.spin(0.5)
        XCTAssertEqual(presented, [SharePayload(text: "Synthetic progress", url: "https://example.com/invite")],
                       "the share sheet was presented with the trimmed payload")
        XCTAssertTrue(payloads.isEmpty, "a share must not advance the step; onNext got \(payloads)")
        XCTAssertNil(OnboardingPressedButton.shared.take(), "a share is not recorded as the advancing press")

        step.tap("Continue") { $0 == "Continue" }
        XCTAssertTrue(step.wait { !payloads.isEmpty }, "CONTROL: the harness sees a real advance")
        XCTAssertEqual(presented.count, 1, "Continue presented nothing")
    }

    /// A `share` button that is a CHILD of Multi-buttons — the same tap site, reached through the
    /// container. Same RED CONTROLS as above.
    func testAMultiButtonsChildShareButtonPresentsTheSheetAndStays() throws {
        var payloads: [[String: Any]?] = []
        let step = try host(
            #"{"id":"milestone","type":"custom","config":{"content_blocks":[{"id":"mb","type":"multi_buttons","zone":"bottom","children":["#
            + #"{"id":"c_share","type":"button","text":"Tell a friend","action":"share","share_url":"https://example.com/child"},"#
            + #"{"id":"c_go","type":"button","text":"Continue","action":"next"}]}]}}"#,
            onNext: { payloads.append($0) }
        )
        defer { step.close() }

        step.tap("the child share button") { $0 == "Tell a friend" }
        step.spin(0.5)
        XCTAssertEqual(presented, [SharePayload(text: nil, url: "https://example.com/child")],
                       "the child's share sheet was presented with the link alone")
        XCTAssertTrue(payloads.isEmpty, "a child share must not advance the step; onNext got \(payloads)")

        step.tap("Continue") { $0 == "Continue" }
        XCTAssertTrue(step.wait { !payloads.isEmpty }, "CONTROL: the child Continue advances")
    }

    /// Blank text and no link: nothing is presented, and the step still does not advance.
    /// RED CONTROL: in `ShareAction.perform`, call `present(SharePayload(text: text, url: url))`
    /// even when `payload` is nil → `presented` is non-empty and this fails.
    func testABlankShareButtonPresentsNothingAndStays() throws {
        var payloads: [[String: Any]?] = []
        let step = try host(
            #"{"id":"milestone","type":"custom","config":{"content_blocks":["#
            + #"{"id":"share","type":"button","text":"Share","action":"share","share_text":"   ","zone":"bottom"}]}}"#,
            onNext: { payloads.append($0) }
        )
        defer { step.close() }

        step.tap("the blank share button") { $0 == "Share" }
        step.spin(0.5)
        XCTAssertTrue(presented.isEmpty, "a blank share presents no sheet; got \(presented)")
        XCTAssertTrue(payloads.isEmpty, "a blank share does not advance either")
    }
}

// MARK: - In-app messages

final class MessageShareCTATests: XCTestCase {

    private func cta(_ json: String) throws -> CTAAction {
        try JSONDecoder().decode(CTAAction.self, from: Data(json.utf8))
    }

    /// RED CONTROL: remove `case share` from `CTAActionType` → "share" decodes to `.unknown` and the
    /// first assertion fails (and `sharePayload` is nil).
    func testAShareCTADecodesTextAndLink() throws {
        let action = try cta(#"{"type":"share","text":"t","url":"u"}"#)
        XCTAssertEqual(action.type, .share)
        XCTAssertEqual(action.text, "t")
        XCTAssertEqual(action.url, "u")
        XCTAssertEqual(action.sharePayload, SharePayload(text: "t", url: "u"))
        XCTAssertEqual(MessageCTAShare.payload(action), SharePayload(text: "t", url: "u"))
        XCTAssertNil(action.linkToOpen, "a share opens no link — its url is shared, not opened")
    }

    func testAShareCTAWithTextOnly() throws {
        let action = try cta(#"{"type":"share","text":"  Synthetic text "}"#)
        XCTAssertEqual(MessageCTAShare.payload(action), SharePayload(text: "Synthetic text", url: nil))
    }

    /// A blank share only dismisses.
    func testABlankShareCTAIsAPlainDismiss() throws {
        XCTAssertNil(MessageCTAShare.payload(try cta(#"{"type":"share","text":"   "}"#)))
        XCTAssertNil(MessageCTAShare.payload(try cta(#"{"type":"share"}"#)))
    }

    /// Unknown and legacy shapes are unchanged — and never share.
    func testUnknownAndLegacyTypesAreUnchanged() throws {
        let unknown = try cta(#"{"type":"teleport","text":"t","url":"https://example.com"}"#)
        XCTAssertEqual(unknown.type, .unknown)
        XCTAssertNil(MessageCTAShare.payload(unknown))
        XCTAssertNil(unknown.linkToOpen)

        let legacyURL = try cta(#"{"type":"url","value":"https://example.com/x"}"#)
        XCTAssertEqual(legacyURL.type, .open_url)
        XCTAssertEqual(legacyURL.linkToOpen, "https://example.com/x")
        XCTAssertNil(MessageCTAShare.payload(legacyURL))

        let bare = try cta(#""dismiss""#)
        XCTAssertEqual(bare.type, .dismiss)
        XCTAssertNil(MessageCTAShare.payload(bare))

        XCTAssertNil(MessageCTAShare.payload(nil))
    }

    /// The share fields survive the cache round trip (`encode` writes `text`).
    /// RED CONTROL: drop `try c.encodeIfPresent(text, forKey: .text)` → `text` is nil after the trip.
    func testShareCTARoundTrips() throws {
        let original = try cta(#"{"type":"share","text":"t","url":"https://example.com/x"}"#)
        let again = try JSONDecoder().decode(CTAAction.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(again.type, .share)
        XCTAssertEqual(again.text, "t")
        XCTAssertEqual(again.url, "https://example.com/x")
    }
}

// MARK: - Paywall extra buttons

@MainActor
final class PaywallShareExtraButtonTests: XCTestCase {

    private var savedPresenter: ((SharePayload, UIViewController?) -> Void)?
    private var presented: [SharePayload] = []

    override func setUp() {
        super.setUp()
        presented = []
        savedPresenter = ShareAction.presenter
        ShareAction.presenter = { [weak self] payload, _ in self?.presented.append(payload) }
    }

    override func tearDown() {
        if let savedPresenter { ShareAction.presenter = savedPresenter }
        super.tearDown()
    }

    private let json = """
    {
      "id": "share_extra_button",
      "layout": {
        "type": "stack",
        "background": { "type": "color", "value": "#FFFFFF" },
        "sections": [
          { "type": "header", "config": { "title": "Synthetic plan" } },
          { "type": "cta", "config": {
              "cta": { "text": "Continue" },
              "extra_buttons": [
                { "text": "Share this", "action": "share", "share_text": "  Synthetic share  ", "url": " https://example.com/p " },
                { "text": "Maybe later", "action": "dismiss", "style": "text" }
              ]
          } }
        ]
      }
    }
    """

    /// RED CONTROL: remove `let share_text: String?` from `PaywallExtraButton` → `share_text` is
    /// unavailable (compile) — or, to see it red at runtime, decode with the key renamed — and the
    /// share_text assertion fails.
    func testAShareExtraButtonDecodes() throws {
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        let extras = try XCTUnwrap(config.sections.first(where: { $0.type == "cta" })?.data?.extraButtons)
        XCTAssertEqual(extras.count, 2)
        XCTAssertEqual(extras[0].action, "share")
        XCTAssertEqual(extras[0].share_text, "  Synthetic share  ")
        XCTAssertEqual(extras[0].url, " https://example.com/p ")
        XCTAssertNil(extras[1].share_text)
    }

    /// Tapping the share extra button in a real `PaywallRenderer` presents the sheet with the trimmed
    /// payload; the paywall stays (`onDismiss` never runs). The "Maybe later" dismiss button beside it
    /// is the control that this harness can see a dismiss.
    ///
    /// RED CONTROL: delete the `case ShareAction.actionName:` arm in
    /// `PaywallRenderer.performButtonAction(_:url:shareText:default:)` → the tap reaches `default`,
    /// which reports `.custom` and purchases; `presented` is empty and the first assertion fails.
    /// RED CONTROL (text): pass `shareText: nil` from `extraButtonsView` → the payload has no text.
    func testTappingAShareExtraButtonPresentsTheSheetAndThePaywallStays() throws {
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        var dismissed = 0
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in dismissed += 1 }
        )
        let hosted = HostedStep(view)
        defer { hosted.close() }

        hosted.tap("the share extra button") { $0 == "Share this" }
        hosted.spin(0.5)
        XCTAssertEqual(presented, [SharePayload(text: "Synthetic share", url: "https://example.com/p")],
                       "the share sheet was presented over the paywall with the trimmed payload")
        XCTAssertEqual(dismissed, 0, "a share must not close the paywall")

        hosted.tap("Maybe later") { $0 == "Maybe later" }
        XCTAssertTrue(hosted.wait { dismissed == 1 }, "CONTROL: the harness sees a dismiss")
        XCTAssertEqual(presented.count, 1)
    }
}
