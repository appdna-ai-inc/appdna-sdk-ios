import SwiftUI
#if SWIFT_PACKAGE
@_spi(AppDNAInternal) import AppDNANotificationExtension
#endif

public struct IconReference: Codable {
    public let library: String?   // "lucide", "sf-symbols", "material", "emoji"
    public let name: String?
    public let color: String?
    public let size: Double?

    public init(library: String? = nil, name: String? = nil, color: String? = nil, size: Double? = nil) {
        self.library = library
        self.name = name
        self.color = color
        self.size = size
    }

    // Zod IconRefSchema accepts either a typed object OR a bare
    // short-form string (SF Symbol name / emoji). Mirror that here so bare
    // strings from the console editor decode cleanly. An emoji is detected
    // by Unicode properties; anything else is treated as an SF Symbol.
    private enum CodingKeys: String, CodingKey {
        case library, name, color, size
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let bare = try? single.decode(String.self) {
            let first = bare.unicodeScalars.first
            let isEmoji = first?.properties.isEmojiPresentation == true
                || first?.properties.generalCategory == .otherSymbol
            self.library = isEmoji ? "emoji" : "sf-symbols"
            self.name = bare
            self.color = nil
            self.size = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.library = try container.decodeIfPresent(String.self, forKey: .library)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
        self.size = try container.decodeIfPresent(Double.self, forKey: .size)
    }

    /// Symmetric encode. Bare string is only emitted when we have
    /// BOTH a recognised short-form library and a name — any other shape
    /// (nil library, a custom library like "material", extra styling like
    /// color/size) encodes as a full object so re-decode preserves the
    /// original library value exactly.
    public func encode(to encoder: Encoder) throws {
        let isShortForm = color == nil
            && size == nil
            && (library == "sf-symbols" || library == "emoji")
            && (name?.isEmpty == false)
        if isShortForm, let name = name {
            var single = encoder.singleValueContainer()
            try single.encode(name)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(library, forKey: .library)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(size, forKey: .size)
    }
}

/// 3-tier icon resolution: SF Symbols -> Lucide mapping -> emoji fallback
public struct IconView: View {
    let ref: IconReference
    let defaultSize: CGFloat

    init(ref: IconReference, size: CGFloat = 24) {
        self.ref = ref
        self.defaultSize = size
    }

    private var iconSize: CGFloat {
        CGFloat(ref.size ?? Double(defaultSize))
    }

    private var iconColor: Color? {
        ref.color.map { Color(hex: $0) }
    }

    public var body: some View {
        Group {
            let iconName = ref.name ?? ""
            switch ref.library ?? "emoji" {
            case "sf-symbols":
                Image(systemName: iconName)
                    .font(.system(size: iconSize))
                    .foregroundColor(iconColor)

            case "lucide":
                // Map common Lucide names to SF Symbols
                if let sfName = IconMapping.lucideToSFSymbol[iconName] {
                    Image(systemName: sfName)
                        .font(.system(size: iconSize))
                        .foregroundColor(iconColor)
                } else if let emoji = IconMapping.lucideToEmoji[iconName] {
                    Text(emoji)
                        .font(.system(size: iconSize))
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: iconSize))
                        .foregroundColor(iconColor)
                }

            case "material":
                // Map Material Icons to SF Symbols
                if let sfName = IconMapping.materialToSFSymbol[iconName] {
                    Image(systemName: sfName)
                        .font(.system(size: iconSize))
                        .foregroundColor(iconColor)
                } else if let emoji = IconMapping.materialToEmoji[iconName] {
                    Text(emoji)
                        .font(.system(size: iconSize))
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: iconSize))
                        .foregroundColor(iconColor)
                }

            case "emoji":
                Text(iconName)
                    .font(.system(size: iconSize))

            default:
                Text(iconName)
                    .font(.system(size: iconSize))
            }
        }
    }
}

/// Detects whether an icon value is a plain emoji string or an IconReference
public func resolveIcon(_ value: Any?) -> IconReference? {
    if let ref = value as? IconReference {
        return ref
    }
    if let dict = value as? [String: Any],
       let library = dict["library"] as? String,
       let name = dict["name"] as? String {
        return IconReference(
            library: library,
            name: name,
            color: dict["color"] as? String,
            size: dict["size"] as? Double
        )
    }
    if let emoji = value as? String, !emoji.isEmpty {
        return IconReference(library: "emoji", name: emoji, color: nil, size: nil)
    }
    return nil
}

/// Cross-platform icon mapping table (~200 most common icons)
public enum IconMapping {
    /// Lives in `AppDNANotificationExtension` (`SFSymbolTables`) so the push extension maps button icons the same way.
    static var lucideToSFSymbol: [String: String] { SFSymbolTables.lucide }

    static let lucideToEmoji: [String: String] = [
        "check": "\u{2713}",
        "check-circle": "\u{2705}",
        "star": "\u{2B50}",
        "heart": "\u{2764}\u{FE0F}",
        "home": "\u{1F3E0}",
        "settings": "\u{2699}\u{FE0F}",
        "user": "\u{1F464}",
        "bell": "\u{1F514}",
        "mail": "\u{1F4E7}",
        "phone": "\u{1F4F1}",
        "camera": "\u{1F4F7}",
        "calendar": "\u{1F4C5}",
        "clock": "\u{1F550}",
        "map-pin": "\u{1F4CD}",
        "gift": "\u{1F381}",
        "shield": "\u{1F6E1}\u{FE0F}",
        "trophy": "\u{1F3C6}",
        "flag": "\u{1F6A9}",
        "thumbs-up": "\u{1F44D}",
        "thumbs-down": "\u{1F44E}",
        "smile": "\u{1F60A}",
        "zap": "\u{26A1}",
        "rocket": "\u{1F680}",
        "sparkles": "\u{2728}",
        "crown": "\u{1F451}",
        "fire": "\u{1F525}",
        "lock": "\u{1F512}",
        "globe": "\u{1F30D}",
        "dollar-sign": "\u{1F4B0}",
    ]

    static var materialToSFSymbol: [String: String] { SFSymbolTables.material }

    static let materialToEmoji: [String: String] = [
        "check_circle": "\u{2705}",
        "star": "\u{2B50}",
        "favorite": "\u{2764}\u{FE0F}",
        "home": "\u{1F3E0}",
        "notifications": "\u{1F514}",
        "email": "\u{1F4E7}",
        "phone": "\u{1F4F1}",
        "camera_alt": "\u{1F4F7}",
        "calendar_today": "\u{1F4C5}",
        "schedule": "\u{1F550}",
        "place": "\u{1F4CD}",
        "thumb_up": "\u{1F44D}",
        "thumb_down": "\u{1F44E}",
        "language": "\u{1F30D}",
    ]
}
