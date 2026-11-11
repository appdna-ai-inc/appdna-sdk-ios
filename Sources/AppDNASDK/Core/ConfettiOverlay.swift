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

    /*
     * ONE LIST, not a `switch` per platform. The semantic colours this used to return
     * (`.red` is #FF3B30) and the Compose constants Android returned (`Color.Red` is #FF0000) are
     * different colours, so an unauthored celebration drew differently on the two platforms. The
     * hexes in `CelebrationPalette` are what these semantic values resolve to in the light
     * appearance, so nothing already published changes here — Android moves to meet this.
     */
    private var effectColors: [Color] {
        CelebrationPalette.colors(type: effect.type, authored: effect.colors).map { Color(hex: $0) }
    }

    /// The shared rule, so "circle or glyph" is one question with one answer.
    private var particleShape: String { CelebrationPalette.glyph(type: effect.type) }

    public var body: some View {
        ZStack {
            if isActive {
                ForEach(particles) { particle in
                    if particleShape.isEmpty {
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
         🔴 NO SECOND GATE. This used to re-check `effect.trigger == "on_appear"`, and every
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
                    x: CGFloat.random(in: 0...SurfaceMetrics.windowBounds.width),
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
                    y: SurfaceMetrics.windowBounds.height + 50
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
