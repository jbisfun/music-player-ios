import FossifyCommons
import SwiftUI
import UIKit

/// Glide cover art with the headset placeholder (rounded_corner_radius_small).
struct CoverArt: View {
    @Environment(\.palette) private var palette
    let track: Track?
    var size: CGFloat = 40
    var corner: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(palette.textColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: track?.id) {
            image = track.flatMap { Artwork.shared.cached($0, size: size) }
            if image == nil { image = await Artwork.shared.image(for: track, size: size) }
        }
    }
}

/// highlightTextPart(): the search query in the primary color.
func highlighted(_ text: String, _ query: String, _ color: Color) -> AttributedString {
    var a = AttributedString(text)
    if !query.isEmpty, let r = a.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        a[r].foregroundColor = color
    }
    return a
}

/// Row chrome shared by every list item: padding and the selected background.
struct RowFrame<Content: View>: View {
    @Environment(\.palette) private var palette
    let selected: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 14) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(selected ? palette.primaryColor.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
    }
}

struct TwoLines: View {
    @Environment(\.palette) private var palette
    let title: AttributedString
    let subtitle: AttributedString?
    var titleSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: titleSize)).foregroundStyle(palette.textColor).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(palette.textColor.opacity(0.8)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// item_track: cover or track number, title, "artist • album" and duration.
struct TrackRow: View {
    @Environment(\.palette) private var palette
    let track: Track
    var info: String?
    var number: String?
    var highlight = ""
    var selected = false
    var current = false

    var body: some View {
        RowFrame(selected: selected) {
            if let number {
                Text(number).font(.system(size: 16)).foregroundStyle(palette.textColor).frame(minWidth: 40)
            } else {
                CoverArt(track: track)
            }
            TwoLines(title: highlighted(track.title, highlight, palette.primaryColor),
                     subtitle: info.map { highlighted($0, highlight, palette.primaryColor) })
            Text(track.duration.formattedDuration())
                .font(.system(size: 14))
                .foregroundStyle(current ? palette.primaryColor : palette.textColor)
        }
        .foregroundStyle(current ? palette.primaryColor : palette.textColor)
    }
}

struct CoverRow: View {
    @Environment(\.palette) private var palette
    let cover: Track?
    let title: String
    let subtitle: String
    var highlight = ""
    var selected = false

    var body: some View {
        RowFrame(selected: selected) {
            CoverArt(track: cover, size: 48)
            TwoLines(title: highlighted(title, highlight, palette.primaryColor), subtitle: AttributedString(subtitle))
        }
    }
}

struct TextRow: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    var highlight = ""
    var selected = false

    var body: some View {
        RowFrame(selected: selected) {
            TwoLines(title: highlighted(title, highlight, palette.primaryColor), subtitle: AttributedString(subtitle), titleSize: 17)
        }
    }
}

/// item_section.
struct SectionRow: View {
    @Environment(\.palette) private var palette
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(palette.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

/// A selectable list (MyRecyclerView + MyRecyclerViewAdapter): tap opens, long press starts
/// the selection, a fast scroller on the right edge.
struct MusicList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var selection: Set<Item.ID>
    var selectable: (Item) -> Bool = { _ in true }
    let bubble: (Item) -> String
    let onClick: (Item) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    @State private var top: Item.ID?

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item, selection.contains(item.id))
                            .onTapGesture {
                                if selection.isEmpty {
                                    onClick(item)
                                } else if selectable(item) {
                                    toggleSelection(item.id, in: &selection)
                                }
                            }
                            .onLongPressGesture {
                                if selectable(item) { toggleSelection(item.id, in: &selection) }
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 8)
            }
            .scrollPosition(id: $top, anchor: .top)
            FastScroller(
                count: items.count,
                position: top.flatMap { id in items.firstIndex { $0.id == id } } ?? 0,
                bubbleText: { items.indices.contains($0) ? bubble(items[$0]) : "" },
                onScroll: { if items.indices.contains($0) { top = items[$0].id } }
            )
        }
    }
}

/// Lists that can be reordered by dragging while items are selected (playlists, queue).
struct ReorderList<Item: Identifiable, Row: View>: View {
    @Environment(\.palette) private var palette
    let items: [Item]
    @Binding var selection: Set<Item.ID>
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    var body: some View {
        List {
            ForEach(items) { item in
                row(item, selection.contains(item.id))
                    .onTapGesture { toggleSelection(item.id, in: &selection) }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(palette.backgroundColor)
            }
            .onMove(perform: onMove)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }
}

/// Placeholder texts of the fragments (tracks_placeholder / placeholder_2).
struct Placeholder: View {
    @Environment(\.palette) private var palette
    let text: String
    var action: String?
    var onAction: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Text(text)
                .font(.system(size: 17).italic())
                .foregroundStyle(palette.textColor)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: onAction) {
                    Text(action).font(.system(size: 17)).underline().foregroundStyle(palette.primaryColor)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// CurrentTrackBar: cover, "title • artist" and play/pause; opens the player.
struct CurrentTrackBar: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                Rectangle().fill(palette.divider).frame(height: 1)
                HStack(spacing: 12) {
                    CoverArt(track: track, size: 40)
                    Text(track.title + track.artistSuffix)
                        .font(.system(size: 16))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(palette.textColor)
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { router.push(.player) }
            }
            .background(palette.backgroundColor)
            .transition(.opacity)
        }
    }
}

/// Top bar with a back arrow, used by the secondary screens; the title can turn into a search field.
struct SearchableTopBar<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    @Binding var query: String
    @Binding var searching: Bool
    var canSearch = true
    @ViewBuilder let trailing: () -> Trailing
    @FocusState private var focused: Bool

    var body: some View {
        if searching {
            HStack(spacing: 4) {
                IconButton(icon: "arrow.left") {
                    query = ""
                    searching = false
                }
                TextField("", text: $query, prompt: Text("Search").foregroundStyle(palette.secondaryText))
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onAppear { focused = true }
                if !query.isEmpty { IconButton(icon: "xmark") { query = "" } }
            }
            .foregroundStyle(palette.textColor)
            .padding(.horizontal, 4)
            .frame(height: 56)
            .background(palette.backgroundColor)
        } else {
            TopBar(title: title, background: nil, tint: nil) {
                if canSearch { IconButton(icon: "magnifyingglass") { searching = true } }
                trailing()
            }
        }
    }
}
