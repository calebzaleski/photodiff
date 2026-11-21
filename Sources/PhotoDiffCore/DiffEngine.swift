import Foundation

/// How confident we are that two assets are the same photo.
public enum MatchTier: Int, Sendable, Comparable, CustomStringConvertible {
    /// Apple's own content fingerprint. Certain.
    case fingerprint = 1
    /// Same capture second and same pixel dimensions. The workhorse.
    case timeAndSize = 2
    /// Same capture second and same import filename. Catches re-encodes.
    case timeAndName = 3
    /// Same import filename and byte size. Catches assets with no usable date.
    case nameAndSize = 4

    public static func < (a: MatchTier, b: MatchTier) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .fingerprint: return "exact"
        case .timeAndSize: return "date + size"
        case .timeAndName: return "date + name"
        case .nameAndSize: return "name + bytes"
        }
    }

    /// Shown in the grid so a fuzzy call is visible rather than implied.
    public var isCertain: Bool { self == .fingerprint }
}

/// The lookup keys for one library, built once and queried many times. Every tier is a
/// dictionary, so comparing 13,000 old assets against 12,000 current ones is 13,000
/// lookups instead of 156 million comparisons.
public struct MatchIndex: Sendable {

    /// "second|WIDTHxHEIGHT" -> durations of the assets under that key
    private var timeAndSize: [String: [Double?]] = [:]
    /// "second|filename" -> durations
    private var timeAndName: [String: [Double?]] = [:]
    /// "filename|bytes"
    private var nameAndSize: Set<String> = []
    private var fingerprints: Set<String> = []

    public private(set) var count = 0

    public init() {}

    // MARK: Keys

    /// Capture time rounded to the second. Libraries store sub-second precision
    /// inconsistently, and the same photo re-imported can drift by a hair.
    static func second(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return Int64((date.timeIntervalSinceReferenceDate).rounded())
    }

    /// Filenames differ in case and extension between a HEIC original and its JPEG
    /// re-encode, so compare the stem, lowercased.
    static func nameStem(_ filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        return stem.isEmpty ? nil : stem
    }

    private static func sizeKey(_ second: Int64, _ w: Int, _ h: Int) -> String {
        let (a, b) = w >= h ? (w, h) : (h, w)
        return "\(second)|\(a)x\(b)"
    }

    // MARK: Building

    public mutating func insert(
        captureDate: Date?,
        width: Int,
        height: Int,
        duration: Double?,
        filename: String?,
        byteSize: Int64?,
        fingerprint: String?
    ) {
        count += 1
        if let fp = fingerprint, !fp.isEmpty { fingerprints.insert(fp) }

        let sec = Self.second(captureDate)
        let stem = Self.nameStem(filename)

        if let sec, width > 0, height > 0 {
            timeAndSize[Self.sizeKey(sec, width, height), default: []].append(duration)
        }
        if let sec, let stem {
            timeAndName["\(sec)|\(stem)", default: []].append(duration)
        }
        if let stem, let bytes = byteSize, bytes > 0 {
            nameAndSize.insert("\(stem)|\(bytes)")
        }
    }

    public mutating func insert(_ asset: AssetRecord) {
        insert(
            captureDate: asset.captureDate,
            width: asset.width,
            height: asset.height,
            duration: asset.duration,
            filename: asset.originalFilename,
            byteSize: asset.originalFileSize,
            fingerprint: asset.fingerprint
        )
    }

    // MARK: Querying

    /// A video only matches if its length agrees too — otherwise two clips shot in the
    /// same second at the same resolution would collapse into one.
    private static func durationAgrees(_ wanted: Double?, _ candidates: [Double?]) -> Bool {
        // A photo matches only candidates that are also photos.
        guard let wanted else { return candidates.contains { $0 == nil } }
        return candidates.contains { c in
            guard let c else { return false }
            return abs(c - wanted) <= 0.5
        }
    }

    /// Returns the strongest tier that says this asset is already here, or nil.
    /// Tiers are tried in order and the first hit wins.
    public func tier(matching asset: AssetRecord) -> MatchTier? {
        if let fp = asset.fingerprint, !fp.isEmpty, fingerprints.contains(fp) {
            return .fingerprint
        }

        let sec = MatchIndex.second(asset.captureDate)
        let stem = MatchIndex.nameStem(asset.originalFilename)

        // Tier 2, allowing a one-second drift either way.
        if let sec, asset.width > 0, asset.height > 0 {
            for offset in [Int64(0), -1, 1] {
                let key = MatchIndex.sizeKey(sec + offset, asset.width, asset.height)
                if let candidates = timeAndSize[key],
                   MatchIndex.durationAgrees(asset.duration, candidates) {
                    return .timeAndSize
                }
            }
        }

        // Tier 3.
        if let sec, let stem {
            for offset in [Int64(0), -1, 1] {
                if let candidates = timeAndName["\(sec + offset)|\(stem)"],
                   MatchIndex.durationAgrees(asset.duration, candidates) {
                    return .timeAndName
                }
            }
        }

        // Tier 4.
        if let stem, let bytes = asset.originalFileSize, bytes > 0,
           nameAndSize.contains("\(stem)|\(bytes)") {
            return .nameAndSize
        }

        return nil
    }
}

/// One photo that exists in the old libraries but not in the current one.
public struct MissingPhoto: Sendable, Identifiable {
    /// The asset chosen to represent this photo — the one from the library with the
    /// best available picture.
    public var representative: AssetRecord
    /// Every old-library copy of this same photo, representative included.
    public var copies: [AssetRecord]

    public var id: String { representative.id }
    public var otherLibraryCount: Int { max(0, Set(copies.map(\.libraryIdentity)).count - 1) }
    public var libraryNames: [String] {
        Array(Set(copies.map(\.libraryName))).sorted()
    }
}

public struct DiffSummary: Sendable {
    public var oldAssetsConsidered = 0
    public var presentCount = 0
    public var missingCount = 0
    public var duplicateCopiesFolded = 0
    public var sharedSkipped = 0
    public var byTier: [MatchTier: Int] = [:]
}

public struct DiffResult: Sendable {
    public let missing: [MissingPhoto]
    public let summary: DiffSummary
}

/// Decides which old assets are absent from the current library, and folds copies of
/// the same photo across old libraries into one entry.
public enum DiffEngine {

    /// - Parameters:
    ///   - oldAssets: every asset from every open old library.
    ///   - current: lookup index for the live library.
    ///   - includeShared: shared-album assets were never really the user's own photos,
    ///     so they are left out of the main result by default.
    public static func diff(
        oldAssets: [AssetRecord],
        against current: MatchIndex,
        includeShared: Bool = false
    ) -> DiffResult {
        var summary = DiffSummary()

        // Deterministic order, so the same photo always picks the same representative
        // and the result does not shuffle between runs.
        let ordered = oldAssets.sorted {
            ($0.libraryName, $0.uuid) < ($1.libraryName, $1.uuid)
        }

        // Grows as we go: an asset already recorded as missing makes later copies of
        // the same photo fold into it instead of appearing again.
        var seenMissing = MatchIndex()
        var groups: [MissingPhoto] = []
        // Maps a key we have already grouped to its index in `groups`.
        var groupOfFingerprint: [String: Int] = [:]
        var groupOfTimeSize: [String: Int] = [:]

        for asset in ordered {
            if asset.isShared && !includeShared {
                summary.sharedSkipped += 1
                continue
            }
            summary.oldAssetsConsidered += 1

            if let tier = current.tier(matching: asset) {
                summary.presentCount += 1
                summary.byTier[tier, default: 0] += 1
                continue
            }

            // Missing. Is it a copy of something already missing?
            if seenMissing.tier(matching: asset) != nil,
               let existing = findGroup(
                   for: asset,
                   fingerprints: groupOfFingerprint,
                   timeSizes: groupOfTimeSize
               ) {
                groups[existing].copies.append(asset)
                groups[existing].representative = preferred(
                    groups[existing].representative, asset
                )
                summary.duplicateCopiesFolded += 1
                continue
            }

            let index = groups.count
            groups.append(MissingPhoto(representative: asset, copies: [asset]))
            seenMissing.insert(asset)
            if let fp = asset.fingerprint, !fp.isEmpty { groupOfFingerprint[fp] = index }
            if let key = timeSizeKey(asset) { groupOfTimeSize[key] = index }
        }

        summary.missingCount = groups.count
        return DiffResult(missing: groups, summary: summary)
    }

    private static func timeSizeKey(_ a: AssetRecord) -> String? {
        guard let sec = MatchIndex.second(a.captureDate), a.width > 0, a.height > 0
        else { return nil }
        let (w, h) = a.normalisedDimensions
        return "\(sec)|\(w)x\(h)"
    }

    private static func findGroup(
        for asset: AssetRecord,
        fingerprints: [String: Int],
        timeSizes: [String: Int]
    ) -> Int? {
        if let fp = asset.fingerprint, let i = fingerprints[fp] { return i }
        guard let sec = MatchIndex.second(asset.captureDate),
              asset.width > 0, asset.height > 0 else { return nil }
        let (w, h) = asset.normalisedDimensions
        for offset in [Int64(0), -1, 1] {
            if let i = timeSizes["\(sec + offset)|\(w)x\(h)"] { return i }
        }
        return nil
    }

    /// Prefer the copy most likely to still have real pixels behind it: a downloaded
    /// original beats a derivative, and a bigger recorded file beats a smaller one.
    private static func preferred(_ a: AssetRecord, _ b: AssetRecord) -> AssetRecord {
        let aHasFile = a.placement.filename != nil
        let bHasFile = b.placement.filename != nil
        if aHasFile != bHasFile { return aHasFile ? a : b }
        return (b.originalFileSize ?? 0) > (a.originalFileSize ?? 0) ? b : a
    }
}
