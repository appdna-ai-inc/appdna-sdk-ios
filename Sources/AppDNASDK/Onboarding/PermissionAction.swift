import Foundation

/// The decision seam for a `permission` CTA.
///
/// WHY THIS FILE EXISTS (and what it FIXES on iOS):
///
///  1. The permission button was the ONLY CTA on a step that told the host NOTHING. Every other
///     button emits `{action, [action_value], ...inputValues}` through `onNext` — which is what
///     `onBeforeStepAdvance` receives and what the cross-platform fixtures call `onAction`. `case
///     "permission"` in `OnboardingRenderer.handleBlockAction` jumped straight into
///     `runPermissionPipeline()` and emitted no host-observable action at all, so a host that wanted
///     to log, branch on, or A/B the permission ask had no callback to hang it on.
///
///  2. The button's OWN `action_value` was ignored. The type was read only from
///     `config.permission_type` / `layout["permission_type"]`, so a console-authored CTA of the form
///     `{action: "permission", value: "notification"}` resolved to the EMPTY STRING — and an empty
///     type falls to `PermissionManager.status("")` → `.unavailable` → the step advanced without ever
///     prompting. The button was inert. (Android had the identical bug; it was fixed there first,
///     which is how this one surfaced.)
///
/// The decision — which type, is it actionable, prompt or advance — is now pure and lives here. The
/// OS work (status, prompt, settings fallback) stays in the SwiftUI host, the only place that can own
/// the presentation.
///
/// Mirrors Android `PermissionAction.kt` symbol for symbol.

/// The action string a permission CTA reports to the host. It is the console-authored
/// `button.action` value, so it IS the contract — never localized, never renamed.
let permissionActionName = "permission"

/// The key the resolved permission type travels under, matching the auth-action payload shape.
let permissionActionValueKey = "action_value"

/// What the caller must do after a permission CTA is tapped.
enum PermissionActionDecision {
    /// The type is real and supported → run the OS pipeline (host pre-hook → status → prompt).
    /// The pipeline owns the advance, because it must only happen once the OS has answered.
    case runPipeline(type: String)

    /// The type is missing, unauthorable or unsupported (e.g. a typo'd `notifications` where the
    /// supported spelling is `notification`) → there is nothing to prompt for. SAFE FALLBACK: advance
    /// anyway. The caller has already emitted the host-observable action, so the host sees exactly
    /// what was asked for and can prompt itself. A dead CTA in an onboarding flow is a total funnel
    /// stop, so "do nothing" is never an option.
    case safeFallbackAdvance(type: String)
}

/// Type source of truth, in the order the renderer already used
/// (`config.permission_type` → `layout["permission_type"]`), plus the button's own `action_value` as
/// the final fallback — the case that used to resolve to "" and render the button inert.
func resolvePermissionType(
    configType: String?,
    layoutType: String?,
    actionValue: String?
) -> String {
    for candidate in [configType, layoutType, actionValue] {
        if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
    }
    return ""
}

/// Pure: is there anything to prompt for? Reuses `PermissionManager`'s own support list, so the two
/// can never disagree about what "supported" means.
func decidePermissionAction(_ type: String) -> PermissionActionDecision {
    if !type.isEmpty, PermissionManager.isSupported(type) {
        return .runPipeline(type: type)
    }
    return .safeFallbackAdvance(type: type)
}

/// The `onAction`-shaped payload for a permission CTA. Step inputs first, so the SDK-controlled
/// `action` / `action_value` keys win on a field-id collision (a customer input literally named
/// "action" cannot mask the button identity).
func permissionActionPayload(
    type: String,
    toggleValues: [String: Bool] = [:],
    inputValues: [String: Any] = [:]
) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in inputValues { out[key] = value }
    for (key, value) in toggleValues { out["toggle_\(key)"] = value }
    out["action"] = permissionActionName
    if !type.isEmpty { out[permissionActionValueKey] = type }
    return out
}

/// The whole permission-CTA decision, SwiftUI-free.
///
/// On the ``PermissionActionDecision/safeFallbackAdvance(type:)`` path the emission IS the advance
/// (`onNext` completes the step), so an unsupported permission can never strand the user. On the
/// ``PermissionActionDecision/runPipeline(type:)`` path the emission is deferred to the pipeline's own
/// `advancePermissionStep()`, which carries the same keys plus the grant result — so the host sees the
/// action exactly ONCE per tap either way, never zero times and never twice.
@discardableResult
func emitPermissionAction(
    configType: String?,
    layoutType: String?,
    actionValue: String?,
    toggleValues: [String: Bool] = [:],
    inputValues: [String: Any] = [:],
    onNext: ([String: Any]?) -> Void
) -> PermissionActionDecision {
    let type = resolvePermissionType(
        configType: configType,
        layoutType: layoutType,
        actionValue: actionValue
    )
    let decision = decidePermissionAction(type)
    if case .safeFallbackAdvance = decision {
        onNext(permissionActionPayload(type: type, toggleValues: toggleValues, inputValues: inputValues))
    }
    return decision
}
