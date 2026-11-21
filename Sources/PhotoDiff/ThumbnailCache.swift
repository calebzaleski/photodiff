import AppKit
import ImageIO
import UniformTypeIdentifiers
import PhotoDiffCore

/// Decodes grid thumbnails on demand and keeps a bounded number in memory, so a result
/// of several thousand photos scrolls immediately instead of decoding everything first.
///
/// The work off the main thread deliberately returns `Data`, not an `NSImage`. `NSImage`
/// is not `Sendable` — it is an AppKit object with its own internal caching — so sending
/// one between tasks is a data race that the compiler is right to reject. Re-encoding a
/// small thumbnail costs very little next to reading and decoding the full picture.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 400
    private var inFlight: Set<String> = []

    func cached(_ id: String) -> NSImage? { images[id] }

    func load(
        id: String,
        store: PictureStore,
        stored: PictureStore.Stored,
        side: CGFloat = 320
    ) async -> NSImage? {
        if let existing = images[id] { return existing }
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let url = store.url(for: stored)
        let pixels = Int(side * 2)   // enough for a Retina cell

        // Both the file read and the decode happen here, off the main thread.
        let jpeg: Data? = await Task.detached(priority: .userInitiated) {
            ThumbnailCache.makeThumbnailData(from: url, maxPixel: pixels)
        }.value

        guard let jpeg, let image = NSImage(data: jpeg) else { return nil }
        remember(id: id, image: image)
        return image
    }

    private func remember(id: String, image: NSImage) {
        images[id] = image
        order.append(id)
        while order.count > limit {
            let oldest = order.removeFirst()
            if oldest != id { images.removeValue(forKey: oldest) }
        }
    }

    /// Uses ImageIO's thumbnail path, which decodes only as much of the file as the
    /// requested size needs — far cheaper than decoding a 48-megapixel original in
    /// full and then shrinking it.
    nonisolated static func makeThumbnailData(from url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Full-size bytes for the detail view, read off the main thread. Returns `Data`,
    /// for the same reason as above.
    nonisolated static func fullSizeData(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
