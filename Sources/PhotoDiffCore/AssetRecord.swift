import Foundation

/// One photo or video, flattened out of whichever schema it came from. Everything
/// downstream — the matcher, the grid, the exporter — sees only this, and never learns
/// which Photos version wrote the database.
public struct AssetRecord: Sendable, Identifiable, Hashable {

    public enum Kind: Int, Sendable { case photo = 0, video = 1 }

    /// Where the asset sits in the library's own structure, so we can find its files.
    public struct Placement: Sendable, Hashable {
        /// `ZASSET.ZDIRECTORY`, e.g. "2019/04/03". Nil in some old libraries.
        public let directory: String?
        /// `ZASSET.ZFILENAME`, the on-disk name inside `originals/`.
        public let filename: String?
        /// Index into the packed `.ithmb` thumbnail cache.
        public let thumbnailIndex: Int?
    }

    public let uuid: String
    public let libraryIdentity: String
    public let libraryName: String

    public let captureDate: Date?
    /// Seconds east of UTC at capture time, when the library recorded it.
    public let timeZoneOffset: Int?

    public let width: Int
    public let height: Int
    /// Seconds, for videos.
    public let duration: Double?

    /// The name the file had when it was imported, e.g. "IMG_4821.HEIC".
    public let originalFilename: String?
    public let originalFileSize: Int64?

    public let kind: Kind
    public let isHidden: Bool
    /// True for assets that arrived through a shared album rather than the user's own
    /// library. PhotoKit's default fetch leaves these out, so counting them as
    /// "missing" would flood the result with photos that were never really theirs.
    public let isShared: Bool

    /// Apple's own content fingerprint, when the library recorded one. Survives even
    /// when the original was never downloaded, which is why it beats hashing bytes.
    public let fingerprint: String?

    public let placement: Placement

    public var id: String { "\(libraryIdentity):\(uuid)" }

    /// Dimensions with orientation collapsed, so a photo stored rotated still matches
    /// the same photo stored upright.
    public var normalisedDimensions: (Int, Int) {
        width >= height ? (width, height) : (height, width)
    }

    public init(
        uuid: String,
        libraryIdentity: String,
        libraryName: String,
        captureDate: Date?,
        timeZoneOffset: Int?,
        width: Int,
        height: Int,
        duration: Double?,
        originalFilename: String?,
        originalFileSize: Int64?,
        kind: Kind,
        isHidden: Bool,
        isShared: Bool,
        fingerprint: String?,
        placement: Placement
    ) {
        self.uuid = uuid
        self.libraryIdentity = libraryIdentity
        self.libraryName = libraryName
        self.captureDate = captureDate
        self.timeZoneOffset = timeZoneOffset
        self.width = width
        self.height = height
        self.duration = duration
        self.originalFilename = originalFilename
        self.originalFileSize = originalFileSize
        self.kind = kind
        self.isHidden = isHidden
        self.isShared = isShared
        self.fingerprint = fingerprint
        self.placement = placement
    }
}

/// Apple stores timestamps as seconds since 2001-01-01, not 1970.
public extension Date {
    static func fromCoreDataTimestamp(_ seconds: Double?) -> Date? {
        guard let seconds, seconds != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
