import AVFoundation
import MediaPlayer
import UIKit

/// getTrackCoverArt(): embedded artwork of files, MPMediaItemArtwork of music library songs.
@MainActor
final class Artwork {
    static let shared = Artwork()

    private let cache = NSCache<NSString, UIImage>()
    private var missing = Set<String>()

    func cached(_ track: Track, size: CGFloat) -> UIImage? {
        cache.object(forKey: key(track, size))
    }

    func image(for track: Track?, size: CGFloat) async -> UIImage? {
        guard let track else { return nil }
        let k = key(track, size)
        if let img = cache.object(forKey: k) { return img }
        if missing.contains(track.id) { return nil }
        let pixels = size * UIScreen.main.scale
        var image: UIImage?
        if let pid = track.persistentID {
            let q = MPMediaQuery.songs()
            q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid), forProperty: MPMediaItemPropertyPersistentID))
            image = q.items?.first?.artwork?.image(at: CGSize(width: pixels, height: pixels))
        } else if let url = track.fileURL {
            image = await Self.embedded(url)
        }
        guard let image else {
            missing.insert(track.id)
            return nil
        }
        let scaled = await image.byPreparingThumbnail(ofSize: Self.fit(image.size, max: pixels)) ?? image
        cache.setObject(scaled, forKey: k)
        return scaled
    }

    func clear() {
        cache.removeAllObjects()
        missing.removeAll()
    }

    private func key(_ t: Track, _ size: CGFloat) -> NSString { "\(t.id)#\(Int(size))" as NSString }

    nonisolated private static func embedded(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let img = UIImage(data: data) { return img }
        }
        return nil
    }

    nonisolated private static func fit(_ s: CGSize, max: CGFloat) -> CGSize {
        let ratio = min(1, max / Swift.max(s.width, s.height, 1))
        return CGSize(width: s.width * ratio, height: s.height * ratio)
    }
}
