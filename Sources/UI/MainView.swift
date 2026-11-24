import FossifyCommons
import SwiftUI
import UniformTypeIdentifiers

/// MainActivity: search menu, the six tab fragments, sleep timer bar, current track bar and tabs.
struct MainView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    @State private var tab: MusicTab = .tracks
    @State private var didPickTab = false
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var selection = Set<String>()
    @State private var action: TrackAction?

    @State private var sorting = false
    @State private var sleepTimer = false
    @State private var customSleep = false
    @State private var newPlaylist = false
    @State private var folderPicker = false
    @State private var folderTracks: [Track]?
    @State private var importer = false
    @State private var importURL: URL?
    @State private var renamePlaylist: Playlist?
    @State private var removePlaylists = false

    private var visibleTabs: [MusicTab] { config.visibleTabs }

    var body: some View {
        VStack(spacing: 0) {
            if selection.isEmpty { searchBar } else { actionBar }
            if library.showScanProgress {
                ProgressView().progressViewStyle(.linear).tint(palette.primaryColor)
            }
            TabView(selection: $tab) {
                ForEach(visibleTabs) { t in
                    page(t).tag(t)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            if let left = player.sleepRemaining { sleepTimerBar(left) }
            CurrentTrackBar()
            if visibleTabs.count > 1 { bottomTabs }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .animation(.default, value: player.currentTrack == nil)
        .onAppear(perform: pickDefaultTab)
        .onChange(of: tab) { _, t in
            config.lastUsedViewPagerPage = visibleTabs.firstIndex(of: t) ?? 0
            selection.removeAll()
        }
        .onChange(of: config.showTabs) { _, _ in
            config.lastUsedViewPagerPage = 0
            if !visibleTabs.contains(tab) { tab = visibleTabs.first ?? .tracks }
        }
        .trackActions($action) { _ in selection.removeAll() }
        .sheet(isPresented: $sorting) {
            ChangeSortingDialog(location: .tab(tab)) { library.rebuild() }
        }
        .sheet(isPresented: $sleepTimer) {
            RadioDialog(title: nil, items: sleepTimerItems, selected: config.lastSleepTimerSeconds) { seconds in
                if seconds == -1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { customSleep = true }
                } else if seconds > 0 {
                    player.startSleepTimer(seconds: seconds)
                }
            }
        }
        .sheet(isPresented: $customSleep) {
            SleepTimerCustomDialog { seconds in if seconds > 0 { player.startSleepTimer(seconds: seconds) } }
        }
        .sheet(isPresented: $newPlaylist) { NewPlaylistDialog { _ in } }
        .sheet(isPresented: $folderPicker) {
            FilePickerDialog(path: MusicLibrary.documents.path, roots: MusicLibrary.storageRoots) { path in
                Task {
                    let tracks = await library.folderTracksRecursive(path)
                    if tracks.isEmpty {
                        router.toast = "The selected folder contains no audio files"
                    } else {
                        try? await Task.sleep(for: .milliseconds(400))
                        folderTracks = tracks
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { folderTracks != nil }, set: { if !$0 { folderTracks = nil } })) {
            NewPlaylistDialog { id in
                if let folderTracks { library.add(folderTracks, toPlaylist: id) }
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: m3uTypes) { result in
            if case .success(let url) = result {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { importURL = url }
            }
        }
        .sheet(isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            SelectPlaylistDialog { id in
                guard let url = importURL else { return }
                switch library.importPlaylist(url, into: id) {
                case .ok: router.toast = "Importing successful"
                case .partial: router.toast = "Importing some entries failed"
                case .fail: router.toast = "Importing failed"
                }
            }
        }
        .sheet(item: $renamePlaylist) { p in
            NewPlaylistDialog(playlist: p) { _ in selection.removeAll() }
        }
        .sheet(isPresented: $removePlaylists) {
            RemovePlaylistDialog(title: nil) { deleteFiles in removeSelectedPlaylists(deleteFiles: deleteFiles) }
        }
    }

    // MARK: Pages (fragments)

    @ViewBuilder
    private func page(_ t: MusicTab) -> some View {
        let q = tab == t ? query.trimmingCharacters(in: .whitespaces) : ""
        Group {
            switch t {
            case .playlists: playlistsPage(q)
            case .folders: foldersPage(q)
            case .artists: artistsPage(q)
            case .albums: albumsPage(q)
            case .tracks: tracksPage(q)
            case .genres: genresPage(q)
            }
        }
        .background(palette.backgroundColor)
    }

    private var emptyText: String { library.scanning ? "Loading files…" : "No items found." }

    @ViewBuilder
    private func playlistsPage(_ q: String) -> some View {
        let items = library.playlists.filter { $0.title.searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText, action: library.scanning ? nil : "Create new playlist") { newPlaylist = true }
        } else {
            MusicList(items: items.map(PlaylistItem.init), selection: $selection, bubble: { item in
                config.playlistSorting & Sort.title != 0 ? item.playlist.title : String(library.playlistTrackCount(item.playlist))
            }, onClick: { router.push(.tracks(.playlist($0.playlist.id))) }) { item, selected in
                TextRow(title: item.playlist.title, subtitle: library.playlistTrackCount(item.playlist).tracksText, highlight: q, selected: selected)
            }
        }
    }

    @ViewBuilder
    private func foldersPage(_ q: String) -> some View {
        let items = library.folders.filter { $0.title.searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText, action: !config.excludedFolders.isEmpty && !library.scanning ? "Manage excluded folders" : nil) {
                router.push(.excludedFolders)
            }
        } else {
            MusicList(items: items, selection: $selection, bubble: { $0.bubbleText(config.folderSorting) },
                      onClick: { router.push(.tracks(.folder($0.path))) }) { f, selected in
                RowFrame(selected: selected) {
                    Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(palette.primaryColor.opacity(0.8)).frame(width: 40)
                    TwoLines(title: highlighted(f.title, q, palette.primaryColor), subtitle: AttributedString(f.trackCount.tracksText))
                }
            }
        }
    }

    @ViewBuilder
    private func artistsPage(_ q: String) -> some View {
        let items = library.artists.filter { $0.title.searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText)
        } else {
            MusicList(items: items, selection: $selection, bubble: { $0.bubbleText(config.artistSorting) },
                      onClick: { router.push(.artist($0.title)) }) { a, selected in
                CoverRow(cover: a.coverTrack, title: a.title, subtitle: "\(a.albumCnt.albumsText), \(a.trackCnt.tracksText)", highlight: q, selected: selected)
            }
        }
    }

    @ViewBuilder
    private func albumsPage(_ q: String) -> some View {
        let items = library.albums.filter { $0.title.searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText)
        } else {
            MusicList(items: items, selection: $selection, bubble: { $0.bubbleText(config.albumSorting) },
                      onClick: { router.push(.tracks(.album($0.title))) }) { a, selected in
                CoverRow(cover: a.coverTrack, title: a.title, subtitle: a.trackCnt.tracksText, highlight: q, selected: selected)
            }
        }
    }

    @ViewBuilder
    private func tracksPage(_ q: String) -> some View {
        let all = library.tracks
        let items = all.filter { $0.title.searchContains(q) || "\($0.artist) - \($0.album)".searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText)
        } else {
            MusicList(items: items, selection: $selection, bubble: { $0.bubbleText(config.trackSorting) },
                      onClick: { router.play(all, start: $0) }) { t, selected in
                TrackRow(track: t, info: "\(t.artist) • \(t.album)", highlight: q, selected: selected)
            }
        }
    }

    @ViewBuilder
    private func genresPage(_ q: String) -> some View {
        let items = library.genres.filter { $0.title.searchContains(q) }
        if items.isEmpty {
            Placeholder(text: emptyText)
        } else {
            MusicList(items: items, selection: $selection, bubble: { $0.bubbleText(config.genreSorting) },
                      onClick: { router.push(.tracks(.genre($0.title))) }) { g, selected in
                CoverRow(cover: g.coverTrack, title: g.title, subtitle: g.trackCnt.tracksText, highlight: q, selected: selected)
            }
        }
    }

    // MARK: Search menu (MySearchMenu + menu_main)

    private var searchBar: some View {
        HStack(spacing: 0) {
            if !searching { CloseAppButton() }
            Button {
                if searching {
                    query = ""
                    searching = false
                    searchFocused = false
                } else {
                    searching = true
                    searchFocused = true
                }
            } label: {
                Image(systemName: searching ? "arrow.left" : "magnifyingglass").font(.system(size: 18)).frame(width: 48, height: 48)
            }
            TextField("", text: $query, prompt: Text(tab.searchHint).foregroundStyle(palette.secondaryText))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: searchFocused) { _, f in if f { searching = true } }
            if !query.isEmpty {
                IconButton(icon: "xmark") { query = "" }
            }
            IconButton(icon: "arrow.up.arrow.down") { sorting = true }
            IconButton(icon: "slider.vertical.3") { router.push(.equalizer) }
            Menu {
                if tab == .playlists {
                    Button { newPlaylist = true } label: { Label("Create new playlist", systemImage: "plus") }
                    Button { folderPicker = true } label: { Label("Create new playlist from folder", systemImage: "folder.badge.plus") }
                    Button { importer = true } label: { Label("Import playlist", systemImage: "square.and.arrow.down") }
                }
                Button {
                    Task {
                        await library.scan(progress: true)
                        player.reload(library)
                    }
                } label: { Label("Rescan media", systemImage: "arrow.clockwise") }
                Button { sleepTimer = true } label: { Label("Sleep timer", systemImage: "moon.zzz") }
                Button { router.push(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                Button { router.push(.about) } label: { Label("About", systemImage: "info.circle") }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 18)).frame(width: 40, height: 48)
            }
        }
        .foregroundStyle(palette.textColor)
        .background(Capsule().fill(palette.surface))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sleepTimerItems: [(Int, String)] {
        var items: [(Int, String)] = [(5 * 60, "5 minutes"), (10 * 60, "10 minutes"), (20 * 60, "20 minutes"), (30 * 60, "30 minutes"), (60 * 60, "1 hour")]
        let last = config.lastSleepTimerSeconds
        if !items.contains(where: { $0.0 == last }) {
            let minutes = last / 60
            items.append((last, minutes.plural("minute", "minutes")))
        }
        items.sort { $0.0 < $1.0 }
        items.append((-1, "Custom"))
        return items
    }

    private func sleepTimerBar(_ seconds: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.divider).frame(height: 1)
            HStack {
                Text("Sleep timer")
                Spacer()
                Text(seconds.formattedDuration())
                IconButton(icon: "xmark") { player.stopSleepTimer() }
            }
            .font(.system(size: 16))
            .foregroundStyle(palette.textColor)
            .padding(.leading, 16)
            .padding(.trailing, 4)
        }
        .background(palette.backgroundColor)
    }

    // MARK: Action mode

    @ViewBuilder
    private var actionBar: some View {
        let close = { selection.removeAll() }
        switch tab {
        case .playlists:
            ActionModeBar(count: selection.count, onClose: close) {
                if selection.count == 1 {
                    IconButton(icon: "pencil") { renamePlaylist = library.playlists.first { selection.contains(String($0.id)) } }
                }
                IconButton(icon: "trash") { removePlaylists = true }
                IconButton(icon: "checklist") { selection = Set(library.playlists.map { String($0.id) }) }
            }
        case .folders:
            ActionModeBar(count: selection.count, onClose: close) {
                IconButton(icon: "minus.circle") {
                    config.addExcludedFolders(Array(selection))
                    selection.removeAll()
                    Task {
                        await library.scan()
                        player.reload(library)
                    }
                }
                IconButton(icon: "square.and.arrow.up") {
                    let tracks = library.folders.filter { selection.contains($0.path) }.flatMap { library.folderTracks($0.path) }
                    action = .share(tracks.filter { $0.fileURL != nil })
                }
            }
        case .artists:
            TrackActionBar(count: selection.count, tracks: { library.artistTracks(library.artists.filter { selection.contains($0.id) }) },
                           trackItems: false, selectAll: { selection = Set(library.artists.map(\.id)) }, close: close, action: $action)
        case .albums:
            TrackActionBar(count: selection.count, tracks: { library.albumTracks(library.albums.filter { selection.contains($0.id) }) },
                           trackItems: false, selectAll: { selection = Set(library.albums.map(\.id)) }, close: close, action: $action)
        case .tracks:
            TrackActionBar(count: selection.count, tracks: { library.tracks.filter { selection.contains($0.id) } },
                           selectAll: { selection = Set(library.tracks.map(\.id)) }, close: close, action: $action)
        case .genres:
            TrackActionBar(count: selection.count, tracks: { library.genreTracks(library.genres.filter { selection.contains($0.id) }) },
                           trackItems: false, selectAll: { selection = Set(library.genres.map(\.id)) }, close: close, action: $action)
        }
    }

    private func removeSelectedPlaylists(deleteFiles: Bool) {
        let ids = Set(library.playlists.filter { selection.contains(String($0.id)) }.map(\.id))
        if deleteFiles {
            let tracks = ids.flatMap { library.playlistTracks($0) }
            let deleted = library.delete(tracks)
            player.remove(Set(deleted.map(\.id)))
        }
        library.deletePlaylists(ids)
        selection.removeAll()
    }

    // MARK: Tabs

    private var bottomTabs: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { t in
                Button {
                    withAnimation { tab = t }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 20))
                        Text(t.title).font(.system(size: 12, weight: t == tab ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(t == tab ? palette.primaryColor : palette.textColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.surface.ignoresSafeArea(edges: .bottom))
    }

    private func pickDefaultTab() {
        guard !didPickTab else { return }
        didPickTab = true
        let i = config.lastUsedViewPagerPage
        tab = visibleTabs.indices.contains(i) ? visibleTabs[i] : (visibleTabs.first ?? .tracks)
    }
}

/// Playlists in a MusicList (string ids like every other list).
struct PlaylistItem: Identifiable {
    let playlist: Playlist
    var id: String { String(playlist.id) }
}

let m3uTypes: [UTType] = [UTType("public.m3u-playlist"), UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")].compactMap { $0 }
