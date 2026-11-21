import Foundation

/// Reads the container format of Photos' packed thumbnail cache — the `.ithmb` files
/// under `resources/derivatives/thumbs/`.
///
/// ## Why this matters
///
/// A library that ran with iCloud "Optimize Mac Storage" keeps almost nothing on disk.
/// In one real library of 13,087 photos there were 530 full originals and 1,064 cached
/// previews; the remaining ~11,500 exist locally *only* as an entry in here. When those
/// photos are also gone from iCloud, this file is the last copy that exists anywhere.
///
/// ## The container, confirmed
///
/// Worked out by reading a real library and checked against its database: the UUIDs
/// recorded here match the assets whose `ZTHUMBNAILINDEX` is 0...6, at exactly the
/// offsets this layout predicts.
///
/// ```text
///   offset 0       4096-byte header (purpose unknown, not needed)
///   offset 4096    record 0
///   offset 4096 + index * 4124    record for ZTHUMBNAILINDEX = index
///
///   each record, 4124 bytes:
///     0..15     asset UUID, raw 16 bytes      <- lets a record be verified, not trusted
///     16..19    width  in pixels, uint32 LE   <- e.g. 30, 48, 64
///     20..23    height in pixels, uint32 LE   <- e.g. 64, 48, 19
///     24..27    zero in every record observed
///     28..4123  4096 bytes of pixel data for a 64x64 grid, cropped to width x height
/// ```
///
/// A record whose UUID is all zero is an empty slot.
///
/// ## What is still unknown
///
/// The pixel encoding. 4096 bytes for a 64×64 grid is exactly one byte per pixel, and
/// the data has a clear 16-byte block structure — both of which point at a
/// block-compressed GPU texture. But decoding it as ASTC (every block footprint),
/// BC3, BC7 and ETC2/EAC, uploaded both with `replace` and with a buffer blit, in
/// linear and in Morton order, all produce the same wrong result: plausible detail in
/// the first few blocks and a flat field after.
///
/// So `pixelData(for:)` hands back the bytes and makes no claim about them. Nothing in
/// the app turns them into an image yet, and photos with no other source still show a
/// metadata tile. A missing picture is a fair answer; a garbled one would not be.
public struct PackedThumbnails: Sendable {

    public static let headerLength = 4096
    public static let recordStride = 4124
    public static let uuidLength = 16
    public static let pixelDataOffset = 28
    public static let pixelDataLength = 4096
    /// The pixel data always covers a 64×64 grid; `width`/`height` crop it.
    public static let gridSide = 64

    public struct Record: Sendable {
        /// Uppercased, hyphenated, as the database writes it.
        public let uuid: String
        public let width: Int
        public let height: Int
        /// The undecoded pixel bytes. See the note above before trying to draw these.
        public let pixelData: Data
    }

    public struct File: Sendable {
        /// Photos' own format id, which is also the file's name, e.g. 4133.
        public let formatID: Int
        public let fileName: String
        public let recordCount: Int
    }

    public let files: [File]

    public init(files: [(name: String, bytes: Int64)]) {
        self.files = files.compactMap { file in
            guard file.bytes > Int64(Self.headerLength) else { return nil }
            let usable = file.bytes - Int64(Self.headerLength)
            return File(
                formatID: Int((file.name as NSString).deletingPathExtension) ?? 0,
                fileName: file.name,
                recordCount: Int(usable / Int64(Self.recordStride))
            )
        }
        .sorted { $0.recordCount > $1.recordCount }
    }

    public static func offset(forIndex index: Int) -> Int64 {
        Int64(headerLength) + Int64(index) * Int64(recordStride)
    }

    /// Parses one record's bytes. Returns nil for an empty slot, and — importantly —
    /// for a record whose UUID is not the asset we asked about. The UUID in the record
    /// means a wrong offset is caught rather than silently shown as someone else's
    /// photo.
    public static func parse(record bytes: Data, expecting uuid: String?) -> Record? {
        guard bytes.count >= recordStride else { return nil }
        let raw = bytes.prefix(uuidLength)
        guard raw.contains(where: { $0 != 0 }) else { return nil }

        let found = formatUUID(Array(raw))
        if let uuid, found.caseInsensitiveCompare(uuid) != .orderedSame { return nil }

        func u32(_ at: Int) -> Int {
            let b = Array(bytes[bytes.startIndex + at ..< bytes.startIndex + at + 4])
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }
        let width = u32(16), height = u32(20)
        guard width > 0, height > 0, width <= gridSide, height <= gridSide else {
            return nil
        }

        let start = bytes.startIndex + pixelDataOffset
        return Record(
            uuid: found,
            width: width,
            height: height,
            pixelData: bytes[start ..< start + pixelDataLength]
        )
    }

    static func formatUUID(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8),
                     hex.dropFirst(8).prefix(4),
                     hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4),
                     hex.dropFirst(20).prefix(12)]
        return parts.joined(separator: "-")
    }
}
