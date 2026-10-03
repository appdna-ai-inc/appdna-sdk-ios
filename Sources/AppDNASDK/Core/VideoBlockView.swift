import SwiftUI
import AVKit

public struct VideoBlock: Codable {
    public let video_url: String
    public let video_thumbnail_url: String?
    public let video_height: Double
    public let video_corner_radius: Double?
    public let autoplay: Bool?
    public let loop: Bool?
    public let muted: Bool?
    public let controls: Bool?
    public let inline_playback: Bool?
}

public struct VideoBlockView: View {
    let block: VideoBlock
    @State private var player: AVPlayer?
    @State private var showThumbnail: Bool

    init(block: VideoBlock) {
        self.block = block
        self._showThumbnail = State(initialValue: !(block.autoplay ?? false))
    }

    public var body: some View {
        ZStack {
            if let player = player, !showThumbnail {
                // Honor `controls` and `loop` (both were decoded but ignored: SwiftUI's
                // VideoPlayer always shows transport controls and has no loop hook, so iOS played once
                // and always showed controls while Android honored both). AVPlayerViewController lets us
                // suppress controls; a didPlayToEndTime observer restarts the video when loop is set.
                AVPlayerControllerView(
                    player: player,
                    showsControls: block.controls ?? true,
                    loop: block.loop ?? false
                )
                    .frame(height: CGFloat(block.video_height))
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.video_corner_radius ?? 0)))
                    .onAppear {
                        player.isMuted = block.muted ?? true
                        if block.autoplay ?? false { player.play() }
                    }
            } else {
                // Thumbnail with play button overlay
                ZStack {
                    if let thumb = block.video_thumbnail_url, let url = URL(string: thumb) {
                        BundledAsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.black.opacity(0.3)
                        }
                    } else {
                        LinearGradient(colors: [Color(white: 0.15), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }

                    // Play button
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 48, height: 48)
                        .shadow(radius: 4)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.black)
                                .offset(x: 2)
                        )
                }
                .frame(height: CGFloat(block.video_height))
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.video_corner_radius ?? 0)))
                .onTapGesture {
                    if let url = URL(string: block.video_url) {
                        player = AVPlayer(url: url)
                        showThumbnail = false
                    }
                }
            }
        }
        .onAppear {
            // Actually AUTOPLAY: `player` used to stay nil until a tap, so autoplay:true
            // fell to the thumbnail and never played (Android honors playWhenReady=autoplay). Create it
            // HERE (once, on appear) rather than in init — `State(initialValue: AVPlayer(url:))` isn't an
            // autoclosure, so a SwiftUI View re-init would eagerly construct + discard an AVPlayer every
            // time. showThumbnail is already false for autoplay; setting the player flips to the player
            // view, whose own onAppear calls play().
            if (block.autoplay ?? false), player == nil, let url = URL(string: block.video_url) {
                player = AVPlayer(url: url)
                showThumbnail = false
            }
        }
    }
}

/// Wraps `AVPlayerViewController` so the content-block video can honor `controls` (SwiftUI's
/// `VideoPlayer` can't hide them) and `loop` (restart on play-to-end). Matches Android's
/// `useController` + `REPEAT_MODE_ONE`. The loop observer is torn down in `dismantleUIViewController`.
private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsControls: Bool
    let loop: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = showsControls
        vc.videoGravity = .resizeAspect
        if loop {
            player.actionAtItemEnd = .none
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    final class Coordinator {
        var observer: NSObjectProtocol?
    }
}
