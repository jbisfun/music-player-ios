import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Port of PlaybackService + SimpleMusicPlayer + MediaSessionCallback: an AVAudioEngine player
/// (player node -> time pitch for the playback speed -> 5 band equalizer) with the queue,
/// shuffle order, repeat modes, sleep timer, lock screen controls and the saved queue.
@MainActor
@Observable
final class Player {
    static let shared = Player()

    /// Queue in insertion order and the play order (shuffled or identity) as indices into it.
    private(set) var items: [Track] = []
    private(set) var order: [Int] = []
    private(set) var current: Int?
    private(set) var isPlaying = false
    /// Current position in seconds, refreshed while playing.
    private(set) var position: Double = 0
    private(set) var sleepRemaining: Int?
    var toast: String?
    /// Bumped on every track change (onMediaItemTransition).
    private(set) var transitions = 0

    @ObservationIgnored private let config = Config.shared
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let pitch = AVAudioUnitTimePitch()
    @ObservationIgnored let eq = AVAudioUnitEQ(numberOfBands: Equalizer.bands.count)
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var wasInterrupted = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var lastSave = Date.distantPast

    var currentTrack: Track? { current.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    /// Queue as shown in the queue screen (currentMediaItemsShuffled).
    var queueInPlayOrder: [Track] { order.compactMap { items.indices.contains($0) ? items[$0] : nil } }

    private var orderPosition: Int? { current.flatMap { order.firstIndex(of: $0) } }

    /// Player.nextMediaItem: the next one, wrapping to the first at the end.
    var nextTrack: Track? {
        guard let pos = orderPosition, !order.isEmpty else { return nil }
        return items[order[(pos + 1) % order.count]]
    }

    var duration: Double {
        if let file { return Double(file.length) / file.processingFormat.sampleRate }
        return Double(currentTrack?.duration ?? 0)
    }

    private init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.attach(eq)
        pitch.rate = config.playbackSpeed
        Equalizer.apply(to: eq, config: config)
        setupSession()
        setupRemoteCommands()
        if config.sleepInTS > Date().timeIntervalSince1970 * 1000 { startSleepTimer() } else { config.sleepInTS = 0 }
    }

    // MARK: Session & system integration

    private func setupSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began, self.isPlaying {
                    self.pause()
                    self.wasInterrupted = true
                } else if type == .ended {
                    if self.wasInterrupted && options.contains(.shouldResume) { self.play() }
                    self.wasInterrupted = false
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // ExoPlayer's handleAudioBecomingNoisy: pause when headphones are unplugged.
            if reason == .oldDeviceUnavailable { MainActor.assumeIsolated { self?.pause() } }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                let pos = self.currentTime
                self.isPlaying = false
                self.seek(to: pos)
                self.play()
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayback(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.config.swapPrevNext { self.previous() } else { self.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.config.swapPrevNext { self.next() } else { self.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(config.playbackSpeed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(config.playbackSpeed),
        ]
        if let img = Artwork.shared.cached(t, size: 300) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if Artwork.shared.cached(t, size: 300) == nil {
            Task {
                if await Artwork.shared.image(for: t, size: 300) != nil, currentTrack?.id == t.id { updateNowPlaying() }
            }
        }
    }

    // MARK: Queue

    /// prepareUsingTracks(): replaces the queue.
    func prepare(_ tracks: [Track], startIndex: Int = 0, position: Double = 0, play: Bool) {
        guard !tracks.isEmpty else { return }
        items = tracks
        let start = min(max(startIndex, 0), tracks.count - 1)
        order = makeOrder(count: tracks.count, first: start)
        load(start, at: position, play: play)
        save(force: true)
    }

    private func makeOrder(count: Int, first: Int) -> [Int] {
        guard config.isShuffleEnabled else { return Array(0..<count) }
        var rest = Array(0..<count).filter { $0 != first }
        rest.shuffle()
        return [first] + rest
    }

    /// maybePreparePlayer(): restores the saved queue, or queues every track like initQueue().
    func restoreIfNeeded(_ library: MusicLibrary) {
        guard !restored, currentTrack == nil else { return }
        if let saved = SavedQueue.load() {
            let tracks = saved.ids.compactMap { library.byID[$0] }
            if let cur = saved.current, let idx = tracks.firstIndex(where: { $0.id == cur }) {
                restored = true
                items = tracks
                let valid = saved.order.filter { $0 < tracks.count }
                order = valid.count == tracks.count && config.isShuffleEnabled ? valid : makeOrder(count: tracks.count, first: idx)
                load(idx, at: saved.position, play: false)
                return
            }
        }
        guard !library.tracks.isEmpty else { return }
        restored = true
        prepare(library.tracks, play: false)
    }

    /// RELOAD_CONTENT after a rescan: drops vanished tracks and picks up edited tags.
    func reload(_ library: MusicLibrary) {
        let gone = Set(items.filter { !$0.isExternal && library.byID[$0.id] == nil }.map(\.id))
        if !gone.isEmpty { remove(gone) }
        items = items.map { library.byID[$0.id] ?? $0 }
        if currentTrack == nil { restoreIfNeeded(library) }
        updateNowPlaying()
    }

    /// addTracksToQueue(): appends the tracks that aren't queued yet.
    func addToQueue(_ tracks: [Track]) {
        let existing = Set(items.map(\.id))
        let new = tracks.filter { !existing.contains($0.id) }
        guard !new.isEmpty else { return }
        if items.isEmpty {
            prepare(new, play: false)
            return
        }
        for t in new {
            items.append(t)
            order.append(items.count - 1)
        }
        save(force: true)
    }

    /// SET_NEXT_ITEM: moves or inserts the track right after the current one.
    func playNext(_ track: Track) {
        guard let pos = orderPosition else {
            prepare([track], play: false)
            return
        }
        let idx: Int
        if let existing = items.firstIndex(where: { $0.id == track.id }) {
            guard existing != current else { return }
            idx = existing
            order.removeAll { $0 == idx }
        } else {
            items.append(track)
            idx = items.count - 1
        }
        let insertAt = min((order.firstIndex(of: current ?? -1) ?? pos) + 1, order.count)
        order.insert(idx, at: insertAt)
        if !config.isShuffleEnabled { reindexFromOrder() }
        save(force: true)
    }

    /// removeQueueItems().
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let currentID = currentTrack?.id
        let currentRemoved = currentID.map(ids.contains) ?? false
        var nextID: String?
        if currentRemoved, let pos = orderPosition {
            nextID = order[(pos + 1)...].map { items[$0].id }.first { !ids.contains($0) }
                ?? order[..<pos].map { items[$0].id }.first { !ids.contains($0) }
        }
        let keptOrderIDs = order.map { items[$0].id }.filter { !ids.contains($0) }
        items.removeAll { ids.contains($0.id) }
        let index = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        order = keptOrderIDs.compactMap { index[$0] }
        if currentRemoved {
            let wasPlaying = isPlaying
            stopNode()
            isPlaying = false
            file = nil
            if let nextID, let i = index[nextID] {
                load(i, at: 0, play: wasPlaying)
            } else {
                current = nil
                position = 0
                updateNowPlaying()
                transitions += 1
            }
        } else {
            current = currentID.flatMap { index[$0] }
        }
        save(force: true)
    }

    /// Drag and drop in the queue screen (moveMediaItem / SET_SHUFFLE_ORDER).
    func moveInQueue(from: IndexSet, to: Int) {
        order.move(fromOffsets: from, toOffset: to)
        if !config.isShuffleEnabled { reindexFromOrder() }
        save(force: true)
    }

    /// Without shuffle the play order is the queue order itself.
    private func reindexFromOrder() {
        let currentID = currentTrack?.id
        items = order.map { items[$0] }
        order = Array(items.indices)
        current = currentID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// After renaming a file the track gets a new id.
    func replace(_ oldID: String, with track: Track) {
        guard let i = items.firstIndex(where: { $0.id == oldID }) else { return }
        items[i] = track
        if i == current { updateNowPlaying() }
        save(force: true)
    }

    /// Queue screen click: seekTo(index, 0) and play.
    func playQueueItem(_ track: Track) {
        guard let i = items.firstIndex(where: { $0.id == track.id }) else { return }
        load(i, at: 0, play: true)
    }

    // MARK: Transport

    func togglePlayback() { isPlaying ? pause() : play() }

    func play() {
        guard let file else {
            if let current { load(current, at: position, play: true) }
            return
        }
        guard !isPlaying else { return }
        guard startEngine() else {
            toast = "An unknown error occurred"
            return
        }
        schedule(file, from: startFrame)
        node.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
        save(force: true)
    }

    func pause() {
        guard isPlaying else { return }
        startFrame = currentFrame
        stopNode()
        isPlaying = false
        position = currentTime
        ticker?.cancel()
        updateNowPlaying()
        save(force: true)
    }

    func seek(to seconds: Double) {
        guard let file else {
            position = max(0, seconds)
            return
        }
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * file.processingFormat.sampleRate)
        if isPlaying, startEngine() {
            schedule(file, from: frame)
            node.play()
        } else {
            if isPlaying { pause() }
            startFrame = frame
        }
        position = currentTime
        updateNowPlaying()
    }

    func seekBack() { seek(to: currentTime - seekIntervalSeconds) }
    func seekForward() { seek(to: currentTime + seekIntervalSeconds) }

    /// SimpleMusicPlayer.seekToNext(): wraps to the first track at the end, regardless of the repeat mode.
    func next() {
        guard let pos = orderPosition, !order.isEmpty else { return }
        load(order[(pos + 1) % order.count], at: 0, play: true)
    }

    /// seekToPrevious(): restarts the track after 5 seconds, wraps to the last one at the start.
    func previous() {
        guard let pos = orderPosition, !order.isEmpty else { return }
        if currentTime > restartOnPreviousThreshold {
            seek(to: 0)
            play()
            return
        }
        load(order[(pos - 1 + order.count) % order.count], at: 0, play: true)
    }

    func toggleShuffle() {
        config.isShuffleEnabled.toggle()
        guard let current else { return }
        order = config.isShuffleEnabled ? makeOrder(count: items.count, first: current) : Array(items.indices)
        save(force: true)
    }

    func setSpeed(_ speed: Float) {
        pitch.rate = speed
        updateNowPlaying()
        startTicker()
    }

    func applyEqualizer() { Equalizer.apply(to: eq, config: config) }

    /// Repeat handling at the end of a track (PlayerListener + ExoPlayer repeat modes).
    private func trackFinished() {
        guard let pos = orderPosition else { return }
        switch config.playbackSetting {
        case .repeatTrack:
            seek(to: 0)
        case .stopAfterCurrentTrack:
            isPlaying = false
            ticker?.cancel()
            seek(to: 0)
        case .repeatPlaylist:
            load(order[(pos + 1) % order.count], at: 0, play: true)
        case .repeatOff:
            if pos + 1 < order.count {
                load(order[pos + 1], at: 0, play: true)
            } else {
                isPlaying = false
                ticker?.cancel()
                seek(to: 0)
                save(force: true)
            }
        }
    }

    // MARK: Engine

    private var currentFrame: AVAudioFramePosition {
        if isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) {
            return startFrame + pt.sampleTime
        }
        return startFrame
    }

    var currentTime: Double {
        guard let file else { return position }
        return min(Double(currentFrame) / file.processingFormat.sampleRate, duration)
    }

    /// Activates the playback session and starts the engine (other apps in the launcher may
    /// have changed the session category).
    private func startEngine() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            if s.category != .playback { try s.setCategory(.playback, mode: .default) }
            try s.setActive(true)
            if !engine.isRunning { try engine.start() }
            return true
        } catch {
            return false
        }
    }

    private func stopNode() {
        generation += 1
        node.stop()
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition) {
        stopNode()
        let start = max(0, min(frame, file.length))
        startFrame = start
        let gen = generation
        let count = AVAudioFrameCount(file.length - start)
        guard count > 0 else {
            Task { @MainActor in if self.generation == gen { self.trackFinished() } }
            return
        }
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen, self.isPlaying else { return }
                self.trackFinished()
            }
        }
    }

    /// Opens the track at `index` and starts it at `seconds`.
    private func load(_ index: Int, at seconds: Double, play shouldPlay: Bool) {
        guard items.indices.contains(index) else { return }
        let track = items[index]
        let changed = current != index
        stopNode()
        isPlaying = false
        ticker?.cancel()
        current = index
        position = seconds
        file = nil
        loadToken += 1
        let token = loadToken
        if changed { transitions += 1 }
        updateNowPlaying()
        Task {
            let opened = await Self.openFile(track)
            guard token == loadToken else { return }
            guard let opened else {
                toast = "An unknown error occurred"
                return
            }
            connect(opened.processingFormat)
            file = opened
            startFrame = AVAudioFramePosition(max(0, seconds) * opened.processingFormat.sampleRate)
            if shouldPlay { play() } else { updateNowPlaying() }
            save(force: true)
        }
    }

    private func connect(_ format: AVAudioFormat) {
        guard connectedFormat != format else { return }
        engine.stop()
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        engine.prepare()
    }

    /// Files play directly; music library songs are read through their asset URL, or exported
    /// to an m4a copy in Caches when Core Audio can't read the library URL.
    nonisolated static func openFile(_ track: Track) async -> AVAudioFile? {
        if let url = track.fileURL { return try? AVAudioFile(forReading: url) }
        guard let pid = track.persistentID else { return nil }
        let q = MPMediaQuery.songs()
        q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid), forProperty: MPMediaItemPropertyPersistentID))
        guard let assetURL = q.items?.first?.assetURL else { return nil }
        if let f = try? AVAudioFile(forReading: assetURL) { return f }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LibraryExport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(pid).m4a")
        if !FileManager.default.fileExists(atPath: dest.path) {
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: assetURL), presetName: AVAssetExportPresetAppleM4A) else { return nil }
            session.outputURL = dest
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else { return nil }
        }
        return try? AVAudioFile(forReading: dest)
    }

    private func startTicker() {
        ticker?.cancel()
        guard isPlaying else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let speed = Double(self?.config.playbackSpeed ?? 1)
                try? await Task.sleep(for: .milliseconds(Int(150 / max(speed, 0.25))))
                guard let self, self.isPlaying else { return }
                self.position = self.currentTime
                if Date().timeIntervalSince(self.lastSave) > 5 { self.save() }
            }
        }
    }

    // MARK: Sleep timer

    func startSleepTimer(seconds: Int? = nil) {
        if let seconds {
            config.lastSleepTimerSeconds = seconds
            config.sleepInTS = Date().timeIntervalSince1970 * 1000 + Double(seconds) * 1000
        }
        sleepTask?.cancel()
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = Int(((self.config.sleepInTS - Date().timeIntervalSince1970 * 1000) / 1000).rounded(.up))
                if left <= 0 {
                    self.config.sleepInTS = 0
                    self.sleepRemaining = nil
                    self.pause()
                    return
                }
                self.sleepRemaining = left
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepRemaining = nil
        config.sleepInTS = 0
    }

    // MARK: Saved queue (queue_items table)

    func save(force: Bool = false) {
        lastSave = Date()
        let saved = SavedQueue(ids: items.filter { !$0.isExternal }.map(\.id), order: order, current: currentTrack?.id, position: currentTime)
        saved.write()
    }
}

struct SavedQueue: Codable {
    var ids: [String]
    var order: [Int]
    var current: String?
    var position: Double

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicPlayer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    static func load() -> SavedQueue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedQueue.self, from: data)
    }

    func write() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
