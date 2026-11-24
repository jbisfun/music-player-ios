import FossifyCommons
import SwiftUI

/// EqualizerActivity: one slider per band (in millibels, snapped to whole dB) and the preset picker.
struct EqualizerView: View {
    @Environment(Config.self) private var config
    @Environment(Player.self) private var player
    @Environment(\.palette) private var palette
    @State private var pickPreset = false
    @State private var levels: [Double] = []

    private let range = Double(Equalizer.maxLevel - Equalizer.minLevel)

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Equalizer")
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Text("").frame(width: 70)
                        Text("\(Equalizer.minLevel / 100)")
                        Spacer()
                        Text("\(Equalizer.minLevel + Equalizer.maxLevel)")
                        Spacer()
                        Text("+\(Equalizer.maxLevel / 100)")
                    }
                    .font(.system(size: 14))
                    ForEach(Equalizer.bands.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Text(Equalizer.label(Equalizer.bands[i])).font(.system(size: 14)).frame(width: 70)
                            Slider(value: binding(i), in: 0...range) { editing in
                                if editing { draggingStarted() } else { config.equalizerBands[i] = Int(levels[i]) }
                            }
                            .tint(palette.primaryColor)
                        }
                        .padding(.vertical, 4)
                    }
                    Button { pickPreset = true } label: {
                        Text(presetName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(palette.primary.isWhite && palette.background.isWhite ? Color(argb: 0xFF2D2D2D) : palette.onPrimary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(palette.primaryColor))
                    }
                    .padding(.top, 16)
                }
                .foregroundStyle(palette.textColor)
                .padding(16)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .onAppear(perform: load)
        .sheet(isPresented: $pickPreset) {
            RadioDialog(title: nil, items: Equalizer.presets.indices.map { ($0, Equalizer.presets[$0].name) } + [(Equalizer.custom, "Custom")],
                        selected: config.equalizerPreset) { id in
                config.equalizerPreset = id
                load()
                player.applyEqualizer()
            }
        }
    }

    private var presetName: String {
        Equalizer.presets.indices.contains(config.equalizerPreset) ? Equalizer.presets[config.equalizerPreset].name : "Custom"
    }

    private func load() {
        levels = Equalizer.levels(config).map { Double($0 - Equalizer.minLevel) }
    }

    private func binding(_ i: Int) -> Binding<Double> {
        Binding(get: { levels.indices.contains(i) ? levels[i] : range / 2 }, set: { v in
            guard levels.indices.contains(i) else { return }
            levels[i] = (v / 100).rounded() * 100
            player.eq.bands[i].gain = Float(levels[i] + Double(Equalizer.minLevel)) / 100
        })
    }

    /// draggingStarted(): switches to the custom preset, keeping the current levels.
    private func draggingStarted() {
        guard config.equalizerPreset != Equalizer.custom else { return }
        config.equalizerPreset = Equalizer.custom
        for (i, l) in levels.enumerated() { config.equalizerBands[i] = Int(l) }
    }
}

/// SettingsActivity.
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @State private var manageTabs = false
    @State private var showFilename = false

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    Text("Color customization").sectionHeader(palette)
                    SettingsItem("Customize colors") { router.push(.customizeColors) }

                    Text("General").sectionHeader(palette)
                    SettingsItem("Manage excluded folders") { router.push(.excludedFolders) }
                    SettingsItem("Manage shown tabs") { manageTabs = true }
                    SettingsToggle("Swap previous/next headphone buttons", isOn: $config.swapPrevNext)
                    SettingsItem("Show filename as song title", value: config.showFilename.title) { showFilename = true }
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .sheet(isPresented: $manageTabs) { ManageVisibleTabsDialog() }
        .sheet(isPresented: $showFilename) {
            RadioDialog(title: nil, items: ShowFilename.allCases.map { ($0, $0.title) }, selected: config.showFilename) {
                config.showFilename = $0
            }
        }
    }
}

/// ExcludedFoldersActivity.
struct ExcludedFoldersView: View {
    @Environment(Config.self) private var config
    @Environment(MusicLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let folders = config.excludedFolders.sorted { $0.naturalCompare($1) < 0 }
        VStack(spacing: 0) {
            TopBar(title: "Manage excluded folders")
            if folders.isEmpty {
                Placeholder(text: "Excluding a folder will prevent the displaying of all audio files within. Files manually added to playlists will not be affected.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(folders, id: \.self) { f in
                            HStack {
                                Text(humanized(f)).font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading)
                                IconButton(icon: "xmark") {
                                    config.excludedFolders.remove(f)
                                    Task {
                                        await library.scan()
                                        player.reload(library)
                                    }
                                }
                            }
                            .foregroundStyle(palette.textColor)
                            .padding(.leading, 16)
                            .padding(.trailing, 4)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.backgroundColor.ignoresSafeArea())
    }

    private func humanized(_ path: String) -> String {
        path == musicLibraryFolder ? path : "Music Player" + (path.isEmpty ? "" : "/" + path)
    }
}

extension AppInfo {
    public static let musicPlayer = AppInfo(
        name: "Music Player", icon: "music.note", upstream: "Music-Player", port: "music-player-ios", policy: "musicplayer",
        faq: [("How can I fast-forward songs?",
               "You can click on the current or max duration texts near the seekbar, that will move the song either backward, or forward."),
              ("How can I select multiple items at once?",
               "Start the selection mode by long pressing one item, then tap on others to select them.")]
    )
}
