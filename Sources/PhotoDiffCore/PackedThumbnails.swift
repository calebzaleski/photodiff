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
/// ## The format
///
/// Undocumented, worked out by reading a real library and checked against its
/// database: the UUIDs stored in these records match the assets whose
/// `ZTHUMBNAILINDEX` is 0...6, in order, at exactly the offsets below.
///
/// ```text
///   record for ZTHUMBNAILINDEX = k starts at k * 4124
///
///   each record, 4124 bytes:
///     0..4095      pixel data (see below), zero-padded
///     4096..4111   asset UUID, raw 16 bytes  <- lets a record be verified, not trusted
///     4112..4115   width  in pixels, uint32 LE   e.g. 30, 48, 64
///     4116..4119   height in pixels, uint32 LE   e.g. 64, 48, 19
///     4120..4123   zero in every record observed
/// ```
///
/// The pixels are **BC7** (BPTC) — 4×4 blocks, 16 bytes each, so the used length is
/// `ceil(w/4) * ceil(h/4) * 16` and the rest of the 4096 bytes is zero padding. A
/// thumbnail is at most 64×64, which is why 4096 bytes is always enough.
///
/// Two wrong turns worth recording, so nobody repeats them. The data looks like ASTC
/// (same block size, same one-byte-per-pixel ratio) and is not; the GPU renders
/// invalid ASTC as magenta, which is the giveaway. And a Metal *blit* from a
/// compressed texture to an RGBA one is not a decode — it reinterprets the bytes, so
/// every candidate format produces the same plausible-looking rubbish. The texture
/// has to be sampled in a shader. See `ThumbnailDecoder`.
public struct PackedThumbnails: Sendable {

    public static let recordStride = 4124
    public static let pixelDataLength = 4096
    public static let uuidOffset = 4096
    public static let uuidLength = 16
    public static let widthOffset = 4112
    public static let heightOffset = 4116
    /// Thumbnails never exceed this on either side.
    public static let maximumSide = 64
    /// BC7: 4×4 pixels per block, 16 bytes per block.
    public static let blockSide = 4
    public static let bytesPerBlock = 16

    public struct Record: Sendable {
        /// Uppercased, hyphenated, as the database writes it.
        public let uuid: String
        public let width: Int
        public let height: Int
        /// BC7 blocks, exactly `blockBytes` long. Hand to `ThumbnailDecoder`.
        public let pixelData: Data

        public var blocksWide: Int { (width + blockSide - 1) / blockSide }
        public var blocksHigh: Int { (height + blockSide - 1) / blockSide }
        /// Width and height rounded up to whole blocks — the size of the texture the
        /// decoder makes, before cropping back to `width` × `height`.
        public var paddedWidth: Int { blocksWide * blockSide }
        public var paddedHeight: Int { blocksHigh * blockSide }
        public var blockBytes: Int { blocksWide * blocksHigh * bytesPerBlock }
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
            guard file.bytes >= Int64(Self.recordStride) else { return nil }
            return File(
                formatID: Int((file.name as NSString).deletingPathExtension) ?? 0,
                fileName: file.name,
                recordCount: Int(file.bytes / Int64(Self.recordStride))
            )
        }
        .sorted { $0.recordCount > $1.recordCount }
    }

    public static func offset(forIndex index: Int) -> Int64 {
        Int64(index) * Int64(recordStride)
    }

    /// Parses one record's bytes. Returns nil for an empty slot, and — importantly —
    /// for a record whose UUID is not the asset we asked about. The UUID in the record
    /// means a wrong offset is caught rather than silently shown as someone else's
    /// photo.
    public static func parse(record bytes: Data, expecting uuid: String?) -> Record? {
        guard bytes.count >= recordStride else { return nil }
        let base = bytes.startIndex
        let raw = bytes[base + uuidOffset ..< base + uuidOffset + uuidLength]
        guard raw.contains(where: { $0 != 0 }) else { return nil }

        let found = formatUUID(Array(raw))
        if let uuid, found.caseInsensitiveCompare(uuid) != .orderedSame { return nil }

        func u32(_ at: Int) -> Int {
            let b = Array(bytes[base + at ..< base + at + 4])
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }
        let width = u32(widthOffset), height = u32(heightOffset)
        guard width > 0, height > 0,
              width <= maximumSide, height <= maximumSide else { return nil }

        let blocks = ((width + blockSide - 1) / blockSide)
            * ((height + blockSide - 1) / blockSide) * bytesPerBlock
        guard blocks <= pixelDataLength else { return nil }

        return Record(
            uuid: found,
            width: width,
            height: height,
            pixelData: bytes[base ..< base + blocks]
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
