import SwiftUI
import UIKit

/**
 Text with JUSTIFIED alignment: every line but the last fills the width on both sides.

 SwiftUI's `Text` has leading, center and trailing and nothing else, so an author's `justify` was
 drawn as leading on iOS while Android drew it justified. This draws the same attributed string
 through a non-editable, non-scrolling `UITextView` whose paragraph style is `.justified`, sized to
 the width SwiftUI proposes (`sizeThatFits`, iOS 16), so it wraps and grows like the `Text` it
 replaces. A `UITextView` rather than a `UILabel` so a link in rich text still opens — through the
 same SwiftUI `openURL` action every other link in the step uses.

 Runs keep their own colour (links, `[word](color:HEX)`); a run with none takes `color`.
 */
struct JustifiedText: UIViewRepresentable {
    let text: NSAttributedString
    let font: UIFont
    let color: UIColor
    let lineLimit: Int?

    /// `alignment` as authored: `justify` is the only value this view is used for.
    static func isJustify(_ alignment: String?) -> Bool { alignment == "justify" || alignment == "justified" }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        // Our runs carry their own link colour and underline; UIKit's tint must not repaint them.
        view.linkTextAttributes = [:]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        view.textContainer.maximumNumberOfLines = lineLimit ?? 0
        view.textContainer.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        view.attributedText = Self.styled(text, font: font, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction?

        /// iOS 17+: a tap on a link asks for its PRIMARY ACTION here and never calls `shouldInteractWith`, so
        /// without this the link opened outside the app (UIKit's default) instead of in the step's browser.
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL?(url) }
        }

        /// iOS 16.
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            openURL?(URL)
            return false
        }
    }

    /// The attributed string as drawn: justified, the base font and colour where a run sets neither.
    static func styled(_ text: NSAttributedString, font: UIFont, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: out.length)
        let para = NSMutableParagraphStyle()
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping
        out.addAttribute(.paragraphStyle, value: para, range: whole)
        out.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { out.addAttribute(.foregroundColor, value: color, range: range) }
        }
        out.enumerateAttribute(.font, in: whole) { value, range, _ in
            if value == nil { out.addAttribute(.font, value: font, range: range) }
        }
        return out
    }

    /**
     A markdown `AttributedString` (what `MarkdownText` returns) as UIKit draws it.

     `NSAttributedString(_:)` keeps colour, underline and link, but bold, italic and code are
     `inlinePresentationIntent`s, which UIKit does not read — so they become font traits here, on
     `base`, or the justified copy would silently drop every `**bold**`.
     */
    @available(iOS 15.0, *)
    static func nsAttributed(_ attr: AttributedString, base: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in attr.runs {
            let piece = String(attr[run.range].characters)
            var a: [NSAttributedString.Key: Any] = [:]
            var traits: UIFontDescriptor.SymbolicTraits = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) { traits.insert(.traitMonoSpace) }
                if intent.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits)) {
                a[.font] = UIFont(descriptor: d, size: base.pointSize)
            }
            if let c = run.uiKit.foregroundColor { a[.foregroundColor] = c }
            if let u = run.uiKit.underlineStyle { a[.underlineStyle] = u.rawValue }
            else if run.swiftUI.underlineStyle != nil { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if a[.foregroundColor] == nil, let c = run.swiftUI.foregroundColor { a[.foregroundColor] = UIColor(c) }
            if let link = run.link { a[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: a))
        }
        return out
    }
}
