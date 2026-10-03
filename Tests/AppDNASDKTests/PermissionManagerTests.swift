import XCTest
@testable import AppDNASDK

/// pure/testable logic of the onboarding runtime-permission pipeline. The OS dialog
/// itself is not unit-testable; everything around it (key mapping, crash-guard decision,
/// status→routing, ATT short-circuit) is.
final class PermissionManagerTests: XCTestCase {

    // MARK: - Type → required Info.plist key mapping

    func testRequiredKeyMapping() {
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "camera"), "NSCameraUsageDescription")
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "microphone"), "NSMicrophoneUsageDescription")
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "photos"), "NSPhotoLibraryUsageDescription")
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "location"), "NSLocationWhenInUseUsageDescription")
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "contacts"), "NSContactsUsageDescription")
        XCTAssertEqual(PermissionManager.requiredInfoPlistKey(for: "att"), "NSUserTrackingUsageDescription")
    }

    func testCalendarKeyIsVersionBranched() {
        let key = PermissionManager.requiredInfoPlistKey(for: "calendar")
        if #available(iOS 17.0, *) {
            XCTAssertEqual(key, "NSCalendarsFullAccessUsageDescription")
        } else {
            XCTAssertEqual(key, "NSCalendarsUsageDescription")
        }
    }

    func testNotificationRequiresNoKey() {
        // notification maps to NO usage-description key — the crash-guard is a no-op for it.
        XCTAssertNil(PermissionManager.requiredInfoPlistKey(for: "notification"))
    }

    func testUnknownTypeHasNoKeyAndIsUnsupported() {
        XCTAssertNil(PermissionManager.requiredInfoPlistKey(for: "health"))
        XCTAssertFalse(PermissionManager.isSupported("health"))
        XCTAssertFalse(PermissionManager.isSupported("exact_alarm"))
        XCTAssertFalse(PermissionManager.isSupported(""))
    }

    func testSupportedTypes() {
        for t in ["notification", "att", "location", "camera", "microphone", "photos", "contacts", "calendar"] {
            XCTAssertTrue(PermissionManager.isSupported(t), "\(t) should be supported")
        }
    }

    // MARK: - Info.plist-present crash-guard decision

    func testGuardUnavailableWhenKeyAbsent() {
        // camera requires a key; absent → .unavailable (do NOT touch the OS API → no SIGABRT).
        let decision = PermissionManager.plistGuardStatus(type: "camera", keyPresent: { _ in false })
        XCTAssertEqual(decision, .unavailable)
    }

    func testGuardProceedsWhenKeyPresent() {
        // camera key present → nil (safe to proceed to the OS request path).
        let decision = PermissionManager.plistGuardStatus(type: "camera", keyPresent: { _ in true })
        XCTAssertNil(decision)
    }

    func testGuardChecksTheCorrectKey() {
        var asked: String?
        _ = PermissionManager.plistGuardStatus(type: "photos", keyPresent: { key in
            asked = key
            return true
        })
        XCTAssertEqual(asked, "NSPhotoLibraryUsageDescription")
    }

    func testGuardNotificationAlwaysProceeds() {
        // notification requires no key → proceed even if every key lookup fails.
        let decision = PermissionManager.plistGuardStatus(type: "notification", keyPresent: { _ in false })
        XCTAssertNil(decision)
    }

    func testGuardUnsupportedTypeIsUnavailable() {
        let decision = PermissionManager.plistGuardStatus(type: "health", keyPresent: { _ in true })
        XCTAssertEqual(decision, .unavailable)
    }

    // MARK: - Status → routing decision

    func testRouteAlreadyGranted() {
        XCTAssertEqual(PermissionManager.route(for: .granted), .alreadyGranted)
    }

    func testRouteDenied() {
        XCTAssertEqual(PermissionManager.route(for: .denied), .denied)
    }

    func testRouteUnavailable() {
        XCTAssertEqual(PermissionManager.route(for: .unavailable), .unavailable)
    }

    func testRoutePrompt() {
        XCTAssertEqual(PermissionManager.route(for: .undetermined), .prompt)
    }

    /// The stored `permission_{type}` value the pipeline writes per decision:
    /// granted/already → "granted"; denied → "denied"; unavailable → nothing stored.
    func testStoredValuePerDecision() {
        XCTAssertEqual(storedValue(for: .alreadyGranted), "granted")
        XCTAssertEqual(storedValue(for: .denied), "denied")
        XCTAssertNil(storedValue(for: .unavailable))
        // prompt stores the request's boolean result, resolved at runtime.
        XCTAssertNil(storedValue(for: .prompt))
    }

    // MARK: - ATT < 14.5 short-circuit

    func testAttShortCircuitBelow14_5() {
        XCTAssertTrue(PermissionManager.attGrantedWithoutPrompt(major: 13, minor: 0))
        XCTAssertTrue(PermissionManager.attGrantedWithoutPrompt(major: 14, minor: 0))
        XCTAssertTrue(PermissionManager.attGrantedWithoutPrompt(major: 14, minor: 4))
    }

    func testAttPromptsAt14_5AndAbove() {
        XCTAssertFalse(PermissionManager.attGrantedWithoutPrompt(major: 14, minor: 5))
        XCTAssertFalse(PermissionManager.attGrantedWithoutPrompt(major: 15, minor: 0))
        XCTAssertFalse(PermissionManager.attGrantedWithoutPrompt(major: 17, minor: 2))
    }

    // MARK: - Delegate defaults

    func testDelegateDefaultsAreInert() async {
        final class BareDelegate: AppDNAOnboardingDelegate {}
        let d = BareDelegate()
        let handling = await d.onPermissionRequest("camera")
        XCTAssertNil(handling)  // default pre-hook → SDK runs the OS flow
        // Default result callback is a no-op (must not crash).
        d.onPermissionResult(flowId: "f", stepId: "s", permissionType: "camera", granted: true)
    }

    func testPermissionHandlingEquatable() {
        XCTAssertEqual(PermissionHandling.proceed, .proceed)
        XCTAssertEqual(PermissionHandling.handledByHost(granted: true), .handledByHost(granted: true))
        XCTAssertNotEqual(PermissionHandling.handledByHost(granted: true), .handledByHost(granted: false))
    }

    // MARK: - console-shape decode (permission_type at step-content TOP LEVEL)

    /// Regression for the contract bug: the console serializer writes
    /// `permission_type` / `show_settings_fallback_on_denied` / `settings_fallback_label`
    /// as SIBLINGS of `content_blocks` at the step-content top level (`step.layout = stepConfig`),
    /// NOT inside the inner `layout` sub-map. The SDK previously read them from the inner map →
    /// resolved to "" → every authored permission step emitted `permission_unavailable` and
    /// advanced WITHOUT prompting. These must decode into first-class StepConfig fields.
    func testPermissionFieldsDecodeFromStepContentTopLevel() throws {
        // `step.layout` = the whole content object; permission keys are siblings of content_blocks.
        let json = """
        {
          "id": "perm-step",
          "type": "custom",
          "layout": {
            "permission_type": "camera",
            "show_settings_fallback_on_denied": true,
            "settings_fallback_label": "Enable in Settings",
            "content_blocks": [
              { "type": "text", "text": "We need your camera" }
            ]
          }
        }
        """
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        // Top-level permission fields must resolve — NOT from the inner `layout` sub-map.
        XCTAssertEqual(step.config.permission_type, "camera")
        XCTAssertEqual(step.config.show_settings_fallback_on_denied, true)
        XCTAssertEqual(step.config.settings_fallback_label, "Enable in Settings")
        // Sibling content_blocks still decode alongside.
        XCTAssertEqual(step.config.content_blocks?.count, 1)
        // The permission type resolved from the field is supported → pipeline WILL prompt.
        XCTAssertTrue(PermissionManager.isSupported(step.config.permission_type ?? ""))
    }

    /// The `config`-keyed variant (some server paths write `step.config` instead of `step.layout`)
    /// must resolve the same top-level permission fields.
    func testPermissionFieldsDecodeFromConfigKey() throws {
        let json = """
        { "id": "s", "type": "custom",
          "config": { "permission_type": "notification", "content_blocks": [] } }
        """
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.config.permission_type, "notification")
    }

    // MARK: - Helpers (mirror the renderer's per-decision store rule)

    private func storedValue(for decision: PermissionRouteDecision) -> String? {
        switch decision {
        case .alreadyGranted: return "granted"
        case .denied: return "denied"
        case .unavailable: return nil
        case .prompt: return nil  // resolved from the OS request result at runtime
        }
    }
}
