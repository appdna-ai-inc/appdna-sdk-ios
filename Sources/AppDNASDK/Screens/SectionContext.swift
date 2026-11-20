import Foundation

/// Shared context passed to every section renderer. Contains accumulated state,
/// user traits for binding resolution, and callbacks for action dispatch.
public struct SectionContext {
    public let screenId: String
    public let flowId: String?
    public var responses: [String: Any]
    public var hookData: [String: Any]?
    public var userTraits: [String: Any]?
    public let onAction: (SectionAction) -> Void
    public let onNavigate: (String) -> Void
    /// A value the user entered in a content block (text, choice, toggle, location), keyed by the block's
    /// `field_id` (else its id). `nil` clears it. The screen collects these into `ScreenResult.responses`, and a
    /// flow into `FlowResult.responses`. Not an action: it runs no veto and tracks nothing.
    public let onResponse: (String, Any?) -> Void
    public let currentScreenIndex: Int
    public let totalScreens: Int
    public let locale: String
    public let localizations: [String: [String: String]]?

    public init(
        screenId: String,
        flowId: String? = nil,
        responses: [String: Any] = [:],
        hookData: [String: Any]? = nil,
        userTraits: [String: Any]? = nil,
        onAction: @escaping (SectionAction) -> Void,
        onNavigate: @escaping (String) -> Void = { _ in },
        onResponse: @escaping (String, Any?) -> Void = { _, _ in },
        currentScreenIndex: Int = 0,
        totalScreens: Int = 1,
        locale: String = "en",
        localizations: [String: [String: String]]? = nil
    ) {
        self.screenId = screenId
        self.flowId = flowId
        self.responses = responses
        self.hookData = hookData
        self.userTraits = userTraits
        self.onAction = onAction
        self.onNavigate = onNavigate
        self.onResponse = onResponse
        self.currentScreenIndex = currentScreenIndex
        self.totalScreens = totalScreens
        self.locale = locale
        self.localizations = localizations
    }

    /// Resolve a localized string. Falls back to default_locale, then to the key itself.
    public func localize(_ key: String) -> String {
        if let localized = localizations?[locale]?[key] {
            return localized
        }
        if let fallback = localizations?["en"]?[key] {
            return fallback
        }
        return key
    }

    /// Build a context dictionary for condition evaluation and template resolution.
    public func buildEvaluationContext() -> [String: Any] {
        var ctx: [String: Any] = [
            "responses": responses,
        ]
        if let hookData = hookData { ctx["hook_data"] = hookData }
        if let traits = userTraits { ctx["user"] = traits }
        ctx["session"] = [
            "screen_index": currentScreenIndex,
            "total_screens": totalScreens,
        ]
        return ctx
    }
}
