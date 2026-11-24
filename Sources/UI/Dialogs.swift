import FossifyCommons
import SwiftUI

/// ChangeSortingDialog.
struct ChangeSortingDialog: View {
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let location: SortLocation
    let onChange: () -> Void

    @State private var sort = Sort.title
    @State private var descending = false
    @State private var useForThis = false
    @State private var loaded = false

    private var options: [(Int, String)] {
        switch location {
        case .tab(.playlists), .tab(.folders):
            return [(Sort.title, "Title"), (Sort.trackCount, "Track Count")]
        case .tab(.artists):
            return [(Sort.title, "Title"), (Sort.albumCount, "Album Count"), (Sort.trackCount, "Track Count")]
        case .tab(.albums):
            return [(Sort.title, "Title"), (Sort.artistTitle, "Artist Name"), (Sort.year, "Year"), (Sort.dateAdded, "Date added")]
        case .tab(.genres):
            return [(Sort.title, "Title"), (Sort.trackCount, "Track Count")]
        case .tab(.tracks), .folder, .genreTracks:
            return trackOptions
        case .playlist:
            return trackOptions + [(Sort.custom, "Custom")]
        }
    }

    private var trackOptions: [(Int, String)] {
        [(Sort.title, "Title"), (Sort.artistTitle, "Artist"), (Sort.duration, "Duration"), (Sort.trackID, "Track number"), (Sort.dateAdded, "Date added")]
    }

    private var current: Int {
        switch location {
        case .tab(.playlists): return config.playlistSorting
        case .tab(.folders): return config.folderSorting
        case .tab(.artists): return config.artistSorting
        case .tab(.albums): return config.albumSorting
        case .tab(.tracks): return config.trackSorting
        case .tab(.genres): return config.genreSorting
        case .playlist(let id): return config.properPlaylistSorting(id)
        case .folder(let path): return config.properFolderSorting(path)
        case .genreTracks: return config.trackSorting
        }
    }

    var body: some View {
        DialogFrame(title: "Sort by") {
            ForEach(options, id: \.0) { option in
                Button { sort = option.0 } label: { RadioRow(title: option.1, on: sort == option.0) }.buttonStyle(.plain)
            }
            if sort != Sort.custom {
                Divider().padding(.vertical, 8)
                Button { descending = false } label: { RadioRow(title: "Ascending", on: !descending) }.buttonStyle(.plain)
                Button { descending = true } label: { RadioRow(title: "Descending", on: descending) }.buttonStyle(.plain)
            }
            switch location {
            case .playlist, .folder:
                Divider().padding(.vertical, 8)
                CheckRow(title: location.isFolder ? "Use for this folder only" : "Use for this playlist only", on: $useForThis)
            default:
                EmptyView()
            }
            DialogButtons { confirm() }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let c = current
            sort = options.first { c & $0.0 != 0 }?.0 ?? Sort.title
            descending = c & Sort.descending != 0
            switch location {
            case .playlist(let id): useForThis = config.hasCustomPlaylistSorting(id)
            case .folder(let path): useForThis = config.hasCustomFolderSorting(path)
            default: break
            }
        }
    }

    private func confirm() {
        var sorting = sort
        if descending && sort != Sort.custom { sorting |= Sort.descending }
        dismiss()
        let isActivity: Bool
        switch location {
        case .tab: isActivity = false
        default: isActivity = true
        }
        guard current != sorting || isActivity else { return }
        switch location {
        case .tab(.playlists): config.playlistSorting = sorting
        case .tab(.folders): config.folderSorting = sorting
        case .tab(.artists): config.artistSorting = sorting
        case .tab(.albums): config.albumSorting = sorting
        case .tab(.tracks): config.trackSorting = sorting
        case .tab(.genres): config.genreSorting = sorting
        case .playlist(let id):
            if useForThis {
                config.saveCustomPlaylistSorting(id, sorting)
            } else {
                config.removeCustomPlaylistSorting(id)
                config.playlistTracksSorting = sorting
            }
        case .folder(let path):
            if useForThis {
                config.saveCustomFolderSorting(path, sorting)
            } else {
                config.removeCustomFolderSorting(path)
                config.playlistTracksSorting = sorting
            }
        case .genreTracks: config.trackSorting = sorting
        }
        onChange()
    }
}

extension SortLocation {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// A labelled DialogTextField (TextInputLayout with a hint).
struct LabeledField: View {
    @Environment(\.palette) private var palette
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13)).foregroundStyle(palette.primaryColor)
            DialogTextField(placeholder: label, text: $text)
        }
        .padding(.bottom, 8)
    }
}

/// NewPlaylistDialog: create or rename a playlist.
struct NewPlaylistDialog: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    var playlist: Playlist?
    let onDone: (Int) -> Void

    @State private var title = ""
    @State private var toast: String?

    var body: some View {
        DialogFrame(title: playlist == nil ? "Create new playlist" : "Rename playlist", scroll: false) {
            DialogTextField(placeholder: "Title", text: $title)
            DialogButtons { confirm() }
        }
        .presentationDetents([.height(220)])
        .toast($toast)
        .onAppear { title = playlist?.title ?? "" }
    }

    private func confirm() {
        let existing = library.playlistID(withTitle: title)
        if title.isEmpty {
            toast = "Please enter a name"
            return
        }
        if let existing, existing != playlist?.id {
            toast = "A playlist with that name already exists"
            return
        }
        let id: Int
        if let playlist {
            library.renamePlaylist(playlist.id, to: title)
            id = playlist.id
        } else {
            id = library.createPlaylist(title)
        }
        dismiss()
        onDone(id)
    }
}

/// SelectPlaylistDialog: pick a playlist, or create a new one.
struct SelectPlaylistDialog: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let onPick: (Int) -> Void

    @State private var createNew = false

    var body: some View {
        DialogFrame(title: nil) {
            ForEach(library.playlists) { p in
                Button {
                    onPick(p.id)
                    dismiss()
                } label: { RadioRow(title: p.title, on: false) }
                .buttonStyle(.plain)
            }
            if !library.playlists.isEmpty { Divider().padding(.vertical, 4) }
            Button { createNew = true } label: { RadioRow(title: "Create new playlist", on: false) }.buttonStyle(.plain)
        }
        .onAppear { if library.playlists.isEmpty { createNew = true } }
        .sheet(isPresented: $createNew) {
            NewPlaylistDialog { id in
                onPick(id)
                dismiss()
            }
        }
    }
}

/// RemovePlaylistDialog.
struct RemovePlaylistDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    var title: String?
    let onConfirm: (Bool) -> Void
    @State private var deleteFiles = false

    var body: some View {
        DialogFrame(title: "Remove playlist", scroll: false) {
            Text(title.map { "This will only remove playlist \"\($0)\". The actual files will not be deleted." }
                ?? "This will only remove the selected playlists. The actual files will not be deleted.")
                .foregroundStyle(palette.textColor)
                .padding(.bottom, 8)
            CheckRow(title: "Delete the files too", on: $deleteFiles)
            DialogButtons {
                dismiss()
                onConfirm(deleteFiles)
            }
        }
        .presentationDetents([.height(300)])
    }
}

/// EditDialog ("Rename song"): tags and file name.
struct EditDialog: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let onDone: (Track) -> Void

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var filename = ""
    @State private var ext = ""
    @State private var toast: String?

    var body: some View {
        DialogFrame(title: "Rename song") {
            LabeledField(label: "Title", text: $title)
            LabeledField(label: "Artist", text: $artist)
            LabeledField(label: "Album", text: $album)
            LabeledField(label: "Filename", text: $filename)
            LabeledField(label: "Extension", text: $ext)
            DialogButtons { confirm() }
        }
        .toast($toast)
        .onAppear {
            title = track.title
            artist = track.artist
            album = track.album
            filename = (track.filename as NSString).deletingPathExtension
            ext = track.filename.pathExt
        }
    }

    private func confirm() {
        if title.isEmpty || artist.isEmpty || filename.isEmpty || ext.isEmpty {
            toast = "Please fill in all fields"
            return
        }
        let unchanged = title == track.title && artist == track.artist && album == track.album
            && "\(filename).\(ext)" == track.filename
        if !unchanged, let updated = library.rename(track, title: title, artist: artist, album: album, filename: filename, ext: ext) {
            onDone(updated)
        }
        dismiss()
    }
}

/// SleepTimerCustomDialog.
struct SleepTimerCustomDialog: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Int) -> Void
    @State private var minutes = ""

    var body: some View {
        DialogFrame(title: "Sleep timer", scroll: false) {
            DialogTextField(placeholder: "Minutes", text: $minutes)
                .keyboardType(.numberPad)
            DialogButtons {
                dismiss()
                onPick((Int(minutes) ?? 0) * 60)
            }
        }
        .presentationDetents([.height(220)])
    }
}

/// ManageVisibleTabsDialog.
struct ManageVisibleTabsDialog: View {
    @Environment(Config.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var mask = 0

    var body: some View {
        DialogFrame(title: nil) {
            ForEach(MusicTab.allCases) { tab in
                CheckRow(title: tab.title, on: Binding(
                    get: { mask & tab.rawValue != 0 },
                    set: { mask = $0 ? mask | tab.rawValue : mask & ~tab.rawValue }
                ))
            }
            DialogButtons {
                config.showTabs = mask == 0 ? MusicTab.allMask : mask
                dismiss()
            }
        }
        .onAppear { mask = config.showTabs }
    }
}

/// ExportPlaylistDialog (the folder comes from the system save dialog, like on Android 10+).
struct ExportPlaylistDialog: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void
    @State private var filename = ""
    @State private var toast: String?

    var body: some View {
        DialogFrame(title: "Export playlist", scroll: false) {
            LabeledField(label: "Filename (without .m3u)", text: $filename)
            DialogButtons {
                if filename.isEmpty {
                    toast = "Please enter a name"
                } else if !filename.isAValidFilename {
                    toast = "The name contains invalid characters"
                } else {
                    dismiss()
                    onPick(filename)
                }
            }
        }
        .presentationDetents([.height(240)])
        .toast($toast)
        .onAppear {
            let f = DateFormatter()
            f.dateFormat = "yyyy_MM_dd_HH_mm_ss"
            filename = "playlist_\(f.string(from: Date()))"
        }
    }
}

/// PlaybackSpeedFragment: bottom sheet with a 0.25x - 3x slider in 0.05 steps.
struct PlaybackSpeedSheet: View {
    @Environment(Config.self) private var config
    @Environment(Player.self) private var player
    @Environment(\.palette) private var palette

    private static let minSpeed: Float = 0.25
    private static let maxSpeed: Float = 3
    private static let maxProgress = Int(maxSpeed * 100 + minSpeed * 100)
    private static let halfProgress = maxProgress / 2

    @State private var progress: Double = Double(halfProgress)

    var body: some View {
        VStack(spacing: 16) {
            Text("Playback speed").font(.system(size: 20, weight: .medium))
            HStack(spacing: 12) {
                IconButton(icon: "tortoise") { step(-1) }
                Slider(value: $progress, in: 0...Double(Self.maxProgress)) { _ in }
                    .tint(palette.primaryColor)
                    .onChange(of: progress) { _, p in update(Int(p)) }
                IconButton(icon: "hare") { step(1) }
            }
            Text(String(format: "%.2fx", config.playbackSpeed)).font(.system(size: 18))
        }
        .foregroundStyle(palette.textColor)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(palette.backgroundColor.ignoresSafeArea())
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .onAppear {
            if config.playbackSpeedProgress == -1 { config.playbackSpeedProgress = Self.halfProgress }
            progress = Double(config.playbackSpeedProgress)
        }
    }

    static func speed(_ progress: Int) -> Float {
        var s: Float
        if progress < halfProgress {
            s = (1 - minSpeed) * (Float(progress) / Float(halfProgress)) + minSpeed
        } else if progress > halfProgress {
            s = (maxSpeed - 1) * (Float(progress) / Float(halfProgress) - 1) + 1
        } else {
            s = 1
        }
        s = min(max(s, minSpeed), maxSpeed)
        return (s * 20).rounded() / 20
    }

    private func update(_ p: Int) {
        let s = Self.speed(p)
        guard s != config.playbackSpeed || p == config.playbackSpeedProgress else { return }
        config.playbackSpeed = s
        config.playbackSpeedProgress = p
        player.setSpeed(s)
    }

    /// reduceSpeed / increaseSpeed: move to the next progress that changes the speed.
    private func step(_ dir: Int) {
        var p = Int(progress)
        let currentSpeed = config.playbackSpeed
        while (dir < 0 && p > 0) || (dir > 0 && p < Self.maxProgress) {
            p += dir
            if Self.speed(p) != currentSpeed {
                progress = Double(p)
                break
            }
        }
    }
}
