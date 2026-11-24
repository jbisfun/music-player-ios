import FossifyCommons
import SwiftUI

/// QueueActivity.
struct QueueView: View {
    @Environment(Player.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searching = false
    @State private var selection = Set<String>()
    @State private var action: TrackAction?
    @State private var newPlaylist = false

    var body: some View {
        let all = player.queueInPlayOrder
        let q = query.trimmingCharacters(in: .whitespaces)
        let tracks = q.isEmpty ? all : all.filter { $0.title.searchContains(q) }
        VStack(spacing: 0) {
            if selection.isEmpty {
                SearchableTopBar(title: "Track queue", query: $query, searching: $searching) {
                    OverflowMenu {
                        Button { newPlaylist = true } label: { Label("Create playlist from queue", systemImage: "text.badge.plus") }
                    }
                }
            } else {
                ActionModeBar(count: selection.count, onClose: { selection.removeAll() }) {
                    IconButton(icon: "minus.circle") {
                        player.remove(selection)
                        selection.removeAll()
                        if player.items.isEmpty { dismiss() }
                    }
                    IconButton(icon: "trash") { action = .delete(selected(all), warning: true) }
                    IconButton(icon: "checklist") { selection = Set(tracks.map(\.id)) }
                    OverflowMenu {
                        Button { action = .share(selected(all).filter { $0.fileURL != nil }) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { action = .addToPlaylist(selected(all)) } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
                    }
                }
            }
            if tracks.isEmpty {
                Placeholder(text: "No items found.")
            } else if !selection.isEmpty && q.isEmpty {
                ReorderList(items: tracks, selection: $selection, onMove: player.moveInQueue) { t, selected in
                    row(t, selected: selected, query: "")
                }
            } else {
                ScrollViewReader { proxy in
                    MusicList(items: tracks, selection: $selection, bubble: { $0.title }, onClick: { player.playQueueItem($0) }) { t, selected in
                        row(t, selected: selected, query: q)
                    }
                    .onAppear {
                        if let id = player.currentTrack?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: player.transitions) { _, _ in
                        if let id = player.currentTrack?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.backgroundColor.ignoresSafeArea())
        .trackActions($action) { _ in
            selection.removeAll()
            if player.items.isEmpty { dismiss() }
        }
        .sheet(isPresented: $newPlaylist) {
            NewPlaylistDialog { id in library.add(all, toPlaylist: id) }
        }
    }

    private func selected(_ all: [Track]) -> [Track] { all.filter { selection.contains($0.id) } }

    /// item_track_queue: the current track in the primary color.
    private func row(_ t: Track, selected: Bool, query: String) -> some View {
        let current = t.id == player.currentTrack?.id
        return RowFrame(selected: selected) {
            CoverArt(track: t)
            Text(highlighted(t.title, query, palette.primaryColor))
                .font(.system(size: 16))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(t.duration.formattedDuration()).font(.system(size: 16))
        }
        .foregroundStyle(current ? palette.primaryColor : palette.textColor)
        .id(t.id)
    }
}
