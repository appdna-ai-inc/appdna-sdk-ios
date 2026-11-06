import Foundation

/// #1501 — what a `custom_view` block draws when the host app has NOT registered its `view_key`.
///
/// It used to draw the literal `[view_key]` (a developer's debug label) to end users whenever the block carried no
/// `placeholder_text`. Now, in order: the host's view; else the authored placeholder image; else the authored
/// `placeholder_text`; else — in a DEBUG build only — the bracketed key, so a developer sees what is missing; else
/// NOTHING (the block collapses). A release build never shows the key; it logs it instead.
enum CustomViewFallback {
    /// Tests set this to exercise a release build; nil reads the build configuration.
    static var debugOverride: Bool?

    static var isDebugBuild: Bool {
        if let o = debugOverride { return o }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The text an unregistered block draws, or nil to draw nothing.
    static func text(viewKey: String?, placeholderText: String?, debug: Bool = isDebugBuild) -> String? {
        if let t = placeholderText, !t.isEmpty { return t }
        let key = viewKey ?? ""
        if debug { return "[\(key)]" }
        Log.debug("[Onboarding] custom_view '\(key)' is not registered and has no placeholder_text — drawing nothing")
        return nil
    }

    /// The decision, as the shared fixture names it: `host_view`, `placeholder_image`, `text:<…>` or `nothing`.
    static func resolve(viewKey: String?, registered: Bool, placeholderImageUrl: String?, placeholderText: String?, debug: Bool) -> String {
        if registered { return "host_view" }
        if let u = placeholderImageUrl, URL(string: u) != nil, !u.isEmpty { return "placeholder_image" }
        if let t = text(viewKey: viewKey, placeholderText: placeholderText, debug: debug) { return "text:\(t)" }
        return "nothing"
    }
}
