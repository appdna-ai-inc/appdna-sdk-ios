import Foundation

/// Which symbol a paywall `guarantee` section draws above its badge.
///
/// The slot takes an SF Symbol name: a name with a `.` or `_` is drawn as authored, anything else
/// (nothing, an emoji, a plain word) draws the default shield. Android resolves the same name through
/// its SF → Material table, so both platforms draw a shield for the default and the common shield
/// names. Shared fixture: `dto_parsing/guarantee_icon_resolution`.
///
/// The default used to be `shield.checkmark.fill`, which is not an SF Symbol, so the default badge drew
/// nothing here and a "?" on Android. That spelling is still read, as the symbol it meant.
enum GuaranteeIcon {
    static let defaultSymbol = "checkmark.shield.fill"

    static func symbol(_ icon: String?) -> String {
        guard let name = icon?.trimmingCharacters(in: .whitespacesAndNewlines), name.contains("_") || name.contains(".") else {
            return defaultSymbol
        }
        return name == "shield.checkmark.fill" ? defaultSymbol : name
    }
}
