import Foundation

/// Main screen tabs; raw values are the upstream TAB_* bit flags.
enum MusicTab: Int, CaseIterable, Identifiable {
    case playlists = 1, folders = 2, artists = 4, albums = 8, tracks = 16, genres = 32

    static let allMask = 1 | 2 | 4 | 8 | 16

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .folders: return "Folders"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .tracks: return "Tracks"
        case .genres: return "Genres"
        }
    }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .folders: return "folder"
        case .artists: return "person"
        case .albums: return "opticaldisc"
        case .tracks: return "music.note"
        case .genres: return "guitars"
        }
    }

    var searchHint: String { "Search \(title.lowercased())" }
}

/// PLAYER_SORT_BY_* and commons' SORT_DESCENDING.
enum Sort {
    static let title = 1
    static let trackCount = 2
    static let albumCount = 4
    static let year = 8
    static let duration = 16
    static let artistTitle = 32
    static let trackID = 64
    static let custom = 128
    static let dateAdded = 256
    static let descending = 1024
}

/// Where a sorting dialog was opened from (TAB_* or ACTIVITY_PLAYLIST_FOLDER).
enum SortLocation: Equatable {
    case tab(MusicTab)
    case playlist(Int)
    case folder(String)
    case genreTracks
}

enum PlaybackSetting: Int, CaseIterable {
    case repeatOff = 0, repeatPlaylist, repeatTrack, stopAfterCurrentTrack

    var next: PlaybackSetting {
        switch self {
        case .repeatOff: return .repeatPlaylist
        case .repeatPlaylist: return .repeatTrack
        case .repeatTrack: return .stopAfterCurrentTrack
        case .stopAfterCurrentTrack: return .repeatOff
        }
    }

    var title: String {
        switch self {
        case .repeatOff: return "Repeat off"
        case .repeatPlaylist: return "Repeat all"
        case .repeatTrack: return "Repeat current song"
        case .stopAfterCurrentTrack: return "Stop playback after current song"
        }
    }

    var icon: String {
        switch self {
        case .repeatOff, .repeatPlaylist: return "repeat"
        case .repeatTrack: return "repeat.1"
        case .stopAfterCurrentTrack: return "arrow.right.to.line"
        }
    }
}

/// SHOW_FILENAME_* values.
enum ShowFilename: Int, CaseIterable {
    case never = 1, ifUnavailable = 2, always = 3

    var title: String {
        switch self {
        case .never: return "Never"
        case .ifUnavailable: return "If title is not available"
        case .always: return "Always"
        }
    }
}

let allTracksPlaylistID = 1
/// MediaStore.UNKNOWN_STRING.
let unknownString = "<unknown>"
let seekIntervalSeconds = 10.0
let restartOnPreviousThreshold = 5.0
/// Pseudo folder holding the songs of the system music library (iOS has no paths for them).
let musicLibraryFolder = "Music library"

/// isAudioFast(): audio extensions the scanner picks up.
let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "m4b", "aac", "flac", "aif", "aiff", "aifc", "caf", "opus", "ogg", "alac", "mp4"]

extension Int {
    func plural(_ one: String, _ other: String) -> String {
        "\(self) \(self == 1 ? one : other)"
    }

    var tracksText: String { plural("Track", "Tracks") }
    var albumsText: String { plural("Album", "Albums") }
}

extension String {
    /// AlphanumericComparator on lowercased strings.
    func naturalCompare(_ other: String) -> Int {
        switch lowercased().localizedStandardCompare(other.lowercased()) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    /// normalizeString() + contains(ignoreCase).
    func searchContains(_ q: String) -> Bool {
        q.isEmpty || range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    var pathName: String { (self as NSString).lastPathComponent }
    var pathParent: String { (self as NSString).deletingLastPathComponent }
    var pathExt: String { (self as NSString).pathExtension }
}
