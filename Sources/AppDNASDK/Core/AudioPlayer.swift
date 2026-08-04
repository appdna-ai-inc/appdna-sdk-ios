import Foundation
import AVFoundation

/// Shared audio player for the `sound_button` content block (Mrozu Duolingo
/// s20/s22). Streams a remote audio clip (mp3/wav/aac) from a URL and plays it
/// on tap / autoplay. Uses `AVPlayer` so remote URLs stream without a manual
/// download step. A single shared instance retains the current player (an
/// `AVPlayer` that goes out of scope stops immediately) and replaces it on each
/// new play, so tapping repeatedly restarts the clip rather than overlapping.
final class AudioPlayer {
    static let shared = AudioPlayer()

    private var player: AVPlayer?

    private init() {}

    /// Play the audio clip at `urlString`. No-op on nil/blank/unsafe URLs.
    /// Only http(s) URLs are honoured (parity with Android's MediaPlayer path
    /// and to keep the block from reaching non-audio schemes).
    func play(urlString: String?) {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return }

        // Route to the playback category so the clip is audible even when the
        // device is on silent (matches typical onboarding "listen" affordances).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    /// Stop and release the current player.
    func stop() {
        player?.pause()
        player = nil
    }
}
