import Foundation

// MARK: - v1.0 Delegate Protocols
//
// NOTE (SPEC-041): The following delegate protocols are defined in their respective module files
// and are NOT duplicated here to avoid compilation conflicts:
//
//   - AppDNAOnboardingDelegate → Sources/AppDNASDK/Onboarding/OnboardingConfig.swift
//     Methods: onOnboardingStarted, onOnboardingStepChanged, onOnboardingCompleted, onOnboardingDismissed
//
//   - AppDNAPaywallDelegate → Sources/AppDNASDK/Paywalls/PaywallConfig.swift
//     Methods: onPaywallPresented, onPaywallAction, onPaywallPurchaseStarted,
//              onPaywallPurchaseCompleted, onPaywallPurchaseFailed, onPaywallDismissed,
//              onPromoCodeSubmit, onPostPurchaseDeepLink, onPostPurchaseNextStep,
//              onPaywallRestoreStarted, onPaywallRestoreCompleted, onPaywallRestoreFailed
//
//   - AppDNAPushDelegate → Sources/AppDNASDK/Integrations/AppDNAPushDelegate.swift
//     Methods: onPushTokenRegistered, onPushReceived, onPushTapped
//

/// Delegate for billing/purchase events.
public protocol AppDNABillingDelegate: AnyObject {
    func onPurchaseCompleted(productId: String, transaction: TransactionInfo)
    func onPurchaseFailed(productId: String, error: Error)
    func onEntitlementsChanged(entitlements: [Entitlement])
    func onRestoreCompleted(restoredProducts: [String])
}

/// Default implementations — all methods optional.
public extension AppDNABillingDelegate {
    func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {}
    func onPurchaseFailed(productId: String, error: Error) {}
    func onEntitlementsChanged(entitlements: [Entitlement]) {}
    func onRestoreCompleted(restoredProducts: [String]) {}
}

/// Delegate for in-app message events.
public protocol AppDNAInAppMessageDelegate: AnyObject {
    func onMessageShown(messageId: String, trigger: String)
    func onMessageAction(messageId: String, action: String, data: [String: Any]?)
    func onMessageDismissed(messageId: String)
    func shouldShowMessage(messageId: String) -> Bool
}

/// Default implementations — all methods optional.
public extension AppDNAInAppMessageDelegate {
    func onMessageShown(messageId: String, trigger: String) {}
    func onMessageAction(messageId: String, action: String, data: [String: Any]?) {}
    func onMessageDismissed(messageId: String) {}
    func shouldShowMessage(messageId: String) -> Bool { true }
}

/// Delegate for survey events.
public protocol AppDNASurveyDelegate: AnyObject {
    func onSurveyPresented(surveyId: String)
    func onSurveyCompleted(surveyId: String, responses: [SurveyResponse])
    func onSurveyDismissed(surveyId: String)
}

/// Default implementations — all methods optional.
public extension AppDNASurveyDelegate {
    func onSurveyPresented(surveyId: String) {}
    func onSurveyCompleted(surveyId: String, responses: [SurveyResponse]) {}
    func onSurveyDismissed(surveyId: String) {}
}

/// Delegate for deep link events.
public protocol AppDNADeepLinkDelegate: AnyObject {
    func onDeepLinkReceived(url: URL, params: [String: String])
}

/// Default implementations — all methods optional.
public extension AppDNADeepLinkDelegate {
    func onDeepLinkReceived(url: URL, params: [String: String]) {}
}

/// SPEC-404 — lifecycle delegate for backend-driven SDK lock state.
///
/// The SDK enters "locked mode" when the `/sdk/bootstrap` response carries a
/// `runtime_lock` object (per-key suspended at day 20+, OR org cancelled).
/// In locked mode: paywall_trigger nodes auto-skip; messages/surveys pause;
/// event uploads cleanly disable on first 401 (existing
/// `eventUploadPermanentlyFailed` flag). Identify continues working locally
/// (anchor + UserDefaults), so the EntitlementOwnerFilter still gates
/// correctly per-user.
///
/// Implement this protocol on a host class and set
/// `AppDNA.lifecycleDelegate = self` to surface a custom UI banner
/// ("Service temporarily unavailable") and to be notified when the lock
/// clears (e.g. trigger a one-shot retry of pending event uploads).
public protocol AppDNALifecycleDelegate: AnyObject {
    /// Fires exactly once per idle → locked transition. `reason` is one of
    /// `'billing_overdue' | 'manual_admin' | 'org_cancelled'` (raw string,
    /// host translates if needed). `lockedAt` is the ISO-8601 timestamp the
    /// backend recorded the lock (per-key suspended_at when available).
    /// String type preserves cross-platform parity (Kotlin / Dart / TS
    /// implementations also take the raw ISO string — see
    /// `src/lib/sdk-delegates/index.ts` for the codegen source of truth).
    func onSdkRuntimeLocked(reason: String, lockedAt: String)

    /// Fires exactly once per locked → idle transition (lock cleared, the
    /// next bootstrap returned no `runtime_lock`). Host typically uses this
    /// to drop a "service unavailable" banner and force an event-queue
    /// flush retry.
    func onSdkRuntimeUnlocked()
}

/// Default no-op extensions — hosts that don't care stay zero-config.
public extension AppDNALifecycleDelegate {
    func onSdkRuntimeLocked(reason: String, lockedAt: String) {}
    func onSdkRuntimeUnlocked() {}
}

/// Delegate for server-driven screen events (SPEC-089c).
public protocol AppDNAScreenDelegate: AnyObject {
    func onScreenPresented(screenId: String)
    func onScreenDismissed(screenId: String, result: ScreenResult)
    func onFlowCompleted(flowId: String, result: FlowResult)
    func onScreenAction(screenId: String, action: SectionAction) -> Bool
}

/// Default implementations — all methods optional.
public extension AppDNAScreenDelegate {
    func onScreenPresented(screenId: String) {}
    func onScreenDismissed(screenId: String, result: ScreenResult) {}
    func onFlowCompleted(flowId: String, result: FlowResult) {}
    func onScreenAction(screenId: String, action: SectionAction) -> Bool { true }
}

// MARK: - Support Types

/// Transaction info from a completed purchase.
public struct TransactionInfo {
    public let transactionId: String
    public let productId: String
    public let purchaseDate: Date
    public let environment: String

    public init(transactionId: String, productId: String, purchaseDate: Date, environment: String = "production") {
        self.transactionId = transactionId
        self.productId = productId
        self.purchaseDate = purchaseDate
        self.environment = environment
    }
}

/// Entitlement info.
public struct Entitlement {
    public let identifier: String
    public let isActive: Bool
    public let expiresAt: Date?
    public let productId: String

    public init(identifier: String, isActive: Bool, expiresAt: Date? = nil, productId: String) {
        self.identifier = identifier
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.productId = productId
    }
}

/// Survey response.
public struct SurveyResponse {
    public let questionId: String
    public let answer: Any

    public init(questionId: String, answer: Any) {
        self.questionId = questionId
        self.answer = answer
    }
}

// MARK: - Init-degraded delegate (SPEC-070-B PN row 2 / D-k)

/// Surfaces a recoverable init failure — a missing `GoogleService-Info-AppDNA.plist`, a malformed
/// bundle config, a subsystem that failed to start. The SDK stays usable; analytics keep flowing
/// (SPEC-070-B AC-31(b)). Android has carried this since SPEC-070-A H.20 (`AppDNAInitDelegate`);
/// iOS had no equivalent, so an iOS host could not tell a degraded SDK from a healthy one.
///
/// Implement on a host class and set `AppDNA.initDelegate = self`. Registering after a degraded
/// init still delivers the pending error once, so late binding never misses the signal.
public protocol AppDNAInitDelegate: AnyObject {
    /// Fires on the main thread whenever `lastInitError` transitions from nil to non-nil, and once
    /// on registration if the SDK is already degraded.
    func onInitDegraded(reason: Error)
}

public extension AppDNAInitDelegate {
    func onInitDegraded(reason: Error) {}
}

/// The errors `AppDNA.reportInitDegraded` records. Android reports a bare `Throwable`; iOS names
/// the cases so a host can branch on them without string-matching a log line.
public enum AppDNAInitError: Error, LocalizedError, Equatable {
    /// No usable AppDNA Firebase configuration. Remote config (paywalls, experiments, flags,
    /// onboarding) will not load; analytics still work.
    case firebaseConfigMissing(String)
    /// The bootstrap request failed. The SDK runs on cached config, if any.
    case bootstrapFailed(String)
    /// One subsystem failed to start. The others — analytics above all — are unaffected.
    case subsystemFailed(name: String, message: String)
    /// A published content block whose `type` this SDK version does not know. It renders as
    /// NOTHING — the step draws with a hole where the block belongs — which is indistinguishable
    /// from a layout bug unless the SDK says so. Ship the SDK version that introduced the type.
    ///
    /// This case exists because that silence cost a full investigation: a summary step drew its
    /// heading, both CTAs and its footnote while the card stack in the middle was simply absent,
    /// and nothing anywhere — no log, no delegate, no placeholder — named the reason.
    case unsupportedBlockType(String)

    public var errorDescription: String? {
        switch self {
        case .firebaseConfigMissing(let detail): return "Firebase configuration missing: \(detail)"
        case .bootstrapFailed(let detail): return "Bootstrap failed: \(detail)"
        case .subsystemFailed(let name, let message): return "Subsystem '\(name)' failed to initialize: \(message)"
        case .unsupportedBlockType(let type):
            return "Content block type '\(type)' is not supported by AppDNA SDK \(AppDNA.sdkVersion) and will render as nothing. Update the SDK."
        }
    }
}
