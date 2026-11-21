import AppKit
import PhotoDiffCore

/// Decodes grid thumbnails on demand and keeps a bounded number in memory, so a result
/// of several thousand photos scrolls immediately instead of decoding everything first.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 400
    private var inFlight: Set<String> = []

    func cached(_ id: String) -> NSImage? { images[id] }

    /// Decodes off the main thread, at roughly the size the grid draws, and caches the
    /// small result rather than the full-size picture.
    ///
    /// The file read happens inside the detached task too. Reading a multi-megabyte
    /// original on the main thread would stutter the grid while scrolling.
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

        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let bytes = store.data(for: stored),
                  let source = NSImage(data: bytes) else { return nil }
            return ThumbnailCache.downscale(source, to: side)
        }.value

        if let image { remember(id: id, image: image) }
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

    private nonisolated static func downscale(_ image: NSImage, to side: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, side / max(size.width, size.height))
        guard scale < 1 else { return image }

        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let output = NSImage(size: target)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        output.unlockFocus()
        return output
    }
}
