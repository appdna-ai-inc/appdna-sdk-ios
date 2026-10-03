import Foundation

/// Context for variable resolution across all SDK modules.
struct TemplateContext {
    let userTraits: [String: Any]?
    let remoteConfig: (String) -> String?
    let onboardingResponses: [String: [String: Any]]
    let computedData: [String: Any]
    let sessionData: [String: Any]
    let deviceInfo: [String: String]
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
    private let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\{\\{([^}|]+)(?:\\|([^}]*))?\\}\\}")
    }()

    private init() {}

    /// Build a TemplateContext from current SDK state.
    func buildContext() -> TemplateContext {
        let identity = AppDNA.identityManagerRef?.currentIdentity
        let sessionStore = SessionDataStore.shared

        return TemplateContext(
            userTraits: identity?.traits,
            remoteConfig: { key in AppDNA.getRemoteConfigFlag(key) },
            onboardingResponses: sessionStore.onboardingResponses,
            computedData: sessionStore.computedData,
            sessionData: sessionStore.sessionData,
            deviceInfo: Self.deviceInfo()
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
                return (context.onboardingResponses[subParts[0]])?[subParts[1]].flatMap(Self.stringify)
            }
            let stepId = parts[1]
            let fieldId = parts[2]
            return (context.onboardingResponses[stepId])?[fieldId].flatMap(Self.stringify)

        case "input":
            // Shorthand: {{input.fieldId}} — searches all step responses for the field
            guard parts.count >= 2 else { return nil }
            let fieldId = parts[1]
            for (_, stepData) in context.onboardingResponses {
                if let value = stepData[fieldId] {
                    return Self.stringify(value)
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
