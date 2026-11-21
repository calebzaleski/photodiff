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
///   record for ZTHUMBNAILINDEX = k starts at k * stride
///
///   each record:
///     0 ..< P          pixel data (see below), zero-padded
///     P   ..< P+16     asset UUID, raw 16 bytes  <- verify, don't trust
///     P+16 ..< P+20    width  in pixels, uint32 LE   e.g. 30, 48, 64
///     P+20 ..< P+24    height in pixels, uint32 LE   e.g. 64, 48, 19
///     P+24 ..< P+28    zero in every record observed
///
///   stride = P + 28
/// ```
///
/// The pixels are **BC7** (BPTC) — 4×4 blocks, 16 bytes each — so the used length is
/// `ceil(w/4) * ceil(h/4) * 16` and the rest of `P` is zero padding.
///
/// A library keeps several of these files side by side at different resolutions, each
/// named for Photos' own format id. One real library held three, all with the same
/// record count and differing only in `P`:
///
/// | file         | stride | P      | largest thumbnail |
/// |--------------|--------|--------|-------------------|
/// | `3356.ithmb` |  1,052 |  1,024 |  32 × 32          |
/// | `4133.ithmb` |  4,124 |  4,096 |  64 × 64          |
/// | `4532.ithmb` | 14,428 | 14,400 | 120 × 120         |
///
/// `P` is always `(side/4)² × 16` for the largest thumbnail the file can hold, so the
/// stride can be recovered from the file's length alone — which matters, because the
/// name is a format id and says nothing about the size. The biggest file wins.
///
/// Two wrong turns worth recording, so nobody repeats them. The data looks like ASTC
/// (same block size, same one-byte-per-pixel ratio) and is not; the GPU renders
/// invalid ASTC as magenta, which is the giveaway. And a Metal *blit* from a
/// compressed texture to an RGBA one is not a decode — it reinterprets the bytes, so
/// every candidate format produces the same plausible-looking rubbish. The texture
/// has to be sampled in a shader. See `ThumbnailDecoder`.
public struct PackedThumbnails: Sendable {

    /// Bytes of UUID and dimensions after the pixel data.
    public static let trailerLength = 28
    public static let uuidLength = 16
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
        public let stride: Int
        /// Bytes of pixel data before the trailer.
        public let pixelCapacity: Int
        /// The largest thumbnail this file can hold, on either side.
        public let maximumSide: Int
        public let recordCount: Int

        public func offset(forIndex index: Int) -> Int64 {
            Int64(index) * Int64(stride)
        }
    }

    /// Largest thumbnail first, so the best available picture is tried first.
    public let files: [File]

    public init(files: [(name: String, bytes: Int64)]) {
        self.files = files.compactMap { Self.describe(name: $0.name, bytes: $0.bytes) }
            .sorted { $0.maximumSide > $1.maximumSide }
    }

    /// Recovers a file's record size from its length.
    ///
    /// The pixel area is always a square BC7 grid, so the stride must be
    /// `(blocks² × 16) + 28` for some whole number of blocks, and the file length must
    /// be an exact multiple of it. Those two conditions together pin the stride down;
    /// the largest candidate that satisfies both is the answer. Anything that fits
    /// neither is left alone rather than guessed at.
    static func describe(name: String, bytes: Int64) -> File? {
        guard bytes > 0 else { return nil }
        var best: File?

        // 64 blocks a side is 256 pixels — far above anything Photos stores here.
        for blocks in 1...64 {
            let pixels = blocks * blocks * bytesPerBlock
            let stride = pixels + trailerLength
            guard bytes % Int64(stride) == 0 else { continue }
            let count = Int(bytes / Int64(stride))
            guard count > 0 else { continue }
            best = File(
                formatID: Int((name as NSString).deletingPathExtension) ?? 0,
                fileName: name,
                stride: stride,
                pixelCapacity: pixels,
                maximumSide: blocks * blockSide,
                recordCount: count
            )
        }
        return best
    }

    /// Parses one record's bytes. Returns nil for an empty slot, and — importantly —
    /// for a record whose UUID is not the asset we asked about. The UUID in the record
    /// means a wrong offset is caught rather than silently shown as someone else's
    /// photo.
    public static func parse(
        record bytes: Data, in file: File, expecting uuid: String?
    ) -> Record? {
        guard bytes.count >= file.stride else { return nil }
        let base = bytes.startIndex
        let pixelEnd = base + file.pixelCapacity
        let raw = bytes[pixelEnd ..< pixelEnd + uuidLength]
        guard raw.contains(where: { $0 != 0 }) else { return nil }

        let found = formatUUID(Array(raw))
        if let uuid, found.caseInsensitiveCompare(uuid) != .orderedSame { return nil }

        func u32(_ at: Int) -> Int {
            let b = Array(bytes[at ..< at + 4])
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }
        let width = u32(pixelEnd + 16), height = u32(pixelEnd + 20)
        guard width > 0, height > 0,
              width <= file.maximumSide, height <= file.maximumSide else { return nil }

        let blocks = ((width + blockSide - 1) / blockSide)
            * ((height + blockSide - 1) / blockSide) * bytesPerBlock
        guard blocks <= file.pixelCapacity else { return nil }

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
