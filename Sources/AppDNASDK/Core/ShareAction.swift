import UIKit

/// What one share carries: the authored text and the optional link, both trimmed, at least one set.
struct SharePayload: Equatable {
    let text: String?
    let url: String?
}

/// The `share` action (#1797): open the system share sheet with authored text and an optional link.
///
/// ONE helper for every surface that can author a share: an onboarding button (top-level, or a child
/// of Multi-buttons / Row / Stack — all drawn by `ContentBlockRendererView.buttonBlock`), an in-app
/// message CTA (`cta_action.type == "share"`) and a paywall extra button. Each calls `perform` /
/// `present` here, so the payload rules and the presentation are the same code on every surface.
///
/// Deliberately NOT tracked as an event and NOT reported to the host: Android cannot learn whether a
/// share completed (an ACTION_SEND chooser reports nothing back), so an event would mean different
/// things on the two platforms. A share never advances a step, closes a paywall, or calls `onNext` —
/// the user is on the same screen when the sheet closes, exactly like `link` and `rate_app`.
enum ShareAction {
    /// The authored action name, on every surface.
    static let actionName = "share"

    /// The payload a share carries, or nil when there is nothing to share.
    ///
    /// Both halves are trimmed; a blank half is absent. Both absent → nil, and the caller presents
    /// nothing: an empty share sheet is a broken screen.
    static func payload(text: String?, url: String?) -> SharePayload? {
        let t = trimmed(text)
        let u = trimmed(url)
        if t == nil && u == nil { return nil }
        return SharePayload(text: t, url: u)
    }

    /// The text a `share` content-block button carries, before translation and interpolation.
    ///
    /// `share_text`; but a block with NEITHER `share_text` nor `share_url` shares its `action_value`:
    /// that is the shape a Screens content-block button authored `share` in before #1797
    /// (`GenericSections`' `.share(text: actionValue)`), and the button tap site now handles every
    /// `share` button first, so dropping it would silently break those screens.
    static func authoredText(of block: ContentBlock) -> String? {
        if block.share_text == nil && block.share_url == nil { return block.action_value }
        return block.share_text
    }

    /// The items handed to `UIActivityViewController`: the text, then the link.
    ///
    /// The link is a `URL` when it parses to one WITH a scheme (so share targets treat it as a link
    /// and can preview it), otherwise the string as authored. The scheme check matters: on iOS 17+
    /// `URL(string:)` percent-encodes almost anything into a relative URL, so "not a link" would
    /// otherwise become a schemeless `URL` that share targets drop.
    static func activityItems(_ p: SharePayload) -> [Any] {
        var items: [Any] = []
        if let text = p.text { items.append(text) }
        if let link = p.url {
            if let parsed = URL(string: link), parsed.scheme != nil {
                items.append(parsed)
            } else {
                items.append(link)
            }
        }
        return items
    }

    /// The tap: build the payload, and present it — or, when it is blank, present nothing, log an
    /// authoring warning and do nothing else. Returns what was presented (nil = nothing).
    @discardableResult
    static func perform(text: String?, url: String?, from viewController: UIViewController? = nil) -> SharePayload? {
        guard let p = payload(text: text, url: url) else {
            // An authoring slip, not a dead subsystem, and it fires on every tap — a LOG, not
            // `reportInitDegraded`. The console warns at publish time; this is the device's fallback.
            Log.warning(
                "A share action has no share text and no link; nothing to share. " +
                "The screen stays as it is."
            )
            return nil
        }
        present(p, from: viewController)
        return p
    }

    /// Presents the share sheet for `p`. Every surface reaches the sheet through here.
    static func present(_ p: SharePayload, from viewController: UIViewController? = nil) {
        presenter(p, viewController)
    }

    /// The presentation step. Tests replace it to capture what the PRODUCTION tap path presents
    /// (a package test has no `UIApplication` scene to present a real sheet into); everything up to
    /// this call is the shipping code. Restore it with `presenter = ShareAction.presentSheet`.
    static var presenter: (SharePayload, UIViewController?) -> Void = ShareAction.presentSheet

    /// The real presentation: a `UIActivityViewController` from the top-most presented view
    /// controller (of `viewController` when given, else of the key window).
    static func presentSheet(_ p: SharePayload, from viewController: UIViewController?) {
        let show: () -> Void = {
            guard var host = viewController ?? AppDNA.topViewController() else {
                Log.warning("Share: no view controller to present the share sheet from")
                return
            }
            while let presented = host.presentedViewController, !presented.isBeingDismissed {
                host = presented
            }
            let sheet = UIActivityViewController(activityItems: ShareAction.activityItems(p), applicationActivities: nil)
            // iPad presents the sheet as a popover, which must be anchored or UIKit raises. Anchor it
            // to the centre of the presenting view, arrowless.
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = host.view
                let bounds = host.view.bounds
                popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            host.present(sheet, animated: true)
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
