import FossifyCommons
import Observation
import SwiftUI
import UIKit

enum TracksSource: Hashable {
    case playlist(Int)
    case folder(String)
    case album(String)
    case genre(String)
}

enum Route: Hashable {
    case player
    case queue
    case tracks(TracksSource)
    case artist(String)
    case equalizer
    case settings
    case excludedFolders
    case customizeColors
    case about
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []
    var toast: String?

    func push(_ r: Route) {
        if r == .player, path.last == .player { return }
        path.append(r)
    }

    func pop() { if !path.isEmpty { path.removeLast() } }
}

/// The whole app as one view: the standalone app's window content, and what the launcher
/// presents. `openURL` is an audio file handed over by the launcher ("Open with").
public struct MusicPlayerRoot: View {
    @State private var router = Router()
    private let openURL: URL?

    public init(openURL: URL? = nil) {
        self.openURL = openURL
    }

    public var body: some View {
        RootView(openURL: openURL)
            .environment(router)
            .environment(MusicLibrary.shared)
            .environment(Player.shared)
            .environment(Config.shared)
            .fossifyTheme()
    }
}

struct RootView: View {
    let openURL: URL?
    @Environment(Router.self) private var router
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(Config.self) private var config
    @Environment(\.scenePhase) private var phase
    @State private var started = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            MainView()
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .player: PlayerView()
                        case .queue: QueueView()
                        case .tracks(let source): TracksView(source: source)
                        case .artist(let name): AlbumsView(artist: name)
                        case .equalizer: EqualizerView()
                        case .settings: SettingsView()
                        case .excludedFolders: ExcludedFoldersView()
                        case .customizeColors: CustomizeColorsView()
                        case .about: AboutView(app: .musicPlayer)
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .paletteBackground()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .toast($router.toast)
        .onChange(of: library.toast) { _, t in
            if let t {
                router.toast = t
                library.toast = nil
            }
        }
        .onChange(of: player.toast) { _, t in
            if let t {
                router.toast = t
                player.toast = nil
            }
        }
        .onAppear(perform: start)
        .onOpenURL(perform: open)
        .onChange(of: phase) { _, p in
            if p == .background { player.save() }
            if p == .active && started { Task { await refresh() } }
        }
        .onChange(of: config.showFilename) { _, _ in
            library.rebuild()
            player.reload(library)
        }
        .onChange(of: config.excludedFolders) { _, _ in library.rebuild() }
    }

    private func start() {
        guard !started else { return }
        started = true
        config.appRunCount += 1
        player.restoreIfNeeded(library)
        if let openURL { open(openURL) }
        // trigger a scan first so that the lists accurately reflect the scanning state
        Task { await refresh(progress: config.appRunCount == 1) }
    }

    private func refresh(progress: Bool = false) async {
        await library.scan(progress: progress)
        player.reload(library)
    }

    /// TrackActivity with ACTION_VIEW: plays a file opened from another app.
    private func open(_ url: URL) {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
            router.toast = "Invalid file format"
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        let rel = MusicLibrary.relativePath(url.path)
        Task {
            var track = rel.flatMap { library.byID["file:" + $0] }
            if track == nil {
                track = await MusicLibrary.readTrack(url: url, rel: url.lastPathComponent, modified: Date().timeIntervalSince1970)
                track?.id = "url:" + url.path
            }
            guard let track else {
                router.toast = "An unknown error occurred"
                return
            }
            player.prepare([track], play: true)
            router.push(.player)
        }
    }
}
