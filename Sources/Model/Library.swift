import AVFoundation
import FossifyCommons
import Foundation
import MediaPlayer
import Observation

/// The music database (port of SongsDatabase + AudioHelper + SimpleMediaScanner + RoomHelper).
/// Songs come from the app's Documents folder (Files › On My iPhone › Music Player) and from
/// the system music library (MPMediaLibrary), the iOS counterparts of storage and MediaStore.
@MainActor
@Observable
final class MusicLibrary {
    static let shared = MusicLibrary()

    /// Everything the scanner found, with tag edits applied.
    private(set) var allTracks: [Track] = []
    /// allTracks without excluded folders, titles per "Show filename as song title", sorted by trackSorting.
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var genres: [Genre] = []
    private(set) var folders: [Folder] = []
    private(set) var byID: [String: Track] = [:]
    private(set) var scanning = false
    var showScanProgress = false
    var toast: String?
    /// Bumped whenever the content changes, so lists can refresh.
    private(set) var revision = 0

    @ObservationIgnored private var rawTracks: [Track] = []
    @ObservationIgnored private var overrides: [String: TagOverride] = [:]
    @ObservationIgnored private let config = Config.shared

    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    nonisolated private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicPlayer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private struct Store: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var overrides: [String: TagOverride]
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storeURL), let s = try? JSONDecoder().decode(Store.self, from: data) {
            rawTracks = s.tracks
            playlists = s.playlists
            overrides = s.overrides
        }
        rebuild()
    }

    private func save() {
        let s = Store(tracks: rawTracks, playlists: playlists, overrides: overrides)
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Derived lists

    /// Recomputes every list; call after settings that affect them change.
    func rebuild() {
        let show = config.showFilename
        allTracks = rawTracks.map { t in
            var t = t
            if let o = overrides[t.id] {
                t.title = o.title
                t.hasTitleTag = true
                t.artist = o.artist
                t.album = o.album
            }
            t.title = t.properTitle(show)
            return t
        }
        byID = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let excluded = config.excludedFolders
        let visible = allTracks.filter { !excluded.contains($0.folderPath) }
        tracks = visible.sorted(by: config.trackSorting)

        // splitIntoAlbums / splitIntoArtists / splitIntoGenres
        var albumMap: [String: [Track]] = [:]
        var artistMap: [String: [Track]] = [:]
        var genreMap: [String: [Track]] = [:]
        var folderMap: [String: [Track]] = [:]
        for t in visible {
            albumMap[t.album, default: []].append(t)
            artistMap[t.artist, default: []].append(t)
            if !t.genre.isEmpty { genreMap[t.genre, default: []].append(t) }
            folderMap[t.folderPath, default: []].append(t)
        }
        albums = albumMap.map { title, ts in
            let first = ts[0]
            return Album(title: title, artist: first.artist, year: first.year, trackCnt: ts.count, dateAdded: first.dateAdded, coverTrack: first)
        }
        .sorted { Album.compare($0, $1, sorting: config.albumSorting) }
        artists = artistMap.map { title, ts in
            Artist(title: title, albumCnt: Set(ts.map(\.album)).count, trackCnt: ts.count, coverTrack: ts[0])
        }
        .sorted { Artist.compare($0, $1, sorting: config.artistSorting) }
        genres = genreMap.map { Genre(title: $0, trackCnt: $1.count, coverTrack: $1[0]) }
            .sorted { Genre.compare($0, $1, sorting: config.genreSorting) }
        folders = folderMap.map { path, ts in Folder(title: ts[0].folderName, trackCount: ts.count, path: path) }
            .sorted { Folder.compare($0, $1, sorting: config.folderSorting) }
        playlists = playlists.sorted { Playlist.compare($0, $1, count: playlistTrackCount, sorting: config.playlistSorting) }
        revision += 1
    }

    func playlist(_ id: Int) -> Playlist? { playlists.first { $0.id == id } }

    func playlistTracks(_ id: Int) -> [Track] {
        (playlist(id)?.trackIDs ?? []).compactMap { byID[$0] }.sorted(by: config.properPlaylistSorting(id))
    }

    func playlistTrackCount(_ p: Playlist) -> Int { p.trackIDs.reduce(0) { $0 + (byID[$1] == nil ? 0 : 1) } }

    /// getAlbumTracks(): ordered by disc, track number and title.
    func albumTracks(_ title: String) -> [Track] {
        tracks.filter { $0.album == title }.sorted {
            if ($0.discNumber ?? 0) != ($1.discNumber ?? 0) { return ($0.discNumber ?? 0) < ($1.discNumber ?? 0) }
            if ($0.trackNumber ?? 0) != ($1.trackNumber ?? 0) { return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
            return $0.title.lowercased() < $1.title.lowercased()
        }
    }

    func albumTracks(_ albums: [Album]) -> [Track] { albums.flatMap { albumTracks($0.title) } }

    func artistAlbums(_ artist: String) -> [Album] {
        let titles = Set(tracks.filter { $0.artist == artist }.map(\.album))
        return albums.filter { titles.contains($0.title) }
    }

    func artistTracks(_ artists: [Artist]) -> [Track] { albumTracks(artists.flatMap { artistAlbums($0.title) }) }

    func genreTracks(_ genres: [Genre]) -> [Track] {
        let titles = Set(genres.map(\.title))
        return tracks.filter { titles.contains($0.genre) }
    }

    func folderTracks(_ path: String) -> [Track] {
        tracks.filter { $0.folderPath == path }.sorted(by: config.properFolderSorting(path))
    }

    // MARK: Playlists

    func playlistID(withTitle title: String) -> Int? { playlists.first { $0.title == title }?.id }

    func createPlaylist(_ title: String) -> Int {
        let id = max(allTracksPlaylistID, playlists.map(\.id).max() ?? 0) + 1
        playlists.append(Playlist(id: id, title: title, trackIDs: []))
        save()
        rebuild()
        return id
    }

    func renamePlaylist(_ id: Int, to title: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].title = title
        save()
        rebuild()
    }

    func deletePlaylists(_ ids: Set<Int>) {
        playlists.removeAll { ids.contains($0.id) }
        for id in ids { config.removeCustomPlaylistSorting(id) }
        save()
        rebuild()
    }

    /// insertTracksWithPlaylist(): appends the tracks that aren't in the playlist yet.
    func add(_ tracks: [Track], toPlaylist id: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var existing = Set(playlists[i].trackIDs)
        for t in tracks where !existing.contains(t.id) {
            playlists[i].trackIDs.append(t.id)
            existing.insert(t.id)
        }
        save()
        rebuild()
    }

    func remove(_ ids: Set<String>, fromPlaylist id: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs.removeAll { ids.contains($0) }
        // make sure these tracks aren't automatically re-added to the 'All tracks' playlist on rescan
        if id == allTracksPlaylistID { config.tracksRemovedFromAllTracksPlaylist.formUnion(ids) }
        save()
        rebuild()
    }

    /// Drag and drop in a playlist: stores the custom order.
    func setPlaylistOrder(_ id: Int, _ ordered: [String]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let rest = playlists[i].trackIDs.filter { !ordered.contains($0) }
        playlists[i].trackIDs = ordered + rest
        config.saveCustomPlaylistSorting(id, Sort.custom)
        save()
        rebuild()
    }

    // MARK: Files

    func fileURL(_ t: Track) -> URL? { t.fileURL }

    /// Tag editing applies to files only (library songs belong to the Music app).
    func canRename(_ t: Track) -> Bool { !t.isLibraryItem }

    /// deleteTracks(): removes the files (Music library songs can't be deleted by apps).
    func delete(_ list: [Track]) -> [Track] {
        var deleted: [Track] = []
        for t in list {
            guard let url = fileURL(t) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil || !FileManager.default.fileExists(atPath: url.path) {
                deleted.append(t)
            }
        }
        if deleted.count < list.count { toast = "Songs from the Music library can't be deleted by apps" }
        let ids = Set(deleted.map(\.id))
        rawTracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        save()
        rebuild()
        return deleted
    }

    /// EditDialog: stores the new tags and renames the file. Returns the updated track.
    func rename(_ track: Track, title: String, artist: String, album: String, filename: String, ext: String) -> Track? {
        guard let i = rawTracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        var raw = rawTracks[i]
        var id = raw.id
        let newPath = (raw.path.pathParent as NSString).appendingPathComponent("\(filename).\(ext)")
        if newPath != raw.path {
            let from = Self.documents.appendingPathComponent(raw.path)
            let to = Self.documents.appendingPathComponent(newPath)
            do { try FileManager.default.moveItem(at: from, to: to) } catch {
                toast = "An error occurred during the renaming"
                return nil
            }
            id = "file:" + newPath
            overrides[raw.id] = nil
            for p in playlists.indices {
                playlists[p].trackIDs = playlists[p].trackIDs.map { $0 == raw.id ? id : $0 }
            }
            raw.path = newPath
            raw.id = id
        }
        overrides[id] = TagOverride(title: title, artist: artist, album: album)
        rawTracks[i] = raw
        save()
        rebuild()
        return byID[id]
    }

    // MARK: Scanning (SimpleMediaScanner)

    /// Scans the Documents folder and the music library; `progress` shows the loading bar and
    /// a "No items found" toast like a manual "Rescan media".
    func scan(progress: Bool = false) async {
        if progress { showScanProgress = true }
        guard !scanning else { return }
        scanning = true
        defer {
            scanning = false
            showScanProgress = false
        }

        let cached = Dictionary(rawTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let docs = Self.documents
        let files = await Task.detached(priority: .userInitiated) { Self.findAudioFiles(in: docs) }.value
        var found: [Track] = []
        for (rel, modified) in files {
            let id = "file:" + rel
            if let c = cached[id], c.modified == modified {
                found.append(c)
            } else if let t = await Self.readTrack(url: docs.appendingPathComponent(rel), rel: rel, modified: modified) {
                found.append(t)
            }
        }
        found += await Self.libraryTracks()

        rawTracks = found
        updateAllTracksPlaylist()
        let ids = Set(found.map(\.id))
        for i in playlists.indices { playlists[i].trackIDs.removeAll { !ids.contains($0) } }
        overrides = overrides.filter { ids.contains($0.key) }
        save()
        rebuild()
        if progress && found.isEmpty { toast = "No items found." }
    }

    private func updateAllTracksPlaylist() {
        if !config.wasAllTracksPlaylistCreated {
            if playlist(allTracksPlaylistID) == nil {
                playlists.append(Playlist(id: allTracksPlaylistID, title: "All tracks", trackIDs: []))
            }
            config.wasAllTracksPlaylistCreated = true
        }
        guard let i = playlists.firstIndex(where: { $0.id == allTracksPlaylistID }) else { return }
        // avoid re-adding tracks that have been explicitly removed from 'All tracks' playlist
        let removed = config.tracksRemovedFromAllTracksPlaylist
        let excluded = config.excludedFolders
        var existing = Set(playlists[i].trackIDs)
        for t in rawTracks where !removed.contains(t.id) && !excluded.contains(t.folderPath) && !existing.contains(t.id) {
            playlists[i].trackIDs.append(t.id)
            existing.insert(t.id)
        }
    }

    /// findAudioFiles(): every audio file below Documents, skipping hidden files and .nomedia folders.
    nonisolated static func findAudioFiles(in root: URL) -> [(String, Double)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [(String, Double)] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                // Inbox holds the copies iOS makes of files opened from other apps.
                let isInbox = url.lastPathComponent == "Inbox" && url.deletingLastPathComponent().standardizedFileURL.path == rootPath
                if isInbox || fm.fileExists(atPath: url.appendingPathComponent(".nomedia").path) { e.skipDescendants() }
                continue
            }
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            result.append((rel, values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return result
    }

    /// MediaMetadataRetriever counterpart: reads the tags with AVFoundation.
    nonisolated static func readTrack(url: URL, rel: String, modified: Double) async -> Track? {
        let asset = AVURLAsset(url: url)
        guard let (items, duration) = try? await asset.load(.metadata, .duration) else { return nil }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = items + common

        func string(_ ids: [AVMetadataIdentifier]) async -> String? {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
                }
            }
            return nil
        }
        func number(_ stringIDs: [AVMetadataIdentifier], _ dataID: AVMetadataIdentifier) async -> Int? {
            if let s = await string(stringIDs), let n = s.firstNumber { return n }
            for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: dataID) {
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    let n = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                    if n > 0 { return n }
                }
            }
            return nil
        }

        let filename = rel.pathName
        let tagTitle = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        let artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist,
                                   .iTunesMetadataAlbumArtist, .id3MetadataBand]) ?? unknownString
        let folderName = rel.pathParent.isEmpty ? "Music Player" : rel.pathParent.pathName
        let album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum]) ?? folderName
        let genre = await string([.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre]) ?? ""
        let trackNumber = await number([.id3MetadataTrackNumber], .iTunesMetadataTrackNumber)
        let discNumber = await number([.id3MetadataPartOfASet], .iTunesMetadataDiscNumber)
        let yearText = await string([.id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate,
                                     .quickTimeMetadataYear, .commonIdentifierCreationDate])
        let year = yearText.flatMap { Int($0.prefix(4)) } ?? 0
        let seconds = duration.seconds.isFinite ? Int(duration.seconds) : 0

        return Track(
            id: "file:" + rel,
            title: tagTitle ?? (filename as NSString).deletingPathExtension,
            hasTitleTag: tagTitle != nil,
            artist: artist, album: album, genre: cleanGenre(genre), path: rel, duration: seconds,
            trackNumber: trackNumber, discNumber: discNumber, year: year, dateAdded: Int(modified), modified: modified
        )
    }

    /// ID3v1 style "(17)" genre references are left as text; strip the parentheses-only form.
    nonisolated private static func cleanGenre(_ g: String) -> String {
        let t = g.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("("), t.hasSuffix(")"), Int(t.dropFirst().dropLast()) != nil { return "" }
        return t
    }

    /// MediaStore counterpart: non-DRM songs of the system music library.
    nonisolated static func libraryTracks() async -> [Track] {
        var status = MPMediaLibrary.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0) } }
        }
        guard status == .authorized else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (MPMediaQuery.songs().items ?? []).compactMap { item -> Track? in
                guard item.assetURL != nil, !item.hasProtectedAsset else { return nil }
                let title = item.title ?? unknownString
                let year = item.releaseDate.map { Calendar.current.component(.year, from: $0) } ?? 0
                return Track(
                    id: "lib:\(item.persistentID)", title: title, hasTitleTag: item.title != nil,
                    artist: item.artist ?? item.albumArtist ?? unknownString, album: item.albumTitle ?? musicLibraryFolder,
                    genre: item.genre ?? "", path: "\(musicLibraryFolder)/\(title)", duration: Int(item.playbackDuration),
                    trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                    discNumber: item.discNumber > 0 ? item.discNumber : nil, year: year,
                    dateAdded: Int(item.dateAdded.timeIntervalSince1970), modified: 0
                )
            }
        }.value
    }

    // MARK: Picking files and folders (FilePickerDialog results)

    /// The FilePickerDialog root: the app's Documents folder.
    static var storageRoots: [StorageRoot] { [StorageRoot(path: documents.path, title: "Music Player")] }

    /// Path relative to Documents for an absolute path from the file picker.
    nonisolated static func relativePath(_ absolute: String) -> String? {
        for root in [documents.path, documents.standardizedFileURL.path, documents.resolvingSymlinksInPath().path] {
            if absolute == root { return "" }
            if absolute.hasPrefix(root + "/") { return String(absolute.dropFirst(root.count + 1)) }
        }
        return nil
    }

    /// getFolderTracks(): every audio file below the folder, rescanning first so new files are known.
    func folderTracksRecursive(_ absolute: String) async -> [Track] {
        guard let rel = Self.relativePath(absolute) else { return [] }
        await scan()
        let prefix = rel.isEmpty ? "" : rel + "/"
        return allTracks.filter { !$0.isLibraryItem && $0.path.hasPrefix(prefix) }
    }

    /// "Add file to playlist".
    func track(atPath absolute: String) async -> Track? {
        guard audioExtensions.contains(absolute.pathExt.lowercased()) else {
            toast = "Invalid file format"
            return nil
        }
        guard let rel = Self.relativePath(absolute) else { return nil }
        if byID["file:" + rel] == nil { await scan() }
        if let t = byID["file:" + rel] { return t }
        toast = "An unknown error occurred"
        return nil
    }

    // MARK: M3U (M3uImporter / M3uExporter)

    enum TransferResult { case ok, partial, fail }

    func importPlaylist(_ url: URL, into id: Int) -> TransferResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else { return .fail }
        var entries: [(title: String?, location: String)] = []
        var pendingTitle: String?
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l == "#EXTM3U" { continue }
            if l.hasPrefix("#EXTINF:") {
                if let comma = l.firstIndex(of: ",") { pendingTitle = String(l[l.index(after: comma)...]) }
            } else if !l.hasPrefix("#") {
                entries.append((pendingTitle, l))
                pendingTitle = nil
            }
        }
        var matched: [Track] = []
        for e in entries {
            let location = e.location.removingPercentEncoding ?? e.location
            for t in allTracks {
                let full = fileURL(t)?.path
                if location == t.path || location == full || location.hasSuffix("/" + t.path) || e.title == t.title
                    || e.title == "\(t.artist) - \(t.title)" {
                    matched.append(t)
                }
            }
        }
        add(matched, toPlaylist: id)
        return matched.isEmpty ? .fail : .ok
    }

    /// Writes the playlist to a temporary .m3u file for the system's save dialog.
    func exportPlaylist(_ tracks: [Track], filename: String) -> URL? {
        var out = "#EXTM3U\n"
        for t in tracks {
            out += "#EXTINF:\(t.duration),\(t.artist) - \(t.title)\n"
            out += "\(t.path)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).m3u")
        return (try? out.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }
}

extension String {
    /// firstNumber(): "3/12" -> 3.
    var firstNumber: Int? {
        let digits = trimmingCharacters(in: .whitespaces).split(separator: "/").first.map { $0.prefix { $0.isNumber } } ?? ""
        guard let n = Int(digits), n > 0 else { return nil }
        return n
    }
}
