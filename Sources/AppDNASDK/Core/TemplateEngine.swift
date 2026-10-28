import Foundation

/// Which surface a template is drawn on. It decides what a Google location answer resolves to.
///
/// Google's terms require attribution in the same visual container wherever a Google answer's
/// content is shown without a Google map. An onboarding step draws that attribution itself, in its
/// container (`GoogleCredit`), so onboarding keeps the answer's values. No other surface can: a push
/// has no container at all, and a paywall, message or survey would need attribution UI of its own.
/// So everywhere else a Google answer resolves to `raw_query`, the text the user typed, which is not
/// Google content.
enum TemplateSurface {
    /// An onboarding step's own text: the answer's values, with the step's credit.
    case onboarding
    /// Every other surface, and anything sent off the device: a Google answer's typed text.
    case other
}

/// Context for variable resolution across all SDK modules.
struct TemplateContext {
    let userTraits: [String: Any]?
    let remoteConfig: (String) -> String?
    let onboardingResponses: [String: [String: Any]]
    let computedData: [String: Any]
    let sessionData: [String: Any]
    let deviceInfo: [String: String]
    /// Where the template is drawn. A context built by hand defaults to the restrictive surface.
    var surface: TemplateSurface = .other
}

/// Shared template interpolation engine for all SDK modules.
/// Resolves `{{namespace.key}}` and `{{namespace.key | fallback}}` variables.
final class TemplateEngine {

    static let shared = TemplateEngine()

    private static let osVersionString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    // Compiled regex — reused across calls
    private let regex: NSRegularExpression? = TemplateEngine.tokenRegex

    private static let tokenRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\{\\{([^}|]+)(?:\\|([^}]*))?\\}\\}")
    }()

    /// The variable path of every `{{…}}` token `interpolate` resolves in `value`, trimmed as it
    /// trims them. Wider than the raw host-data pass's scanner: a path may hold a space.
    static func tokenPaths(in value: String) -> [String] {
        guard value.contains("{{"), let regex = tokenRegex else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { m in
            Range(m.range(at: 1), in: value).map { String(value[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    private init() {}

    /// Build a TemplateContext from current SDK state.
    ///
    /// `surface` has no default on purpose: every caller states where its text goes. Only an
    /// onboarding step's own text passes `.onboarding`; a paywall, message, survey, push, or a value
    /// sent to the customer's server (a hook header) passes `.other`.
    func buildContext(surface: TemplateSurface) -> TemplateContext {
        let identity = AppDNA.identityManagerRef?.currentIdentity
        let sessionStore = SessionDataStore.shared

        return TemplateContext(
            userTraits: identity?.traits,
            remoteConfig: { key in AppDNA.getRemoteConfigFlag(key) },
            onboardingResponses: sessionStore.onboardingResponses,
            computedData: sessionStore.computedData,
            sessionData: sessionStore.sessionData,
            deviceInfo: Self.deviceInfo(),
            surface: surface
        )
    }

    /// Interpolate all `{{...}}` variables in a string.
    func interpolate(_ value: String, context: TemplateContext) -> String {
        guard value.contains("{{") else { return value } // Fast path
        guard let regex = regex else { return value }

        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))

        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: value),
                  let fullRange = Range(match.range, in: value) else { continue }

            let varPath = String(value[varRange]).trimmingCharacters(in: .whitespaces)
            let fallback: String? = match.numberOfRanges > 2
                ? Range(match.range(at: 2), in: value).map { String(value[$0]).trimmingCharacters(in: .whitespaces) }
                : nil

            let resolved = resolveVariable(varPath, context: context) ?? fallback ?? ""
            result = result.replacingCharacters(in: fullRange, with: resolved)
        }
        return result
    }

    /// Interpolate multiple string fields at once.
    func interpolateFields(_ fields: [String?], context: TemplateContext) -> [String?] {
        return fields.map { field in
            guard let field = field else { return nil }
            return interpolate(field, context: context)
        }
    }

    /// Resolve ONE token exactly as `interpolate` would (`resolved ?? fallback ?? ""`).
    ///
    /// The raw host-data pass owns every block string and makes `loc()` lookup-only, so a token whose
    /// root is NOT a block root (`device.*`, `computed.*`, `remote_config.*`, `input.*`, a bare name)
    /// would otherwise stop resolving in published flows that rely on it today. The pass routes each
    /// such token here, one at a time — never the whole string, which would re-scan substituted data.
    func resolveToken(_ path: String, fallback: String?, context: TemplateContext) -> String {
        resolveVariable(path.trimmingCharacters(in: .whitespaces), context: context) ?? fallback ?? ""
    }

    // MARK: - Variable Resolution

    private func resolveVariable(_ path: String, context: TemplateContext) -> String? {
        let parts = path.split(separator: ".", maxSplits: 2).map(String.init)
        guard let namespace = parts.first else { return nil }

        switch namespace {
        case "user":
            guard parts.count >= 2 else { return nil }
            return context.userTraits?[parts[1]].flatMap(Self.stringify)

        case "remote_config":
            guard parts.count >= 2 else { return nil }
            return context.remoteConfig(parts[1])

        case "onboarding", "responses":
            // onboarding.stepId.fieldId
            guard parts.count >= 3 else {
                // onboarding.stepId — return step dict description
                guard parts.count >= 2 else { return nil }
                // Try as two-part path with dot in remaining
                let remaining = path.dropFirst("onboarding.".count)
                let subParts = remaining.split(separator: ".", maxSplits: 1).map(String.init)
                guard subParts.count >= 2 else { return nil }
                return (context.onboardingResponses[subParts[0]])?[subParts[1]].flatMap { answerText($0, context) }
            }
            let stepId = parts[1]
            let fieldPath = parts[2]
            guard let step = context.onboardingResponses[stepId] else { return nil }
            if let exact = step[fieldPath] { return exact is NSNull ? nil : answerText(exact, context) }
            // #1158 — `{{onboarding.<step>.<field>.city}}`: the path is split at most three ways, so a key inside a
            // structured answer (a location selection) arrives as `field.city`. Walk it.
            let keys = fieldPath.split(separator: ".").map(String.init)
            var value: Any? = step[keys[0]]
            for key in keys.dropFirst() {
                // A key inside a Google answer, off onboarding: the user's typed text instead.
                if context.surface == .other, LocationAnswer.carriesPlaceId(value) { return Self.typedText(of: value) }
                value = (value as? [String: Any])?[key]
            }
            guard let found = value, !(found is NSNull) else { return nil }
            return answerText(found, context)

        case "input":
            // Shorthand: {{input.fieldId}} — searches all step responses for the field
            guard parts.count >= 2 else { return nil }
            let fieldId = parts[1]
            for (_, stepData) in context.onboardingResponses {
                if let value = stepData[fieldId] {
                    return answerText(value, context)
                }
            }
            return nil

        case "computed":
            guard parts.count >= 2 else { return nil }
            let key = parts[1]
            return context.computedData[key].flatMap(Self.stringify)

        case "session":
            guard parts.count >= 2 else { return nil }
            let key = parts[1]
            return context.sessionData[key].flatMap(Self.stringify)

        case "device":
            guard parts.count >= 2 else { return nil }
            return context.deviceInfo[parts[1]]

        default:
            // Legacy: bare variable name → remote config (backward compat)
            return context.remoteConfig(path)
        }
    }

    // MARK: - Helpers

    /// An onboarding answer as template text. Off onboarding, a Google answer (one carrying
    /// `place_id`) is its `raw_query`, and a step or list holding one has it replaced the same way
    /// before it is stringified — so the whole-answer token never prints Google content either.
    private func answerText(_ value: Any, _ context: TemplateContext) -> String? {
        guard context.surface == .other else { return Self.stringify(value) }
        if LocationAnswer.carriesPlaceId(value) { return Self.typedText(of: value) }
        return Self.stringify(Self.typedTextForGoogleAnswers(in: value))
    }

    /// A Google answer's `raw_query`, or nil when it has none (the token then takes its fallback).
    static func typedText(of answer: Any?) -> String? {
        let dict = (answer as? [String: Any]) ?? (answer as? NSDictionary).map { d in
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            return out
        }
        guard let q = dict?["raw_query"] as? String, !q.isEmpty else { return nil }
        return q
    }

    /// `value` with every Google answer inside it, at any depth, replaced by its `raw_query`.
    static func typedTextForGoogleAnswers(in value: Any) -> Any {
        if LocationAnswer.carriesPlaceId(value) { return typedText(of: value) ?? "" }
        if let d = value as? [String: Any] { return d.mapValues { typedTextForGoogleAnswers(in: $0) } }
        if let a = value as? [Any] { return a.map { typedTextForGoogleAnswers(in: $0) } }
        return value
    }

    static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            // Check if it's a boolean
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return "\(value)"
        }
    }

    private static func deviceInfo() -> [String: String] {
        var info: [String: String] = [
            "platform": "ios",
            "os_version": Self.osVersionString,
            "locale": Locale.current.languageCode ?? "en",
        ]
        if let country = (Locale.current as NSLocale).countryCode {
            info["country"] = country
        }
        return info
    }
}
