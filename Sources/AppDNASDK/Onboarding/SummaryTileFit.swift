import SwiftUI
import UIKit

/// How much a two-column summary tile's value shrinks so its longest word fits the tile.
///
/// A value wraps on word boundaries on its own; only a word wider than the tile broke mid-word. Shrinking the
/// whole value until that word fits keeps it whole, and the floor stops a long id reaching an unreadable
/// size. Past the floor the word breaks, which reads better than vanishing. Android `SummaryTileFit`.
enum SummaryTileFit {
    /// The smallest a value is drawn, against its authored size.
    static let minScale: CGFloat = 0.5

    /// Headroom, so a width rounded differently by the text layout cannot still break the word.
    private static let margin: CGFloat = 0.97

    /// The longest word's width at the authored size, and the tile's inner width, in the same unit.
    static func scale(longestWordWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard longestWordWidth > 0, availableWidth > 0, longestWordWidth > availableWidth else { return 1 }
        return min(1, max(minScale, availableWidth * margin / longestWordWidth))
    }

    /// The width of `value`'s widest word at `size`, bold, as a tile draws it.
    static func longestWordWidth(_ value: String, size: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: size, weight: .bold)
        return value.split(whereSeparator: { $0.isWhitespace })
            .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }
}

/// A summary tile's value: wraps on word boundaries, shrinking when a word is wider than the tile.
struct SummaryTileValue: View {
    let value: String
    let size: CGFloat
    let color: Color
    let alignment: HorizontalAlignment
    @State private var width: CGFloat = 0

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        let scale = width > 0 ? SummaryTileFit.scale(
            longestWordWidth: SummaryTileFit.longestWordWidth(value, size: size), availableWidth: width
        ) : 1
        Text(value)
            .font(.system(size: size * scale, weight: .bold))
            .foregroundColor(color)
            .multilineTextAlignment(alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .background(GeometryReader { proxy in Color.clear.preference(key: WidthKey.self, value: proxy.size.width) })
            .onPreferenceChange(WidthKey.self) { width = $0 }
    }
}
