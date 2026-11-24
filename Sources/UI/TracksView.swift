import FossifyCommons
import SwiftUI

/// TracksActivity: playlist, folder, genre and album tracks (the album with its header).
struct TracksView: View {
    let source: TracksSource
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    @State private var query = ""
    @State private var searching = false
    @State private var selection = Set<String>()
    @State private var action: TrackAction?
    @State private var sorting = false
    @State private var filePicker = false
    @State private var folderPicker = false
    @State private var exportDialog = false
    @State private var exportFile: URL?

    private var playlistID: Int? { if case .playlist(let id) = source { return id } else { return nil } }
    private var isAlbum: Bool { if case .album = source { return true } else { return false } }

    private var title: String {
        switch source {
        case .playlist(let id): return library.playlist(id)?.title ?? ""
        case .folder(let path): return path == musicLibraryFolder ? path : (path.isEmpty ? "Music Player" : path.pathName)
        case .album(let title), .genre(let title): return title
        }
    }

    private var allTracks: [Track] {
        _ = library.revision
        switch source {
        case .playlist(let id): return library.playlistTracks(id)
        case .folder(let path): return library.folderTracks(path)
        case .album(let title): return library.albumTracks(title)
        case .genre(let title): return library.genreTracks([Genre(title: title, trackCnt: 0)]).sorted(by: config.trackSorting)
        }
    }

    var body: some View {
        let all = allTracks
        let q = query.trimmingCharacters(in: .whitespaces)
        let tracks = q.isEmpty ? all : all.filter { $0.title.searchContains(q) || "\($0.artist) - \($0.album)".searchContains(q) }
        VStack(spacing: 0) {
            if selection.isEmpty {
                SearchableTopBar(title: title, query: $query, searching: $searching, canSearch: !isAlbum) {
                    if !isAlbum { IconButton(icon: "arrow.up.arrow.down") { sorting = true } }
                    if playlistID != nil {
                        OverflowMenu {
                            Button { filePicker = true } label: { Label("Add file to playlist", systemImage: "doc.badge.plus") }
                            Button { folderPicker = true } label: { Label("Add folder to playlist", systemImage: "folder.badge.plus") }
                            Button { exportPlaylist(all) } label: { Label("Export playlist", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            } else {
                TrackActionBar(
                    count: selection.count,
                    tracks: { all.filter { selection.contains($0.id) } },
                    removeFromPlaylist: playlistID.map { id in
                        {
                            library.remove(selection, fromPlaylist: id)
                            selection.removeAll()
                        }
                    },
                    selectAll: { selection = Set(tracks.map(\.id)) },
                    close: { selection.removeAll() },
                    action: $action
                )
            }
            content(all: all, tracks: tracks, query: q)
                .frame(maxHeight: .infinity)
            CurrentTrackBar()
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .trackActions($action) { deleted in
            selection.removeAll()
            if !deleted.isEmpty && playlistID == nil && allTracks.isEmpty { router.pop() }
        }
        .sheet(isPresented: $sorting) {
            ChangeSortingDialog(location: sortLocation) { library.rebuild() }
        }
        .sheet(isPresented: $filePicker) {
            FilePickerDialog(path: MusicLibrary.documents.path, roots: MusicLibrary.storageRoots, pickFile: true) { path in
                Task {
                    if let t = await library.track(atPath: path), let id = playlistID { library.add([t], toPlaylist: id) }
                }
            }
        }
        .sheet(isPresented: $folderPicker) {
            FilePickerDialog(path: MusicLibrary.documents.path, roots: MusicLibrary.storageRoots) { path in
                Task {
                    let tracks = await library.folderTracksRecursive(path)
                    if let id = playlistID { library.add(tracks, toPlaylist: id) }
                }
            }
        }
        .sheet(isPresented: $exportDialog) {
            ExportPlaylistDialog { name in
                guard let url = library.exportPlaylist(all, filename: name) else {
                    router.toast = "Exporting failed"
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exportFile = url }
            }
        }
        .fileMover(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }), file: exportFile) { result in
            switch result {
            case .success: router.toast = "Exporting successful"
            case .failure: router.toast = "Exporting failed"
            }
        }
    }

    @ViewBuilder
    private func content(all: [Track], tracks: [Track], query q: String) -> some View {
        if case .album(let albumTitle) = source {
            albumContent(albumTitle, all)
        } else if tracks.isEmpty {
            if playlistID != nil && q.isEmpty {
                Placeholder(text: "No items found.", action: "Add folder to playlist") { folderPicker = true }
            } else {
                Placeholder(text: "No items found.")
            }
        } else if let id = playlistID, !selection.isEmpty, q.isEmpty {
            ReorderList(items: tracks, selection: $selection, onMove: { from, to in
                var ids = tracks.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                library.setPlaylistOrder(id, ids)
            }) { t, selected in
                TrackRow(track: t, info: "\(t.artist) • \(t.album)", selected: selected)
            }
        } else {
            MusicList(items: tracks, selection: $selection, bubble: { $0.bubbleText(bubbleSorting) },
                      onClick: { router.play(tracks, start: $0) }) { t, selected in
                TrackRow(track: t, info: "\(t.artist) • \(t.album)", highlight: q, selected: selected)
            }
        }
    }

    /// TracksHeaderAdapter: album header followed by numbered tracks.
    @ViewBuilder
    private func albumContent(_ albumTitle: String, _ tracks: [Track]) -> some View {
        let entries = [AlbumEntry.header] + tracks.map(AlbumEntry.track)
        MusicList(items: entries, selection: $selection, selectable: { $0 != .header }, bubble: { e in
            if case .track(let t) = e { return t.bubbleText(config.trackSorting) }
            return albumTitle
        }, onClick: { e in
            if case .track(let t) = e { router.play(tracks, start: t) }
        }) { e, selected in
            switch e {
            case .header: albumHeader(albumTitle, tracks)
            case .track(let t): TrackRow(track: t, number: trackNumber(t), selected: selected)
            }
        }
    }

    private func albumHeader(_ albumTitle: String, _ tracks: [Track]) -> some View {
        let album = library.albums.first { $0.title == albumTitle }
        let year = (album?.year ?? 0) != 0 ? "\(album!.year) • " : ""
        return HStack(alignment: .center, spacing: 16) {
            CoverArt(track: album?.coverTrack ?? tracks.first, size: 120, corner: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text(albumTitle).font(.system(size: 20, weight: .medium)).lineLimit(2)
                Text(album?.artist ?? tracks.first?.artist ?? "").font(.system(size: 16)).lineLimit(1)
                Text("\(year)\(tracks.count.tracksText) • \(tracks.totalDuration.formattedDuration(forceShowHours: true))")
                    .font(.system(size: 14))
            }
            .foregroundStyle(palette.textColor)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// track_on_disk: "disc.track" or the track number.
    private func trackNumber(_ t: Track) -> String {
        if let disc = t.discNumber {
            let n = t.trackNumber.map { String(format: "%02d", $0) } ?? ""
            return "\(disc).\(n)"
        }
        return t.trackNumber.map(String.init) ?? ""
    }

    private var sortLocation: SortLocation {
        switch source {
        case .playlist(let id): return .playlist(id)
        case .folder(let path): return .folder(path)
        default: return .genreTracks
        }
    }

    private var bubbleSorting: Int {
        switch source {
        case .playlist(let id): return config.properPlaylistSorting(id)
        case .folder(let path): return config.properFolderSorting(path)
        default: return config.trackSorting
        }
    }

    private func exportPlaylist(_ tracks: [Track]) {
        if tracks.isEmpty {
            router.toast = "No entries for exporting have been found"
        } else {
            exportDialog = true
        }
    }
}

enum AlbumEntry: Identifiable, Equatable {
    case header
    case track(Track)

    var id: String {
        switch self {
        case .header: return "header"
        case .track(let t): return t.id
        }
    }
}

/// AlbumsActivity: an artist's albums followed by all their tracks.
struct AlbumsView: View {
    let artist: String
    @Environment(MusicLibrary.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette

    @State private var selection = Set<String>()
    @State private var action: TrackAction?

    enum Entry: Identifiable {
        case section(String)
        case album(Album)
        case track(Track)

        var id: String {
            switch self {
            case .section(let s): return "s:" + s
            case .album(let a): return "a:" + a.title
            case .track(let t): return t.id
            }
        }
    }

    var body: some View {
        let _ = library.revision
        let albums = library.artistAlbums(artist)
        let tracks = library.albumTracks(albums)
        let entries: [Entry] = [.section(albums.count.albumsText)] + albums.map(Entry.album)
            + [.section("\(tracks.count.tracksText) • \(tracks.totalDuration.formattedDuration(forceShowHours: true))")]
            + tracks.map(Entry.track)
        VStack(spacing: 0) {
            if selection.isEmpty {
                TopBar(title: artist)
            } else {
                let selectedAlbums = albums.filter { selection.contains("a:" + $0.title) }
                let selectedTracks = tracks.filter { selection.contains($0.id) }
                TrackActionBar(
                    count: selection.count,
                    tracks: { selectedTracks + library.albumTracks(selectedAlbums) },
                    trackItems: selectedAlbums.isEmpty,
                    selectAll: { selection = Set(entries.filter { if case .section = $0 { return false } else { return true } }.map(\.id)) },
                    close: { selection.removeAll() },
                    action: $action
                )
            }
            MusicList(items: entries, selection: $selection, selectable: { e in
                if case .section = e { return false } else { return true }
            }, bubble: { e in
                switch e {
                case .section(let s): return s
                case .album(let a): return a.title
                case .track(let t): return t.title
                }
            }, onClick: { e in
                switch e {
                case .album(let a): router.push(.tracks(.album(a.title)))
                case .track(let t): router.play(tracks, start: t)
                case .section: break
                }
            }) { e, selected in
                switch e {
                case .section(let s): SectionRow(title: s)
                case .album(let a): CoverRow(cover: a.coverTrack, title: a.title, subtitle: a.trackCnt.tracksText, selected: selected)
                case .track(let t): TrackRow(track: t, info: t.album, selected: selected)
                }
            }
            .frame(maxHeight: .infinity)
            CurrentTrackBar()
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .trackActions($action) { deleted in
            selection.removeAll()
            if !deleted.isEmpty && library.artistAlbums(artist).isEmpty { router.pop() }
        }
    }
}
