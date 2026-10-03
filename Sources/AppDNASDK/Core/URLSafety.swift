import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A scheme allowlist for URLs that arrive from remote config.
///
/// Onboarding blocks, in-app messages, and server-driven screens all hand config strings straight to
/// the system opener. A compromised or misconfigured config could therefore drive `javascript:`,
/// `data:`, `file:`, or plain `http:` navigation from inside the app — in-app phishing, with no
/// certificate pinning (W9) to make it harder.
///
/// The rule: **https for anything external**, plus the small set of system schemes a growth SDK
/// legitimately needs, plus **the host app's own registered URL schemes** so its deep links keep
/// working. Everything else is refused and logged.
internal enum URLSafety {
    /// Schemes always permitted. `http` is deliberately absent — a config-driven cleartext
    /// navigation is exactly the attack this guards.
    static let allowedSchemes: Set<String> = [
        "https",
        "mailto",
        "tel",
        "sms",
        "itms-apps",   // App Store
        "itms-appss",
    ]

    /// The custom URL schemes the host app declares in its Info.plist. A deep link back into the
    /// host is not external navigation, so it is allowed.
    ///
    /// `var`, not `let`, purely so tests can stand in for a host that registers a scheme. Under XCTest
    /// `Bundle.main` is the test runner, which declares no `CFBundleURLTypes` — so a genuine
    /// custom-scheme deep link (`myapp://…`) is refused there for a reason that never applies in a real
    /// app, and a routing test would fail on POLICY rather than on the routing it exists to assert.
    /// Production never assigns this; it stays the bundle-derived set computed below.
    static var hostSchemes: Set<String> = {
        guard let urlTypes = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else {
            return []
        }
        var schemes = Set<String>()
        for type in urlTypes {
            for scheme in (type["CFBundleURLSchemes"] as? [String]) ?? [] {
                schemes.insert(scheme.lowercased())
            }
        }
        return schemes
    }()

    /// Whether a config-driven URL may be opened.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme) || hostSchemes.contains(scheme)
    }

    /// Parse and validate in one step. Returns nil — and logs why — when the URL is refused.
    static func sanitized(_ raw: String) -> URL? {
        guard let url = URL(string: raw) else {
            Log.warning("Refusing to open a malformed config URL")
            return nil
        }
        guard isAllowed(url) else {
            // The scheme, never the full URL: the path may carry a token.
            Log.warning("Refusing to open config URL with disallowed scheme '\(url.scheme ?? "none")'")
            return nil
        }
        return url
    }

    /// How an allowed URL reaches the system. Production hands it to `UIApplication`; a test
    /// substitutes a spy, which is what lets the CALL SITES — not just this helper — be asserted on.
    internal static var opener: (URL) -> Void = { url in
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Sanitize and open, in one call. Returns whether the URL was allowed.
    ///
    /// 🔴 The helper above existed and was unit-tested, while `PaywallRenderer` — the MONEY surface —
    /// built `URL(string: config.secondaryUrl)` and handed it straight to `UIApplication.shared.open`.
    /// A tested guard nothing calls is not a guard. Every config-driven open goes through here now.
    @discardableResult
    static func open(_ raw: String?) -> Bool {
        guard let raw, let url = sanitized(raw) else { return false }
        opener(url)
        return true
    }
}
