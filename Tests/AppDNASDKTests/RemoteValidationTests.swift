// RemoteValidationTests.swift
//
// Live validation — live validation through the host.
//  * A validated text input strokes the colour of its state: the REAL `FormInputTextBlock`, reading the REAL
//    `RemoteValidationCoordinator` through `\.appdnaRemoteValidation`, drawn in a key window and its pixels read.
//  * The protocol's default `onValidateInput` tells the step the host does not implement it (the task-local probe), a
//    host's own method does not, and the router's production wiring turns the default into "no delegate" at once.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class RemoteValidationTests: XCTestCase {
    private func block() throws -> ContentBlock {
        let json = ##"{"id":"name","type":"input_text","field_id":"name","field_placeholder":"Name","field_config":{"remote_validation":{"enabled":true}},"field_style":{"border_color":"#00FF00","error_border_color":"#FF00FF","valid_border_color":"#00FFFF","border_width":3}}"##
        return try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    private func coordinator(_ answer: InputValidationResult?, hasHost: Bool = true) -> RemoteValidationCoordinator {
        RemoteValidationCoordinator(
            schedule: { _, _ in {} },
            hasHost: { hasHost },
            startCall: { _, _, _, complete in complete(.answered(answer)); return {} }
        )
    }

    private func counts(_ c: RemoteValidationCoordinator) async throws -> (magenta: Int, green: Int, cyan: Int) {
        let b = try block()
        c.valueChanged("name", "somebody", config: try XCTUnwrap(RemoteValidationConfig.of(b)), immediate: true)
        let size = CGSize(width: 360, height: 140)
        let env = RemoteValidationEnv(coordinator: c, fields: c.fields, ctaWaiting: false, drawsProgress: true)
        let view = FormInputTextBlock(block: b, inputValues: .constant(["name": "somebody"]), keyboardType: .default)
            .environment(\.appdnaRemoteValidation, env)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var magenta = 0, green = 0, cyan = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = px[i], g = px[i + 1], b = px[i + 2]
            if r > 220, g < 40, b > 220 { magenta += 1 }
            if r < 40, g > 220, b < 40 { green += 1 }
            if r < 40, g > 220, b > 220 { cyan += 1 }
        }
        return (magenta, green, cyan)
    }

    func testEachAnswerStrokesItsBorderColour() async throws {
        let none = try await counts(coordinator(nil, hasHost: false))
        XCTAssertGreaterThan(none.green, 500, "control: with no delegate the field strokes its resting colour")
        XCTAssertEqual(none.magenta + none.cyan, 0, "control: and no state colour")
        let invalid = try await counts(coordinator(.invalid(message: "Already taken")))
        XCTAssertGreaterThan(invalid.magenta, 500, "invalid strokes error_border_color")
        XCTAssertEqual(invalid.green, 0, "invalid is not the resting colour")
        let valid = try await counts(coordinator(.valid()))
        XCTAssertGreaterThan(valid.cyan, 500, "valid strokes valid_border_color")
    }

    // MARK: The default implementation

    private final class Bare: AppDNAOnboardingDelegate {}
    private final class Validating: AppDNAOnboardingDelegate {
        func onValidateInput(flowId: String, stepId: String, fieldId: String, value: String) async -> InputValidationResult? {
            .invalid(message: "taken")
        }
    }

    func testTheDefaultImplementationMarksNotImplementedAndAHostsOwnDoesNot() async {
        let bareBox = RemoteValidationProbe.Box()
        let bare = await RemoteValidationProbe.$box.withValue(bareBox) {
            await Bare().onValidateInput(flowId: "f", stepId: "s", fieldId: "x", value: "v")
        }
        XCTAssertNil(bare)
        XCTAssertTrue(bareBox.notImplemented, "the default body must tell the step the host does not validate")
        let ownBox = RemoteValidationProbe.Box()
        let own = await RemoteValidationProbe.$box.withValue(ownBox) {
            await Validating().onValidateInput(flowId: "f", stepId: "s", fieldId: "x", value: "v")
        }
        XCTAssertEqual(own, .invalid(message: "taken"))
        XCTAssertFalse(ownBox.notImplemented, "a host's own method is not the default")
    }

    func testTheRoutersWiringTurnsTheDefaultIntoNoDelegate() async throws {
        let host = Bare()
        var warnings = 0
        let c = OnboardingStepRouter.makeRemoteValidation(delegate: host, flowId: "f", stepId: "s", tracker: nil)
        c.warn = { _ in warnings += 1 }
        let config = try XCTUnwrap(RemoteValidationConfig.of(try block()))
        c.valueChanged("name", "abc", config: config, immediate: true)
        for _ in 0..<50 where c.state("name")?.phase != .unavailable { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(c.state("name")?.phase, .unavailable)
        XCTAssertEqual(c.state("name")?.reason, "no_delegate")
        XCTAssertEqual(warnings, 1)
        // Learned: the next value goes straight to "no delegate", with no call and no progress.
        c.valueChanged("name", "abcd", config: config)
        XCTAssertEqual(c.state("name")?.phase, .unavailable)
        XCTAssertFalse(c.showsProgress("name"))
    }
}

// MARK: Offline, through the step's production wiring and the REAL NetworkMonitor

@MainActor
final class RemoteValidationOfflineTests: XCTestCase {
    private final class Flaky: AppDNAOnboardingDelegate {
        var calls: [String] = []
        var answer: InputValidationResult?
        func onValidateInput(flowId: String, stepId: String, fieldId: String, value: String) async -> InputValidationResult? {
            calls.append(value)
            return answer
        }
    }

    override func tearDown() {
        NetworkMonitor.shared.apply(type: .wifi, expensive: false)
        super.tearDown()
    }

    func testOfflineSaysSoAndTheReturningConnectionRechecks() async throws {
        let host = Flaky()
        let c = OnboardingStepRouter.makeRemoteValidation(delegate: host, flowId: "f", stepId: "s", tracker: nil)
        let observer = c.watchConnectivity(NetworkMonitor.shared)
        defer { NetworkMonitor.shared.removeRegainedObserver(observer) }
        let config = try XCTUnwrap(RemoteValidationConfig.from(["enabled": true, "when_unavailable": "allow"]))

        NetworkMonitor.shared.apply(type: .none, expensive: false)   // airplane mode
        c.valueChanged("name", "abc", config: config, immediate: true)
        for _ in 0..<100 where c.state("name")?.phase != .unavailable { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(c.state("name")?.reason, "offline")
        XCTAssertEqual(c.state("name")?.message, RemoteValidationConfig.builtInOffline, "offline says so even under allow")
        XCTAssertEqual(c.decide([.init(id: "name", value: "abc", config: config)]), .allow, "the default lets the user continue")

        host.answer = .valid()
        NetworkMonitor.shared.apply(type: .wifi, expensive: false)   // back online → re-check by itself
        for _ in 0..<100 where c.state("name")?.phase != .valid { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(c.state("name")?.phase, .valid)
        XCTAssertEqual(host.calls, ["abc", "abc"])
    }

    func testOfflineUnderBlockRefuses() async throws {
        let host = Flaky()
        let c = OnboardingStepRouter.makeRemoteValidation(delegate: host, flowId: "f", stepId: "s", tracker: nil)
        let config = try XCTUnwrap(RemoteValidationConfig.from(["enabled": true, "when_unavailable": "block"]))
        NetworkMonitor.shared.apply(type: .none, expensive: false)
        c.valueChanged("name", "abc", config: config, immediate: true)
        for _ in 0..<100 where c.state("name")?.phase != .unavailable { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(c.decide([.init(id: "name", value: "abc", config: config)]), .block(RemoteValidationConfig.builtInOffline))
    }
}
