import FossifyCommons
import UIKit

/// The iOS home-screen player widget (fossify-ios/widgets-ios): publishes the current song and
/// registers the in-app actions its buttons run (AudioPlaybackIntent runs them in the app
/// process, like MyWidgetProvider's PREVIOUS / PLAYPAUSE / NEXT broadcasts).
public enum MusicPlayerWidgetData {
    static let snapshotName = "musicplayer"
    @MainActor private static var artworkTrack: String?

    /// Call once at launch (LauncherApp.init), also when iOS starts the app in the background
    /// for a widget button. Doesn't create the Player (its audio session and remote commands
    /// would make the launcher the Now Playing app); `playerCreated()` starts publishing.
    @MainActor
    public static func install() {
        WidgetBridge.register("musicplayer.previous") { control { Player.shared.previous() } }
        WidgetBridge.register("musicplayer.toggle") { control { Player.shared.togglePlayback() } }
        WidgetBridge.register("musicplayer.next") { control { Player.shared.next() } }
    }

    @MainActor private static var tracking = false

    /// Called by Player.init (deferred a turn): publish now and on every song/state change.
    @MainActor
    static func playerCreated() {
        guard !tracking else { return }
        tracking = true
        WidgetBridge.track { publish() }
    }

    /// `fossify://open/musicplayer`: the app opens on its current screen.
    @MainActor
    public static func handle(_ url: URL) {}

    /// handlePlayerControls(): restore the saved queue first; nothing to play does nothing.
    @MainActor
    private static func control(_ action: () -> Void) {
        let player = Player.shared
        player.restoreIfNeeded(MusicLibrary.shared)
        if player.currentTrack != nil { action() }
        publish()
    }

    @MainActor
    static func publish() {
        let player = Player.shared
        let track = player.currentTrack
        var snapshot = MusicWidgetSnapshot(hasTrack: track != nil, title: track?.properTitle(Config.shared.showFilename) ?? "",
                                           artist: track?.artist ?? "", isPlaying: player.isPlaying, artwork: nil)
        let rel = "musicplayer/artwork.jpg"
        if let track, artworkTrack == track.id, let url = WidgetBridge.fileURL(rel), FileManager.default.fileExists(atPath: url.path) {
            snapshot.artwork = rel
        }
        WidgetBridge.save(snapshot, snapshotName, reload: [WidgetKinds.musicPlayer])
        guard let track, artworkTrack != track.id else { return }
        artworkTrack = track.id
        Task { @MainActor in
            let image = await Artwork.shared.image(for: track, size: 300)
            guard artworkTrack == track.id, let url = WidgetBridge.fileURL(rel) else { return }
            if let data = image?.jpegData(compressionQuality: 0.8) {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            snapshot.artwork = image == nil ? nil : rel
            WidgetBridge.save(snapshot, snapshotName, reload: [WidgetKinds.musicPlayer])
        }
    }
}
