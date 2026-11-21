import Foundation
import Photos
import PhotoDiffCore

/// Reads the live Photos library through PhotoKit and turns it into lookup keys.
///
/// PhotoKit rather than the folder, for two reasons: the live library is protected by
/// macOS privacy and a plain file read of it is refused, and it is iCloud-optimized, so
/// PhotoKit is the only thing that knows about photos whose originals were never
/// downloaded.
///
/// Note on the permission name: PhotoKit's only read access level is called
/// `.readWrite`. The app never calls a change API — `PHPhotoLibrary.performChanges` and
/// every `PHAssetChangeRequest` are banned by a test that scans the source tree.
@MainActor
final class CurrentLibraryIndex {

    enum Access: Equatable {
        case granted
        /// macOS granted access to a hand-picked subset of photos, not the whole
        /// library. Every photo outside that subset would look "missing", so a
        /// comparison run in this state is worse than useless — it is misleading.
        case limitedToSomePhotos
        case denied
        case notAsked
    }

    struct Built {
        var index: MatchIndex
        var assetCount: Int
        var photoCount: Int
        var videoCount: Int
        var withoutDate: Int
        var buildTime: TimeInterval
    }

    /// Kept so the deferred filename lookup can go back to the right assets without
    /// re-fetching the whole library.
    private var assets: [PHAsset] = []
    private var secondsToAssets: [Int64: [PHAsset]] = [:]

    // MARK: Permission

    private static func translate(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized: return .granted
        case .limited: return .limitedToSomePhotos
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    static func currentAccess() -> Access {
        translate(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func requestAccess() async -> Access {
        translate(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    // MARK: Phase one — the fast index

    /// Builds the time-and-size keys, which is all tier 2 needs. Does not touch
    /// `PHAssetResource`, the slow per-asset call.
    func buildFastIndex(progress: ((Int, Int) -> Void)? = nil) -> Built {
        let started = Date()

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.wantsIncrementalChangeDetails = false

        let fetched = PHAsset.fetchAssets(with: options)
        var index = MatchIndex()
        var all: [PHAsset] = []
        var buckets: [Int64: [PHAsset]] = [:]
        var withoutDate = 0
        var photos = 0
        var videos = 0
        let total = fetched.count

        fetched.enumerateObjects { asset, offset, _ in
            all.append(asset)

            let isVideo = asset.mediaType == .video
            if isVideo { videos += 1 } else { photos += 1 }
            let duration = isVideo ? asset.duration : nil
            index.insert(
                captureDate: asset.creationDate,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                duration: duration,
                filename: nil,       // deferred, see augment(...)
                byteSize: nil,
                fingerprint: nil     // PhotoKit does not expose Apple's fingerprints
            )

            if let date = asset.creationDate {
                let sec = Int64(date.timeIntervalSinceReferenceDate.rounded())
                buckets[sec, default: []].append(asset)
            } else {
                withoutDate += 1
            }

            if offset % 500 == 0 { progress?(offset, total) }
        }

        self.assets = all
        self.secondsToAssets = buckets

        return Built(
            index: index,
            assetCount: all.count,
            photoCount: photos,
            videoCount: videos,
            withoutDate: withoutDate,
            buildTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: Phase two — only the filenames we actually need

    /// Adds filename keys for tiers 3 and 4, but only for current-library assets that
    /// could plausibly match something still unaccounted for.
    ///
    /// This is the one expensive PhotoKit call: `assetResources(for:)` is per asset, so
    /// running it over twelve thousand photos is slow and almost entirely wasted. Tier
    /// 2 has already settled the great majority, so this narrows to the few hundred
    /// assets near an unmatched capture time, plus every undated asset.
    func augment(
        _ index: inout MatchIndex,
        nearSeconds seconds: Set<Int64>,
        includeUndated: Bool
    ) -> Int {
        var candidates: [PHAsset] = []
        var seen = Set<String>()

        for second in seconds {
            for offset in [Int64(0), -1, 1] {
                for asset in secondsToAssets[second + offset] ?? [] {
                    if seen.insert(asset.localIdentifier).inserted {
                        candidates.append(asset)
                    }
                }
            }
        }
        if includeUndated {
            for asset in assets where asset.creationDate == nil {
                if seen.insert(asset.localIdentifier).inserted { candidates.append(asset) }
            }
        }

        for asset in candidates {
            let resources = PHAssetResource.assetResources(for: asset)
            // The original is what the old libraries recorded a filename for.
            let primary = resources.first {
                $0.type == .photo || $0.type == .video
            } ?? resources.first
            guard let primary else { continue }

            index.insert(
                captureDate: asset.creationDate,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                duration: asset.mediaType == .video ? asset.duration : nil,
                filename: primary.originalFilename,
                byteSize: Self.byteSize(of: primary),
                fingerprint: nil
            )
        }
        return candidates.count
    }

    /// `PHAssetResource` has no public size, so this reads the value Photos keeps
    /// internally and simply gives up if it is not there. Tier 4 then does not fire,
    /// which at worst means a photo is reported as missing when it is present — visible
    /// and correctable, unlike the reverse.
    private static func byteSize(of resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    // MARK: Thumbnails for the current library (used when showing a match)

    func thumbnail(for localIdentifier: String, size: CGSize) async -> Data? {
        guard let asset = assets.first(where: { $0.localIdentifier == localIdentifier })
        else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
