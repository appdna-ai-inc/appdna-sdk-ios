import SwiftUI

public struct ParticleEffect: Codable {
    public let type: String?        // "confetti", "sparkle", "fireworks", "snow", "hearts"
    public let trigger: String?     // "on_appear", "on_step_complete", "on_purchase", "on_flow_complete"
    public let duration_ms: Int?
    public let intensity: String?   // "light", "medium", "heavy"
    public let colors: [String]?
}

public struct ConfettiOverlay: View {
    let effect: ParticleEffect
    @State private var isActive = false
    @State private var particles: [ConfettiParticle] = []

    private var particleCount: Int {
        switch effect.intensity ?? "medium" {
        case "light": return 30
        case "heavy": return 120
        default: return 60
        }
    }

    private var effectColors: [Color] {
        if let customColors = effect.colors, !customColors.isEmpty {
            return customColors.map { Color(hex: $0) }
        }
        switch effect.type ?? "confetti" {
        case "hearts": return [.red, .pink, Color(hex: "#FF6B9D")]
        case "snow": return [.white, Color(white: 0.95), Color(white: 0.9)]
        case "sparkle": return [.yellow, .orange, Color(hex: "#FFD700")]
        case "fireworks": return [.red, .blue, .green, .yellow, .purple, .orange]
        default: return [.red, .blue, .green, .yellow, .purple, .orange, .pink]
        }
    }

    private var particleShape: String {
        switch effect.type ?? "confetti" {
        case "hearts": return "\u{2764}\u{FE0F}"
        case "snow": return "\u{2744}\u{FE0F}"
        case "sparkle": return "\u{2728}"
        case "fireworks": return "\u{1F386}"
        default: return "\u{25CF}"
        }
    }

    public var body: some View {
        ZStack {
            if isActive {
                ForEach(particles) { particle in
                    if (effect.type ?? "confetti") == "confetti" {
                        Circle()
                            .fill(particle.color)
                            .frame(width: particle.size, height: particle.size)
                            .position(particle.position)
                            .opacity(particle.opacity)
                    } else {
                        Text(particleShape)
                            .font(.system(size: particle.size))
                            .position(particle.position)
                            .opacity(particle.opacity)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        /*
         🔴 #956 — NO SECOND GATE. This used to re-check `effect.trigger == "on_appear"`, and every
         caller already decides WHEN to render the overlay: the paywall sets `showConfetti` only
         after a purchase when the trigger says `on_purchase`, the survey only on completion, a
         message only when its own condition fires. So the re-check could not admit anything the
         parent had not already admitted — it could only SUBTRACT, and it did: an effect authored
         `on_purchase` was armed by the paywall and then refused here, on both platforms. Android's
         `trigger && (effect.trigger == "on_appear" || isActive)` is the same bug in Kotlin, and
         `PaywallConfig.kt` DEFAULTS an unauthored paywall effect to `on_purchase` — so the
         default never fired either.

         The overlay animates when it appears. Deciding whether it should appear is the parent's
         job, and the parent is the only one that knows.
        */
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        isActive = true
        particles = (0..<particleCount).map { _ in
            ConfettiParticle(
                color: effectColors.randomElement() ?? .blue,
                size: CGFloat.random(in: 4...12),
                position: CGPoint(
                    x: CGFloat.random(in: 0...UIScreen.main.bounds.width),
                    y: -20
                ),
                opacity: 1.0
            )
        }

        // Animate particles falling
        withAnimation(.easeOut(duration: Double(effect.duration_ms ?? 2000) / 1000.0)) {
            particles = particles.map { p in
                var updated = p
                updated.position = CGPoint(
                    x: p.position.x + CGFloat.random(in: -50...50),
                    y: UIScreen.main.bounds.height + 50
                )
                updated.opacity = 0
                return updated
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(effect.duration_ms ?? 2000) / 1000.0) {
            isActive = false
        }
    }

    public func triggerEffect() {
        startAnimation()
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGFloat
    var position: CGPoint
    var opacity: Double
}
