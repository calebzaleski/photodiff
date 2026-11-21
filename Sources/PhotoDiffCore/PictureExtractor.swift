import Foundation

/// Which version of a photo we managed to recover. Shown in the grid and written into
/// the export filename, so it is always clear whether a file is the real original or
/// only the cached preview that survived.
public enum PictureKind: String, Sendable, CustomStringConvertible {
    case original
    case derivative
    case thumbnail

    public var description: String { rawValue }

    /// Best first. Used when choosing between copies of the same photo.
    public var rank: Int {
        switch self {
        case .original: return 3
        case .derivative: return 2
        case .thumbnail: return 1
        }
    }
}

public struct ExtractedPicture: Sendable {
    public let data: Data
    public let kind: PictureKind
    /// The extension the bytes actually are, e.g. "heic" or "jpeg".
    public let fileExtension: String
}

/// Pulls the best surviving picture for an asset out of a library.
///
/// Separate from `LibraryReader` because it needs no database: once the assets are
/// read, getting their pictures is pure file reading. That lets every library be
/// scanned at the same time without copying a 140MB database twice.
///
/// Holds a `ReadOnlyLibrary`, so it can read a library and — by construction — cannot
/// write to one. The writing belongs to `PictureStore`.
public final class PictureExtractor {

    private let library: ReadOnlyLibrary
    private let packed: PackedThumbnails
    /// Shared across every extraction: building the Metal pipeline costs more than
    /// decoding a thumbnail does. Nil when the GPU cannot do BC7, in which case this
    /// source is simply skipped.
    private let decoder: ThumbnailDecoder?

    public init(bundleURL: URL) throws {
        let library = try ReadOnlyLibrary(bundleURL: bundleURL)
        self.library = library

        let thumbDir = "resources/derivatives/thumbs"
        let files: [(name: String, bytes: Int64)] = library.contents(of: thumbDir)
            .filter { $0.hasSuffix(".ithmb") }
            .compactMap { name in
                guard let bytes = library.size(of: "\(thumbDir)/\(name)") else { return nil }
                return (name, bytes)
            }
        self.packed = PackedThumbnails(files: files)
        self.decoder = packed.files.isEmpty ? nil : try? ThumbnailDecoder()
    }

    public var displayName: String { library.displayName }
    public var identity: String { library.identity }

    /// Pulls the best available picture for an asset out of the library.
    ///
    /// Most of these libraries ran with "Optimize Mac Storage", so the full original is
    /// usually absent and a cached derivative is the only copy left. Order is:
    /// the original if it was downloaded, else the largest derivative, else nothing.
    ///
    /// The third source is the packed `.ithmb` cache. It is small — at most 64 pixels
    /// on the long side — but it is the only thing that survives for the great majority
    /// of photos in an iCloud-optimized library, so it is the difference between a grid
    /// of pictures and a grid of filenames.
    public func extractPicture(for asset: AssetRecord, maxBytes: Int = 64 << 20) -> ExtractedPicture? {
        if let original = readOriginal(asset, limit: maxBytes) { return original }
        if let derivative = readLargestDerivative(asset, limit: maxBytes) { return derivative }
        if let packedThumb = readPackedThumbnail(asset) { return packedThumb }
        return nil
    }

    /// Reads the asset's record out of the packed cache and decodes it.
    ///
    /// Each record carries the UUID of the photo it belongs to, and that is checked
    /// against the asset we were asked about. If the index were ever wrong, this
    /// returns nothing rather than quietly showing a different person's photo.
    private func readPackedThumbnail(_ asset: AssetRecord) -> ExtractedPicture? {
        guard let decoder,
              let index = asset.placement.thumbnailIndex, index >= 0 else { return nil }

        let dir = "resources/derivatives/thumbs"
        // packed.files is ordered largest-thumbnail first.
        for file in packed.files where index < file.recordCount {
            guard let bytes = try? library.read(
                "\(dir)/\(file.fileName)",
                at: file.offset(forIndex: index),
                length: file.stride
            ) else { continue }

            guard let record = PackedThumbnails.parse(
                      record: bytes, in: file, expecting: asset.uuid),
                  let jpeg = decoder.jpeg(from: record) else { continue }
            return ExtractedPicture(data: jpeg, kind: .thumbnail, fileExtension: "jpg")
        }
        return nil
    }

    /// Reports what each source could supply, without reading the bytes. Used to
    /// measure coverage on a real library before deciding whether the packed thumbnail
    /// cache needs to be decoded at all.
    public func pictureAvailability(for asset: AssetRecord) -> PictureKind? {
        if originalPath(asset) != nil { return .original }
        if !derivativeNames(asset).isEmpty { return .derivative }
        if asset.placement.thumbnailIndex != nil && thumbnailCacheIsAvailable { return .thumbnail }
        return nil
    }

    /// True when the library has a packed thumbnail cache at all.
    public var thumbnailCacheIsAvailable: Bool {
        !packed.files.isEmpty
    }

    /// Sizes of the packed thumbnail files, for the measurement that has to happen
    /// before that fallback can be built.
    public var thumbnailCacheReport: [(name: String, bytes: Int64)] {
        contentsOfThumbsDirectory().compactMap { name in
            guard let bytes = library.size(of: "resources/derivatives/thumbs/\(name)")
            else { return nil }
            return (name, bytes)
        }
    }

    // MARK: Sources

    private func originalPath(_ asset: AssetRecord) -> String? {
        guard let filename = asset.placement.filename,
              let shard = asset.uuid.first else { return nil }
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return nil }

        // Photos files sit under originals/<first character of the UUID>/.
        let candidates = [
            "originals/\(shard)/\(asset.uuid).\(ext)",
            "originals/\(shard)/\(asset.uuid).\(ext.lowercased())",
            "originals/\(shard)/\(asset.uuid).\(ext.uppercased())",
        ]
        return candidates.first { library.exists($0) }
    }

    private func readOriginal(_ asset: AssetRecord, limit: Int) -> ExtractedPicture? {
        guard let path = originalPath(asset),
              let data = try? library.readAll(path, limit: limit),
              !data.isEmpty else { return nil }
        return ExtractedPicture(
            data: data, kind: .original,
            fileExtension: (path as NSString).pathExtension.lowercased()
        )
    }

    /// Derivative JPEGs are named `<UUID>_1_105_c.jpeg` and similar, sharded by the
    /// UUID's first character. Several sizes can exist; the biggest is worth keeping.
    private func derivativeNames(_ asset: AssetRecord) -> [(dir: String, name: String)] {
        guard let shard = asset.uuid.first else { return [] }
        let dir = "resources/derivatives/\(shard)"
        return library.contents(of: dir)
            .filter { $0.hasPrefix(asset.uuid) }
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return ext == "jpeg" || ext == "jpg" || ext == "heic"
            }
            .map { (dir, $0) }
    }

    private func readLargestDerivative(_ asset: AssetRecord, limit: Int) -> ExtractedPicture? {
        let best = derivativeNames(asset)
            .map { (path: "\($0.dir)/\($0.name)", size: library.size(of: "\($0.dir)/\($0.name)") ?? 0) }
            .max { $0.size < $1.size }

        guard let best, best.size > 0,
              let data = try? library.readAll(best.path, limit: limit),
              !data.isEmpty else { return nil }
        return ExtractedPicture(
            data: data, kind: .derivative,
            fileExtension: (best.path as NSString).pathExtension.lowercased()
        )
    }

    private func contentsOfThumbsDirectory() -> [String] {
        library.contents(of: "resources/derivatives/thumbs")
            .filter { $0.hasSuffix(".ithmb") }
    }
}
