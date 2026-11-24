# music-player-ios

[Fossify Music Player](https://github.com/FossifyOrg/Music-Player) re-created for iOS in SwiftUI, on top of AVFoundation (`AVAudioEngine`) and MediaPlayer.

    idl build -c release     # -> build/release/FossifyMusicPlayer.ipa (ad-hoc signed; re-sign to install)
    idl install "<device>" FossifyMusicPlayer

Ported: playlists, folders, artists, albums, tracks and genres tabs with search, sorting (per playlist/folder too), fast scroller and multi-select actions (add to playlist/queue, play next, share, properties, rename song, delete, exclude folder); the "All tracks" playlist, create playlist (also from a folder or the queue), add file/folder to playlist, drag and drop order, M3U import/export; the player with seeking, tap-to-skip 10 s, shuffle, repeat off/all/one/stop after current song, playback speed, next track and the queue; background playback with lock screen controls, the 5-band equalizer with presets, sleep timer, restored queue and position, playing audio files opened from other apps; colors, shown tabs, excluded folders, swap previous/next headphone buttons and filename as title; the home-screen player widget (song info and previous/play-pause/next, shrinking to the controls row, configurable background color, alpha and text color).

Differences forced by iOS: songs come from the app's folder (Files › On My iPhone › Music Player) and the non-DRM songs of the Music library, which apps can't delete, rename or share; edited tags are stored by the app instead of being written into the files; the equalizer uses Android's standard bands and presets instead of the device's; lock screen and Control Center controls replace the notification; the home-screen widget is available inside launcher-ios (iOS home-screen widgets would need a WidgetKit extension) and no in-app language switch.

GPL-3.0, like the original.
