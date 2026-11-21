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

    public init(bundleURL: URL) throws {
        self.library = try ReadOnlyLibrary(bundleURL: bundleURL)
    }

    public var displayName: String { library.displayName }
    public var identity: String { library.identity }

    /// Pulls the best available picture for an asset out of the library.
    ///
    /// Most of these libraries ran with "Optimize Mac Storage", so the full original is
    /// usually absent and a cached derivative is the only copy left. Order is:
    /// the original if it was downloaded, else the largest derivative, else nothing.
    ///
    /// The packed `.ithmb` cache is a fourth possible source and is deliberately not
    /// read yet: its layout has to be confirmed against a real library before it can be
    /// decoded without producing garbled images. `thumbnailCacheIsAvailable` reports
    /// whether that fallback would have anything to offer.
    public func extractPicture(for asset: AssetRecord, maxBytes: Int = 64 << 20) -> ExtractedPicture? {
        if let original = readOriginal(asset, limit: maxBytes) { return original }
        if let derivative = readLargestDerivative(asset, limit: maxBytes) { return derivative }
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
        !contentsOfThumbsDirectory().isEmpty
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
