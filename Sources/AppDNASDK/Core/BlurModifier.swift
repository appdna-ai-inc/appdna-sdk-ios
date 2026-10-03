import SwiftUI

public struct BlurConfig: Codable {
    public let radius: Double?
    public let tint: String?
    public let saturation: Double?

    public init(radius: Double? = nil, tint: String? = nil, saturation: Double? = nil) {
        self.radius = radius
        self.tint = tint
        self.saturation = saturation
    }

    // Zod + console editor treat `blur_backdrop` as a boolean for
    // convenience (simple toggle), but the iOS SDK uses a richer BlurConfig
    // struct for future tuning. Accept both wire shapes so messages with
    // `blur_backdrop: true` decode into a sensible default config, and
    // `blur_backdrop: false` (or missing) decodes as nil at the optional
    // boundary. The full object form continues to work unchanged.
    private enum CodingKeys: String, CodingKey { case radius, tint, saturation }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let bool = try? single.decode(Bool.self) {
            if !bool {
                // `false` is semantically "no blur"; callers should surface
                // this via the optional boundary. We still need to produce
                // a valid instance here — BlurConfig with radius=0 renders
                // to a no-op (see BlurBackdropModifier at :17-21).
                self.radius = 0
                self.tint = nil
                self.saturation = nil
                return
            }
            // Sensible defaults for the "true" short-form — matches the
            // glassmorphism look Apple uses on system modals.
            self.radius = 30
            self.tint = nil
            self.saturation = 1.8
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.radius = try container.decodeIfPresent(Double.self, forKey: .radius)
        self.tint = try container.decodeIfPresent(String.self, forKey: .tint)
        self.saturation = try container.decodeIfPresent(Double.self, forKey: .saturation)
    }
}

public struct BlurBackdropModifier: ViewModifier {
    let config: BlurConfig

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // System material for glassmorphism
                    if (config.radius ?? 0) > 0 {
                        Color.clear
                            .background(.ultraThinMaterial)
                            .blur(radius: CGFloat(config.radius ?? 0) / 3)
                    }

                    // Optional tint overlay
                    if let tint = config.tint {
                        Color(hex: tint).opacity(0.15)
                    }
                }
            )
            .saturation(config.saturation ?? 1.8)
    }
}

extension View {
    public func applyBlurBackdrop(_ config: BlurConfig?) -> some View {
        Group {
            if let config = config, (config.radius ?? 0) > 0 {
                self.modifier(BlurBackdropModifier(config: config))
            } else {
                self
            }
        }
    }
}
