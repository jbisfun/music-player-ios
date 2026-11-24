import FossifyCommons
import SwiftUI

/// The dialogs behind the selection actions of every track list (BaseMusicAdapter).
enum TrackAction: Identifiable {
    case addToPlaylist([Track])
    case rename(Track)
    case properties([Track])
    case share([Track])
    case delete([Track], warning: Bool)

    var id: String {
        switch self {
        case .addToPlaylist: return "playlist"
        case .rename: return "rename"
        case .properties: return "properties"
        case .share: return "share"
        case .delete: return "delete"
        }
    }
}

struct TrackActionsModifier: ViewModifier {
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.palette) private var palette
    @Binding var action: TrackAction?
    /// Called after an action completed (finishActMode), with the deleted tracks for deletions.
    let onDone: ([Track]) -> Void

    private var sheetAction: Binding<TrackAction?> {
        Binding(get: {
            if case .delete = action { return nil }
            return action
        }, set: { if $0 == nil { action = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: {
            if case .delete = action { return true }
            return false
        }, set: { if !$0 { action = nil } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetAction) { a in
                sheet(a).environment(\.palette, palette)
            }
            .alert(deleteTitle, isPresented: deleteShown) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if case .delete(let tracks, _) = action {
                        let deleted = library.delete(tracks)
                        player.remove(Set(deleted.map(\.id)))
                        onDone(deleted)
                    }
                }
            }
    }

    private var deleteTitle: String {
        if case .delete(_, let warning) = action, warning {
            return "WARNING: This will delete the selected files themselves from the device, all playlists included."
        }
        return "Are you sure you want to proceed with the deletion?"
    }

    @ViewBuilder
    private func sheet(_ a: TrackAction) -> some View {
        switch a {
        case .addToPlaylist(let tracks):
            SelectPlaylistDialog { id in
                library.add(tracks, toPlaylist: id)
                onDone([])
            }
        case .rename(let track):
            EditDialog(track: track) { updated in
                player.replace(track.id, with: updated)
                onDone([])
            }
        case .properties(let tracks):
            PropertiesDialog(paths: tracks.compactMap { $0.fileURL?.path }, countHidden: false) { path in
                StorageRoot.humanize(path, in: MusicLibrary.storageRoots)
            }
        case .share(let tracks):
            ShareSheet(items: tracks.compactMap(\.fileURL))
        case .delete:
            EmptyView()
        }
    }
}

extension View {
    func trackActions(_ action: Binding<TrackAction?>, onDone: @escaping ([Track]) -> Void) -> some View {
        modifier(TrackActionsModifier(action: action, onDone: onDone))
    }
}

/// The action mode of track lists (cab_tracks / cab_albums / cab_tracks_header ...).
struct TrackActionBar: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let count: Int
    /// getAllSelectedTracks().
    let tracks: () -> [Track]
    /// Single selected track rows (properties, rename, play next apply to tracks only).
    var trackItems = true
    var removeFromPlaylist: (() -> Void)?
    var showDelete = true
    let selectAll: () -> Void
    let close: () -> Void
    @Binding var action: TrackAction?

    var body: some View {
        let single = count == 1 && trackItems ? tracks().first : nil
        ActionModeBar(count: count, onClose: close) {
            if let removeFromPlaylist {
                IconButton(icon: "minus.circle", action: removeFromPlaylist)
            }
            if showDelete {
                IconButton(icon: "trash") { action = .delete(tracks(), warning: false) }
            }
            if trackItems {
                IconButton(icon: "info.circle") { properties() }
            }
            if let single, library.canRename(single) {
                IconButton(icon: "pencil") { action = .rename(single) }
            }
            OverflowMenu {
                Button { share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { action = .addToPlaylist(tracks()) } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
                Button {
                    player.addToQueue(tracks())
                    close()
                } label: { Label("Add to queue", systemImage: "text.append") }
                if let single, single.id != player.currentTrack?.id {
                    Button {
                        player.playNext(single)
                        close()
                    } label: { Label("Play next", systemImage: "text.insert") }
                }
                Button(action: selectAll) { Label("Select all", systemImage: "checklist") }
            }
        }
    }

    private func share() {
        let files = tracks().filter { $0.fileURL != nil }
        if files.isEmpty { router.toast = "No items found." } else { action = .share(files) }
    }

    private func properties() {
        let files = tracks().filter { $0.fileURL != nil }
        if files.isEmpty { router.toast = "No items found." } else { action = .properties(files) }
    }
}

extension Router {
    /// prepareAndPlay(): replaces the queue and opens the player.
    @MainActor
    func play(_ tracks: [Track], start: Track) {
        let index = tracks.firstIndex { $0.id == start.id } ?? 0
        Player.shared.prepare(tracks, startIndex: index, play: true)
        push(.player)
    }
}
