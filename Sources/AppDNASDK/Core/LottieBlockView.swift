import Lottie
import SwiftUI

/*
 * 🔴 `lottie_json` and `color_overrides` are GONE, by the owner's decision (2026-10-19).
 *
 * Both were declared here, in the Kotlin DTO and in the Zod schema, and read by NO renderer on
 * either platform: an inline animation document and a per-layer recolour that nothing applied. The
 * console could not set either, so nothing in production carries them.
 *
 * `lottie_url` covers the real use; an inline document bloats the Firestore config a device
 * downloads on every cold start; and a recolour belongs in the `.lottie` the designer ships, where
 * it can be seen before it is published.
 */
public struct LottieBlock: Codable {
    public let lottie_url: String?
    public let autoplay: Bool
    public let loop: Bool
    public let speed: Double
    public let width: Double?
    public let height: Double
    public let alignment: String
    public let play_on_scroll: Bool?
    public let play_on_tap: Bool?
}

public struct LottieBlockView: View {
    let block: LottieBlock

    /// Bumped on each tap so `.id()` restarts the animation from frame 0 (`play_on_tap`).
    @State private var playOnTapTrigger = 0

    private var alignmentValue: Alignment {
        switch block.alignment {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    public var body: some View {
        /*
         THE REAL ENGINE. This drew a purple placeholder box reading "Lottie Animation" for
         as long as the block type has existed, while Android rendered the animation; 27 blocks
         across 19 flows on dev used it, 3 of those flows ACTIVE.

         🔴 `play_on_tap` and `play_on_scroll` are FORMAT choices that change what drives playback,
         so they are resolved before `autoplay` rather than beside it: a block that plays on tap
         must start PAUSED whatever `autoplay` says, or the first tap would restart something
         already running. `play_on_scroll` has no scroll offset to read from inside this view, so
         it is treated as "do not autoplay" — the animation waits, and a tap still starts it, which
         is strictly better than ignoring the field (Android does the same).
        */
        content
            .frame(height: CGFloat(block.height))
            .frame(maxWidth: block.width.map { CGFloat($0) } ?? .infinity, alignment: alignmentValue)
    }

    /// Tapping plays once from the start — only wired when the block asked for it.
    @ViewBuilder
    private var content: some View {
        if block.play_on_tap == true {
            animation(playing: playOnTapTrigger)
                .onTapGesture { playOnTapTrigger += 1 }
        } else {
            animation(playing: nil)
        }
    }

    @ViewBuilder
    private func animation(playing trigger: Int?) -> some View {
        if let urlString = block.lottie_url, let url = URL(string: urlString) {
            /*
             🔴 TWO LOADERS, CHOSEN BY EXTENSION, and getting this wrong draws NOTHING rather than
             failing. `DotLottieFile` reads the zipped `.lottie` container; a plain `.json` is a
             `LottieAnimation`. The first version of this used `DotLottieFile` for both and the
             render test measured `withAnimation=0` — it linked, it compiled, it laid out, and it
             drew an empty frame. The build could not have told me; only reading the pixels did.
            */
            if url.pathExtension.lowercased() == "lottie" {
                LottieView { try await DotLottieFile.loadedFrom(url: url) }
                    .configure { $0.contentMode = .scaleAspectFit }
                    .playbackMode(playbackMode(trigger))
                    .animationSpeed(block.speed)
                    .id(trigger ?? 0)
            } else {
                LottieView { try await LottieAnimation.loadedFrom(url: url) }
                    .configure { $0.contentMode = .scaleAspectFit }
                    .playbackMode(playbackMode(trigger))
                    .animationSpeed(block.speed)
                    .id(trigger ?? 0)
            }
        } else {
            // No URL is not an error — an authored block with nothing to show draws nothing, the
            // way every other block type does, rather than reserving space for a missing file.
            EmptyView()
        }
    }

    private func playbackMode(_ trigger: Int?) -> LottiePlaybackMode {
        // A tap-driven block is paused at frame 0 until the first tap.
        if block.play_on_tap == true, (trigger ?? 0) == 0 { return .paused(at: .progress(0)) }
        if block.play_on_scroll == true, trigger == nil { return .paused(at: .progress(0)) }
        guard block.autoplay || trigger != nil else { return .paused(at: .progress(0)) }
        return .playing(.fromProgress(0, toProgress: 1, loopMode: block.loop ? .loop : .playOnce))
    }
}
