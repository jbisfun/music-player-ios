import FossifyCommons
import Observation
import SwiftUI

/// Port of the music player Config (SharedPreferences -> UserDefaults); colors live in FossifyCommons.BaseConfig.
@Observable
final class Config {
    static let shared = Config()

    @ObservationIgnored private let d = UserDefaults.standard

    var isShuffleEnabled: Bool { didSet { d.set(isShuffleEnabled, forKey: "shuffle") } }
    var playbackSetting: PlaybackSetting { didSet { d.set(playbackSetting.rawValue, forKey: "playback_setting") } }
    var showFilename: ShowFilename { didSet { d.set(showFilename.rawValue, forKey: "show_filename") } }
    var swapPrevNext: Bool { didSet { d.set(swapPrevNext, forKey: "swap_prev_next") } }
    var lastSleepTimerSeconds: Int { didSet { d.set(lastSleepTimerSeconds, forKey: "last_sleep_timer_seconds") } }
    var sleepInTS: Double { didSet { d.set(sleepInTS, forKey: "sleep_in_ts") } }

    var playlistSorting: Int { didSet { d.set(playlistSorting, forKey: "playlist_sorting") } }
    var playlistTracksSorting: Int { didSet { d.set(playlistTracksSorting, forKey: "playlist_tracks_sorting") } }
    var folderSorting: Int { didSet { d.set(folderSorting, forKey: "folder_sorting") } }
    var artistSorting: Int { didSet { d.set(artistSorting, forKey: "artist_sorting") } }
    var albumSorting: Int { didSet { d.set(albumSorting, forKey: "album_sorting") } }
    var trackSorting: Int { didSet { d.set(trackSorting, forKey: "track_sorting") } }
    var genreSorting: Int { didSet { d.set(genreSorting, forKey: "genre_sorting") } }
    /// sort_playlist_<id> and commons' sort_folder_<path>.
    var customSortings: [String: Int] { didSet { d.set(customSortings, forKey: "custom_sortings") } }

    var equalizerPreset: Int { didSet { d.set(equalizerPreset, forKey: "EQUALIZER_PRESET") } }
    /// Band index -> level offset from the lowest level (millibels), like upstream's JSON map.
    var equalizerBands: [Int: Int] {
        didSet { d.set(Dictionary(uniqueKeysWithValues: equalizerBands.map { (String($0.key), $0.value) }), forKey: "EQUALIZER_BANDS") }
    }
    var playbackSpeed: Float { didSet { d.set(playbackSpeed, forKey: "PLAYBACK_SPEED") } }
    var playbackSpeedProgress: Int { didSet { d.set(playbackSpeedProgress, forKey: "PLAYBACK_SPEED_PROGRESS") } }

    var wasAllTracksPlaylistCreated: Bool { didSet { d.set(wasAllTracksPlaylistCreated, forKey: "was_all_tracks_playlist_created") } }
    var tracksRemovedFromAllTracksPlaylist: Set<String> {
        didSet { d.set(Array(tracksRemovedFromAllTracksPlaylist), forKey: "tracks_removed_from_all_tracks_playlist") }
    }
    var showTabs: Int { didSet { d.set(showTabs, forKey: "show_tabs") } }
    var excludedFolders: Set<String> { didSet { d.set(Array(excludedFolders), forKey: "excluded_folders") } }
    var lastUsedViewPagerPage: Int { didSet { d.set(lastUsedViewPagerPage, forKey: "last_used_view_pager_page") } }
    var appRunCount: Int { didSet { d.set(appRunCount, forKey: "app_run_count") } }

    private init() {
        isShuffleEnabled = d.bool(forKey: "shuffle")
        playbackSetting = PlaybackSetting(rawValue: d.integer(forKey: "playback_setting")) ?? .repeatOff
        showFilename = ShowFilename(rawValue: d.object(forKey: "show_filename") as? Int ?? 2) ?? .ifUnavailable
        swapPrevNext = d.bool(forKey: "swap_prev_next")
        lastSleepTimerSeconds = d.object(forKey: "last_sleep_timer_seconds") as? Int ?? 30 * 60
        sleepInTS = d.double(forKey: "sleep_in_ts")
        playlistSorting = d.object(forKey: "playlist_sorting") as? Int ?? Sort.title
        playlistTracksSorting = d.object(forKey: "playlist_tracks_sorting") as? Int ?? Sort.title
        folderSorting = d.object(forKey: "folder_sorting") as? Int ?? Sort.title
        artistSorting = d.object(forKey: "artist_sorting") as? Int ?? Sort.title
        albumSorting = d.object(forKey: "album_sorting") as? Int ?? Sort.title
        trackSorting = d.object(forKey: "track_sorting") as? Int ?? Sort.title
        genreSorting = d.object(forKey: "genre_sorting") as? Int ?? Sort.title
        customSortings = d.dictionary(forKey: "custom_sortings") as? [String: Int] ?? [:]
        equalizerPreset = d.integer(forKey: "EQUALIZER_PRESET")
        let bands = d.dictionary(forKey: "EQUALIZER_BANDS") as? [String: Int] ?? [:]
        equalizerBands = Dictionary(uniqueKeysWithValues: bands.compactMap { k, v in Int(k).map { ($0, v) } })
        playbackSpeed = d.object(forKey: "PLAYBACK_SPEED") as? Float ?? 1
        playbackSpeedProgress = d.object(forKey: "PLAYBACK_SPEED_PROGRESS") as? Int ?? -1
        wasAllTracksPlaylistCreated = d.bool(forKey: "was_all_tracks_playlist_created")
        tracksRemovedFromAllTracksPlaylist = Set(d.stringArray(forKey: "tracks_removed_from_all_tracks_playlist") ?? [])
        showTabs = d.object(forKey: "show_tabs") as? Int ?? MusicTab.allMask
        excludedFolders = Set(d.stringArray(forKey: "excluded_folders") ?? [])
        lastUsedViewPagerPage = d.integer(forKey: "last_used_view_pager_page")
        appRunCount = d.integer(forKey: "app_run_count")
    }

    func isTabVisible(_ tab: MusicTab) -> Bool { showTabs & tab.rawValue != 0 }
    var visibleTabs: [MusicTab] { MusicTab.allCases.filter(isTabVisible) }

    // MARK: Per playlist / folder sorting

    func hasCustomPlaylistSorting(_ id: Int) -> Bool { customSortings["sort_playlist_\(id)"] != nil }
    func saveCustomPlaylistSorting(_ id: Int, _ value: Int) { customSortings["sort_playlist_\(id)"] = value }
    func removeCustomPlaylistSorting(_ id: Int) { customSortings["sort_playlist_\(id)"] = nil }
    func properPlaylistSorting(_ id: Int) -> Int { customSortings["sort_playlist_\(id)"] ?? playlistTracksSorting }

    func hasCustomFolderSorting(_ path: String) -> Bool { customSortings["sort_folder_\(path.lowercased())"] != nil }
    func saveCustomFolderSorting(_ path: String, _ value: Int) { customSortings["sort_folder_\(path.lowercased())"] = value }
    func removeCustomFolderSorting(_ path: String) { customSortings["sort_folder_\(path.lowercased())"] = nil }
    func properFolderSorting(_ path: String) -> Int { customSortings["sort_folder_\(path.lowercased())"] ?? playlistTracksSorting }

    func addExcludedFolders(_ paths: [String]) {
        excludedFolders.formUnion(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty })
    }
}
