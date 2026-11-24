import FossifyCommons
import Foundation

/// A song. `id` is stable across scans: "file:<path relative to Documents>" or "lib:<persistent id>".
struct Track: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var hasTitleTag: Bool
    var artist: String
    var album: String
    var genre: String
    /// Path relative to the Documents folder; for music library songs "Music library/<title>".
    var path: String
    var duration: Int
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int
    var dateAdded: Int
    /// File modification date, used to skip unchanged files when rescanning.
    var modified: Double

    var isLibraryItem: Bool { id.hasPrefix("lib:") }
    /// A file opened from another app ("url:<absolute path>"), not part of the library.
    var isExternal: Bool { id.hasPrefix("url:") }

    var fileURL: URL? {
        if isLibraryItem { return nil }
        if isExternal { return URL(fileURLWithPath: String(id.dropFirst(4))) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
    }
    var persistentID: UInt64? { isLibraryItem ? UInt64(id.dropFirst(4)) : nil }

    /// Folder the track is listed under in the Folders tab.
    var folderPath: String { isLibraryItem ? musicLibraryFolder : path.pathParent }
    var folderName: String { folderPath.isEmpty ? "Music Player" : folderPath.pathName }
    var filename: String { path.pathName }

    /// getProperTitle(showFilename).
    func properTitle(_ show: ShowFilename) -> String {
        if isLibraryItem { return title }
        switch show {
        case .never: return title
        case .ifUnavailable: return hasTitleTag && title != unknownString ? title : filename
        case .always: return filename
        }
    }

    /// " • artist" suffix used by the current track bar and the "Next:" line.
    var artistSuffix: String {
        let a = artist.trimmingCharacters(in: .whitespaces)
        return a.isEmpty || a == unknownString ? "" : " • \(artist)"
    }

    static func compare(_ a: Track, _ b: Track, sorting: Int) -> Bool {
        var r: Int
        if sorting & Sort.title != 0 {
            r = unknownLast(a.title, b.title) ?? a.title.naturalCompare(b.title)
        } else if sorting & Sort.artistTitle != 0 {
            r = unknownLast(a.artist, b.artist) ?? a.artist.naturalCompare(b.artist)
        } else if sorting & Sort.trackID != 0 {
            let disc = compareInts(a.discNumber ?? Int.max, b.discNumber ?? Int.max)
            r = disc != 0 ? disc : compareInts(a.trackNumber ?? 0, b.trackNumber ?? 0)
        } else if sorting & Sort.dateAdded != 0 {
            r = compareInts(a.dateAdded, b.dateAdded)
        } else if sorting & Sort.custom != 0 {
            r = 0
        } else {
            r = compareInts(a.duration, b.duration)
        }
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }

    func bubbleText(_ sorting: Int) -> String {
        if sorting & Sort.title != 0 { return title }
        if sorting & Sort.artistTitle != 0 { return artist }
        return duration.formattedDuration()
    }
}

func compareInts(_ a: Int, _ b: Int) -> Int { a < b ? -1 : (a > b ? 1 : 0) }

/// Unknown titles/artists sort last.
func unknownLast(_ a: String, _ b: String) -> Int? {
    if a == unknownString && b != unknownString { return 1 }
    if a != unknownString && b == unknownString { return -1 }
    return nil
}

extension Array where Element == Track {
    /// sortSafely(sorting); custom order keeps the given (playlist) order.
    func sorted(by sorting: Int) -> [Track] {
        if sorting & Sort.custom != 0 { return self }
        return enumerated().sorted { l, r in
            if Track.compare(l.element, r.element, sorting: sorting) { return true }
            if Track.compare(r.element, l.element, sorting: sorting) { return false }
            return l.offset < r.offset
        }.map(\.element)
    }

    var totalDuration: Int { reduce(0) { $0 + $1.duration } }
}

struct Album: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var artist: String
    var year: Int
    var trackCnt: Int
    var dateAdded: Int
    var coverTrack: Track?

    static func compare(_ a: Album, _ b: Album, sorting: Int) -> Bool {
        var r: Int
        if sorting & Sort.title != 0 {
            r = unknownLast(a.title, b.title) ?? a.title.naturalCompare(b.title)
        } else if sorting & Sort.artistTitle != 0 {
            r = unknownLast(a.artist, b.artist) ?? a.artist.naturalCompare(b.artist)
        } else if sorting & Sort.dateAdded != 0 {
            r = compareInts(a.dateAdded, b.dateAdded)
        } else {
            r = compareInts(a.year, b.year)
        }
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }

    func bubbleText(_ sorting: Int) -> String {
        if sorting & Sort.title != 0 { return title }
        if sorting & Sort.artistTitle != 0 { return artist }
        return String(year)
    }
}

struct Artist: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var albumCnt: Int
    var trackCnt: Int
    var coverTrack: Track?

    static func compare(_ a: Artist, _ b: Artist, sorting: Int) -> Bool {
        var r: Int
        if sorting & Sort.title != 0 {
            r = unknownLast(a.title, b.title) ?? a.title.naturalCompare(b.title)
        } else if sorting & Sort.albumCount != 0 {
            r = compareInts(a.albumCnt, b.albumCnt)
        } else {
            r = compareInts(a.trackCnt, b.trackCnt)
        }
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }

    func bubbleText(_ sorting: Int) -> String {
        if sorting & Sort.title != 0 { return title }
        if sorting & Sort.albumCount != 0 { return String(albumCnt) }
        return String(trackCnt)
    }
}

struct Genre: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var trackCnt: Int
    var coverTrack: Track?

    static func compare(_ a: Genre, _ b: Genre, sorting: Int) -> Bool {
        var r = sorting & Sort.title != 0 ? a.title.naturalCompare(b.title) : compareInts(a.trackCnt, b.trackCnt)
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }

    func bubbleText(_ sorting: Int) -> String { sorting & Sort.title != 0 ? title : String(trackCnt) }
}

struct Folder: Hashable, Identifiable {
    var id: String { path }
    var title: String
    var trackCount: Int
    var path: String

    static func compare(_ a: Folder, _ b: Folder, sorting: Int) -> Bool {
        var r = sorting & Sort.title != 0 ? a.title.naturalCompare(b.title) : compareInts(a.trackCount, b.trackCount)
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }

    func bubbleText(_ sorting: Int) -> String { sorting & Sort.title != 0 ? title : String(trackCount) }
}

/// A playlist; `trackIDs` is the custom (drag and drop) order.
struct Playlist: Codable, Hashable, Identifiable {
    var id: Int
    var title: String
    var trackIDs: [String]

    static func compare(_ a: Playlist, _ b: Playlist, count: (Playlist) -> Int, sorting: Int) -> Bool {
        var r = sorting & Sort.title != 0 ? a.title.naturalCompare(b.title) : compareInts(count(a), count(b))
        if sorting & Sort.descending != 0 { r = -r }
        return r < 0
    }
}

/// Title/artist/album edits from the rename dialog, keyed by track id.
struct TagOverride: Codable, Hashable {
    var title: String
    var artist: String
    var album: String
}
