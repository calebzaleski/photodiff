import Foundation
import ImageIO

/// Where the app keeps the pictures it recovered, so a library copy can be deleted and
/// the grid — and the export — still work.
///
/// Like `TempStore`, this does the writing and cannot name a library: it accepts bytes
/// that something else already read.
/// Safe to use from several tasks at once: it holds only a root URL, and every write
/// goes to a path derived from a distinct asset id, so two tasks never touch one file.
public final class PictureStore: @unchecked Sendable {

    public enum Failure: Error, LocalizedError {
        case cannotPrepare(String)
        public var errorDescription: String? {
            switch self {
            case .cannotPrepare(let p): return "Could not prepare the picture store at \(p)"
            }
        }
    }

    public struct Stored: Sendable, Codable {
        public let assetID: String
        public let kind: String
        public let fileName: String
        public let bytes: Int64
        /// Actual pixel size of what was recovered — not what the photo used to be.
        /// Shown in the grid, because "thumbnail" alone does not convey that a 4032px
        /// photo came back as 120px.
        public var pixelWidth: Int = 0
        public var pixelHeight: Int = 0

        public var isFullQuality: Bool { kind == "original" }

        public var sizeLabel: String {
            pixelWidth > 0 ? "\(pixelWidth)×\(pixelHeight)" : "unknown size"
        }
    }

    public let root: URL
    private let fm = FileManager.default

    /// Defaults to Application Support, deliberately outside any repo or library, so
    /// the cache can never be committed or mistaken for library data.
    public init(root: URL? = nil) throws {
        let base = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoDiff/Pictures", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotPrepare(base.path)
        }
        self.root = base
    }

    /// Files are sharded two characters deep so one folder never holds 13,000 entries.
    private func location(assetID: String, kind: String, extension ext: String) -> URL {
        let safe = assetID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let shard = String(safe.prefix(2))
        return root.appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(safe).\(kind).\(ext)")
    }

    @discardableResult
    public func save(
        _ data: Data, assetID: String, kind: String, extension ext: String
    ) throws -> Stored {
        let target = location(assetID: assetID, kind: kind, extension: ext)
        try fm.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        let (w, h) = Self.pixelSize(of: data)
        return Stored(
            assetID: assetID, kind: kind,
            fileName: target.lastPathComponent, bytes: Int64(data.count),
            pixelWidth: w, pixelHeight: h
        )
    }

    /// Reads just the image header, not the pixels.
    static func pixelSize(of data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any] else { return (0, 0) }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return (w, h)
    }

    public func url(for stored: Stored) -> URL {
        let shard = String(stored.fileName.prefix(2))
        return root.appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(stored.fileName)
    }

    public func data(for stored: Stored) -> Data? {
        try? Data(contentsOf: url(for: stored))
    }

    /// Total bytes held, shown in the sidebar so the cache never grows unnoticed.
    public func totalBytes() -> Int64 {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public func clear() throws {
        try fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Copies a stored picture out to wherever the user asked, with a readable name
    /// that says which version it is.
    @discardableResult
    public func export(
        _ stored: Stored, to folder: URL, named name: String
    ) throws -> URL {
        let source = url(for: stored)
        let ext = (stored.fileName as NSString).pathExtension
        var target = folder.appendingPathComponent("\(name).\(stored.kind).\(ext)")

        // Never overwrite something already in the destination folder.
        var attempt = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(name) (\(attempt)).\(stored.kind).\(ext)")
            attempt += 1
        }
        try fm.copyItem(at: source, to: target)
        return target
    }
}
