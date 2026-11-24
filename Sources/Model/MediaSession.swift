import UIKit

/// The player's MediaSession as seen from outside the app: what the launcher's quick settings
/// media controls show and drive (Android's media notification / QS media player).
@MainActor
public enum MusicPlayerSession {
    /// A track is loaded (playing or paused).
    public static var isActive: Bool { Player.shared.currentTrack != nil }
    public static var isPlaying: Bool { Player.shared.isPlaying }
    public static var title: String? { Player.shared.currentTrack?.title }
    public static var artist: String? { Player.shared.currentTrack?.artist }
    /// Bumped on every track change.
    public static var trackChanges: Int { Player.shared.transitions }

    public static func artwork(size: CGFloat) async -> UIImage? {
        await Artwork.shared.image(for: Player.shared.currentTrack, size: size)
    }

    public static func playPause() { Player.shared.togglePlayback() }
    public static func next() { Player.shared.next() }
    public static func previous() { Player.shared.previous() }
}
