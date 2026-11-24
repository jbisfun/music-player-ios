import FossifyCommons
import SwiftUI

/// TrackActivity: cover, title, artist, seek bar, speed, transport controls and the next track.
struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var dragValue: Double?
    @State private var speedSheet = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ZStack(alignment: .top) {
                            cover(height: min(400, geo.size.height / 2))
                            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 70)
                                .allowsHitTesting(false)
                            HStack {
                                IconButton(icon: "arrow.left") { dismiss() }
                                Spacer()
                            }
                            .foregroundStyle(.white)
                        }
                        info
                        progress
                        controls
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                nextTrack
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .offset(y: dragOffset)
        .gesture(
            // fling down to close, like setupFlingListener
            DragGesture(minimumDistance: 30)
                .onChanged { v in if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) { dragOffset = v.translation.height } }
                .onEnded { v in
                    if v.translation.height > 100 && abs(v.translation.height) > abs(v.translation.width) {
                        dismiss()
                    }
                    withAnimation { dragOffset = 0 }
                }
        )
        .sheet(isPresented: $speedSheet) { PlaybackSpeedSheet() }
        .onChange(of: player.currentTrack == nil) { _, gone in if gone { dismiss() } }
    }

    @ViewBuilder
    private func cover(height: CGFloat) -> some View {
        TopArt(track: player.currentTrack, height: height)
    }

    private var info: some View {
        VStack(spacing: 4) {
            Text(player.currentTrack?.title ?? "")
                .font(.system(size: 22, weight: .medium))
                .multilineTextAlignment(.center)
                .onLongPressGesture { router.toast = Launcher.copy(player.currentTrack?.title ?? "") }
            Text(player.currentTrack?.artist ?? "")
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .onLongPressGesture { router.toast = Launcher.copy(player.currentTrack?.artist ?? "") }
        }
        .foregroundStyle(palette.textColor)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
    }

    private var progress: some View {
        let duration = max(player.duration, 1)
        let value = dragValue ?? min(player.position, duration)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { player.seekBack() } label: {
                    Text(Int(value).formattedDuration()).font(.system(size: 14)).monospacedDigit().frame(minWidth: 48)
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { value }, set: { dragValue = $0 }), in: 0...duration) { editing in
                    if !editing, let v = dragValue {
                        player.seek(to: v)
                        dragValue = nil
                    }
                }
                .tint(palette.primaryColor)
                Button { player.seekForward() } label: {
                    Text(Int(player.duration).formattedDuration()).font(.system(size: 14)).monospacedDigit().frame(minWidth: 48)
                }
                .buttonStyle(.plain)
            }
            Button { speedSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: config.playbackSpeed < 1 ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent")
                    Text(speedText)
                }
                .font(.system(size: 15))
                .frame(height: 44)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.textColor)
        .padding(.horizontal, 12)
        .padding(.top, 16)
    }

    /// DecimalFormat("#.##") + "x".
    private var speedText: String {
        let s = (Double(config.playbackSpeed) * 100).rounded() / 100
        return (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + "x"
    }

    private var controls: some View {
        HStack {
            Button { toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(config.isShuffleEnabled ? palette.primaryColor : palette.textColor)
                    .opacity(config.isShuffleEnabled ? 1 : 0.5)
            }
            .accessibilityLabel(config.isShuffleEnabled ? "Disable shuffle" : "Enable shuffle")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
            Spacer()
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill") }
            Spacer()
            Button { togglePlaybackSetting() } label: {
                let s = config.playbackSetting
                Image(systemName: s.icon)
                    .foregroundStyle(s == .repeatOff ? palette.textColor : palette.primaryColor)
                    .opacity(s == .repeatOff ? 0.5 : 1)
            }
            .accessibilityLabel(config.playbackSetting.next.title)
        }
        .font(.system(size: 26))
        .foregroundStyle(palette.textColor)
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .frame(height: 80)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var nextTrack: some View {
        if let next = player.nextTrack {
            VStack(spacing: 0) {
                Rectangle().fill(palette.divider).frame(height: 1)
                HStack(spacing: 12) {
                    CoverArt(track: next, size: 40)
                    Text("Next: \(next.title)\(next.artistSuffix)").font(.system(size: 16)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { router.push(.queue) }
            }
            .background(palette.backgroundColor)
        }
    }

    private func toggleShuffle() {
        player.toggleShuffle()
        router.toast = config.isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled"
    }

    private func togglePlaybackSetting() {
        config.playbackSetting = config.playbackSetting.next
        router.toast = config.playbackSetting.title
    }
}

/// The big cover (fitCenter, so audiobook covers show whole) or the headset placeholder.
struct TopArt: View {
    @Environment(\.palette) private var palette
    let track: Track?
    let height: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "headphones").font(.system(size: height * 0.5)).foregroundStyle(palette.textColor)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .task(id: track?.id) {
            image = nil
            image = await Artwork.shared.image(for: track, size: 600)
        }
    }
}
