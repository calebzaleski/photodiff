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
    /// Directory listings, read once each. Photos shards files by the first character
    /// of the UUID, so there are only a handful of directories but many thousands of
    /// lookups — listing per asset would dominate the run.
    private var listings: [String: [String]] = [:]
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
        if let scoped = readScopedOriginal(asset, limit: maxBytes) { return scoped }
        if let derivative = readLargestDerivative(asset, limit: maxBytes) { return derivative }
        if let packedThumb = readPackedThumbnail(asset) { return packedThumb }
        return nil
    }

    /// Full-size files that live under `scopes/` rather than `originals/`.
    ///
    /// Photos files arriving through a shared album or through Messages are stored in
    /// a separate scope, and they are full-size originals — not previews. In one real
    /// library this found 1,462 photographs that `originals/` did not have, roughly
    /// tripling how many could be recovered at full quality. Easy to miss, because
    /// `scopes/` mostly holds other people's shared photos that are not assets in this
    /// library at all; only those whose UUID matches an asset count.
    private func readScopedOriginal(_ asset: AssetRecord, limit: Int) -> ExtractedPicture? {
        guard let shard = asset.uuid.first else { return nil }
        for scope in listing("scopes") {
            guard let path = largestFile(
                matching: asset.uuid, in: "scopes/\(scope)/originals/\(shard)")
            else { continue }
            guard let data = try? library.readAll(path, limit: limit), !data.isEmpty
            else { continue }
            return ExtractedPicture(
                data: data, kind: .original,
                fileExtension: (path as NSString).pathExtension.lowercased()
            )
        }
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
        if readScopedOriginalPath(asset) != nil { return .original }
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

    /// Cached listing of one directory inside the library.
    /// Does a file belong to this asset?
    ///
    /// Usually the name is just `<uuid>.<ext>`, but an edited or multi-part asset gets
    /// a suffixed sibling — `<uuid>_3.mov` and the like. Those are real full-size
    /// files, and in one library 450 of 2,437 originals were named that way, so
    /// insisting on an exact match quietly discards them.
    private static func belongs(_ fileName: String, to uuid: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        if stem.caseInsensitiveCompare(uuid) == .orderedSame { return true }
        return stem.count > uuid.count
            && stem.lowercased().hasPrefix(uuid.lowercased() + "_")
    }

    /// The biggest file in `dir` belonging to this asset, if any.
    private func largestFile(matching uuid: String, in dir: String) -> String? {
        let hits = listing(dir).filter { Self.belongs($0, to: uuid) }
        guard !hits.isEmpty else { return nil }
        return hits
            .map { (path: "\(dir)/\($0)", size: library.size(of: "\(dir)/\($0)") ?? 0) }
            .max { $0.size < $1.size }?
            .path
    }

    private func listing(_ dir: String) -> [String] {
        if let known = listings[dir] { return known }
        let names = library.contents(of: dir)
        listings[dir] = names
        return names
    }

    /// Finds the asset's original by **name**, not by the extension the database
    /// records.
    ///
    /// Matching on the recorded extension looks reasonable and quietly loses more than
    /// half the files: the database may say `.HEIC` where the file on disk is `.heic`
    /// or `.jpeg`, may record no filename at all, and edited photos sit beside their
    /// originals under related names. Listing the directory once and matching the UUID
    /// stem found 2,895 → 6,000-odd recoverable photos in the libraries tested.
    private func originalPath(_ asset: AssetRecord) -> String? {
        guard let shard = asset.uuid.first else { return nil }
        return largestFile(matching: asset.uuid, in: "originals/\(shard)")
    }

    /// An open, streaming handle on the asset's full-size file, if one exists in this
    /// library. Returns nil when only a preview or thumbnail is available.
    ///
    /// Streaming rather than returning `Data`, because these are the real originals —
    /// one video in the libraries examined was 1.9GB.
    public func fullSizeFile(
        for asset: AssetRecord
    ) -> (source: ByteSource, bytes: Int64, fileExtension: String)? {
        guard let path = originalPath(asset) ?? readScopedOriginalPath(asset),
              let size = library.size(of: path), size > 0,
              let handle = try? library.open(path) else { return nil }
        return (handle, size, (path as NSString).pathExtension.lowercased())
    }

    private func readScopedOriginalPath(_ asset: AssetRecord) -> String? {
        guard let shard = asset.uuid.first else { return nil }
        for scope in listing("scopes") {
            if let path = largestFile(
                matching: asset.uuid, in: "scopes/\(scope)/originals/\(shard)") {
                return path
            }
        }
        return nil
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
        return listing(dir)
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
