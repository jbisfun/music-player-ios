import FossifyCommons
import SwiftUI

/// Port of MyWidgetProvider + WidgetConfigureActivity: the player widget (title, artist and
/// previous / play-pause / next) drawn on launcher-ios's home grid. It reads the live `Player`,
/// so it follows track changes and the playback state like TRACK_STATE_CHANGED did.
public enum MusicPlayerWidgets {
    public static let all: [HomeWidgetKind] = [
        HomeWidgetKind(
            id: "musicplayer.player",
            title: "Music Player",
            // widget_info.xml: targetCell 4x2, minWidth 250dp, minResizeHeight 30dp, resize both ways
            defaultSize: CGSize(width: 4, height: 2),
            minSize: CGSize(width: 3, height: 1),
            resizable: true,
            configure: { context, done in AnyView(MusicWidgetConfigureView(context: context, done: done)) },
            content: { context in AnyView(MusicPlayerWidgetView(context: context)) }
        ),
    ]
}

/// Widget colors: config.widgetBgColor / widgetTextColor, kept per placed widget. The last saved
/// pair is also remembered app-wide so a new widget starts with it, like upstream's shared config.
struct MusicWidgetColors {
    /// commons default_widget_bg_color / default_widget_text_color (color_primary).
    static let defaultBg: UInt32 = 0xAA00_0000
    static let defaultText: UInt32 = 0xFF10_6D1F
    private static let lastBgKey = "musicplayer_widget_bg_color"
    private static let lastTextKey = "musicplayer_widget_text_color"

    var bg: UInt32
    var text: UInt32

    static func load(_ context: HomeWidgetContext) -> MusicWidgetColors {
        let d = UserDefaults.standard
        func read(_ key: String, _ fallback: UInt32) -> UInt32 {
            (d.object(forKey: key) as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? fallback
        }
        let bg = read(context.key("bg_color"), read(lastBgKey, defaultBg))
        let text = read(context.key("text_color"), read(lastTextKey, defaultText))
        return MusicWidgetColors(bg: bg, text: text)
    }

    func save(_ context: HomeWidgetContext) {
        let d = UserDefaults.standard
        for (key, value) in [(context.key("bg_color"), bg), (context.key("text_color"), text),
                             (Self.lastBgKey, bg), (Self.lastTextKey, text)] {
            d.set(Int(value), forKey: key)
        }
    }
}

/// widget.xml (song info row above the controls) or small_widget.xml (controls only) once the
/// widget is shrunk below half its initial height, i.e. to a single grid row.
struct MusicPlayerWidgetView: View {
    let context: HomeWidgetContext
    @AppStorage private var bgRaw: Int
    @AppStorage private var textRaw: Int
    private var player: Player { Player.shared }
    private var config: Config { Config.shared }

    init(context: HomeWidgetContext) {
        self.context = context
        let colors = MusicWidgetColors.load(context)
        _bgRaw = AppStorage(wrappedValue: Int(colors.bg), context.key("bg_color"))
        _textRaw = AppStorage(wrappedValue: Int(colors.text), context.key("text_color"))
    }

    var body: some View {
        let small = context.size.height < 2
        let track = player.currentTrack
        MusicWidgetBody(
            small: small,
            title: track?.properTitle(config.showFilename) ?? "",
            artist: track?.artist ?? "",
            isPlaying: player.isPlaying,
            bg: UInt32(truncatingIfNeeded: bgRaw),
            text: UInt32(truncatingIfNeeded: textRaw),
            onOpen: { context.openApp(nil) },
            onPrevious: { control { player.previous() } },
            onPlayPause: { control { player.togglePlayback() } },
            onNext: { control { player.next() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: small ? .center : .top)
        // onEnabled/onAppWidgetOptionsChanged -> triggerUpdate(): prepare the player so the
        // saved queue's song shows up even before the app was opened
        .task { player.restoreIfNeeded(MusicLibrary.shared) }
    }

    /// handlePlayerControls(): opens the app when there's nothing to play.
    private func control(_ action: () -> Void) {
        player.restoreIfNeeded(MusicLibrary.shared)
        if player.currentTrack == nil {
            context.openApp(nil)
        } else {
            action()
        }
    }
}

/// The RemoteViews layout itself, shared by the widget and the configure preview.
struct MusicWidgetBody: View {
    let small: Bool
    let title: String
    let artist: String
    let isPlaying: Bool
    let bg: UInt32
    let text: UInt32
    var onOpen: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onNext: () -> Void = {}

    var body: some View {
        let textColor = Color(argb: text)
        VStack(spacing: 0) {
            if !small {
                // song_info_holder: 60dp, 4dp top padding, centered single-line title (18sp) and artist (16sp)
                VStack(spacing: 0) {
                    Text(title).font(.system(size: 18))
                    Text(artist).font(.system(size: 16))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .foregroundStyle(textColor)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
            }
            // widget_controls.xml: three equally weighted 48dp buttons with 8dp vertical padding
            HStack(spacing: 0) {
                button("backward.end.fill", onPrevious)
                button(isPlaying ? "pause.fill" : "play.fill", onPlayPause)
                button("forward.end.fill", onNext)
            }
            .frame(height: 60)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(argb: bg)))
    }

    private func button(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color(argb: text))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedStyle())
    }
}

/// WidgetConfigureActivity: a preview of the widget, the background color with its alpha
/// seekbar, the text color and OK.
struct MusicWidgetConfigureView: View {
    let context: HomeWidgetContext
    let done: (Bool) -> Void

    var body: some View {
        MusicWidgetConfigureContent(context: context, done: done).fossifyTheme()
    }
}

private struct MusicWidgetConfigureContent: View {
    let context: HomeWidgetContext
    let done: (Bool) -> Void
    @Environment(\.palette) private var palette
    @State private var bgWithoutAlpha: UInt32
    @State private var alpha: Double
    @State private var text: UInt32
    @State private var pickBg = false
    @State private var pickText = false

    init(context: HomeWidgetContext, done: @escaping (Bool) -> Void) {
        self.context = context
        self.done = done
        let colors = MusicWidgetColors.load(context)
        _bgWithoutAlpha = State(initialValue: colors.bg | 0xFF00_0000)
        _alpha = State(initialValue: Double(colors.bg >> 24) / 255)
        _text = State(initialValue: colors.text)
    }

    private var bg: UInt32 { (UInt32((alpha * 255).rounded()) << 24) | (bgWithoutAlpha & 0x00FF_FFFF) }

    var body: some View {
        let track = Player.shared.currentTrack
        VStack(spacing: 0) {
            TopBar(title: "Music Player", onBack: { done(false) })
            VStack(spacing: 4) {
                MusicWidgetBody(
                    small: false,
                    title: track?.properTitle(Config.shared.showFilename) ?? "Song title",
                    artist: track?.artist ?? "Artist",
                    isPlaying: Player.shared.isPlaying,
                    bg: bg,
                    text: text
                )
                .padding(.vertical, 16)
                Spacer()
                HStack(spacing: 8) {
                    swatch(bg) { pickBg = true }
                    Slider(value: $alpha, in: 0...1)
                        .padding(.horizontal, 16)
                        .frame(maxHeight: .infinity)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                }
                .frame(height: 50)
                HStack {
                    swatch(text) { pickText = true }
                    Spacer()
                    Button { save() } label: {
                        Text("OK")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(palette.primary.contrastColor)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(palette.primaryColor))
                    }
                }
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.85).ignoresSafeArea())
        .sheet(isPresented: $pickBg) {
            ColorPickerDialog(color: bgWithoutAlpha) { bgWithoutAlpha = $0 }
        }
        .sheet(isPresented: $pickText) {
            ColorPickerDialog(color: text) { text = $0 }
        }
    }

    private func swatch(_ color: UInt32, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(argb: color))
                .overlay(Circle().stroke(Color(argb: color | 0xFF00_0000), lineWidth: 2))
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    private func save() {
        MusicWidgetColors(bg: bg, text: text).save(context)
        done(true)
    }
}
