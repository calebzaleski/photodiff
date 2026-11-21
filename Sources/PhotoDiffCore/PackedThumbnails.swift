import Foundation

/// Reads Photos' packed thumbnail cache — the `.ithmb` files under
/// `resources/derivatives/thumbs/`.
///
/// This matters more than it sounds. Libraries that ran with iCloud "Optimize Mac
/// Storage" keep almost no full-size originals on disk, and only a minority of assets
/// have a per-asset derivative JPEG. But Photos keeps a small thumbnail for very nearly
/// every asset here — in one real library, 13,081 of 13,087 photos. Without this, most
/// of a result is filename tiles; with it, nearly all of it is pictures.
///
/// ## The format
///
/// Each `.ithmb` is a flat array of fixed-size records with no header. An asset's
/// record sits at `ZTHUMBNAILINDEX * stride`. Unused slots are zero-filled, and the
/// file is preallocated, so its length is an upper bound on the slot count rather than
/// an exact multiple — the stride cannot be recovered by dividing.
///
/// The records are raw **ASTC 4×4 LDR** blocks: 16 bytes per 4×4 pixel block, so
/// exactly 1 byte per pixel. A 4,096-byte record is therefore 64×64. That is a GPU
/// texture format, which is why the bytes are neither JPEG nor plain pixels.
///
/// The file name is Photos' own format id (4532, 4133, 3356...), not a size, so the
/// stride is derived from the file rather than assumed.
public struct PackedThumbnails: Sendable {

    public struct Format: Sendable {
        /// Photos' format id, which is also the file's name.
        public let id: Int
        public let stride: Int
        public let side: Int
        public let slots: Int
        public let fileName: String
    }

    /// ASTC 4×4 is one byte per pixel, so a square record of `n` bytes is √n on a side.
    /// Only sizes Photos actually uses are accepted, so a file we do not understand is
    /// skipped rather than decoded into noise.
    static let plausibleSides = [32, 64, 128, 160, 256, 320, 512]

    /// Records always begin on a 4KB boundary in the files observed.
    static let alignment = 4096

    public let formats: [Format]

    /// Works out each file's record size from its length and the number of assets that
    /// claim a slot in it. Prefers the largest thumbnail available.
    public init(files: [(name: String, bytes: Int64)], highestIndex: Int) {
        let slotsNeeded = max(1, highestIndex + 1)

        formats = files.compactMap { file -> Format? in
            let id = Int((file.name as NSString).deletingPathExtension) ?? 0
            guard file.bytes > 0 else { return nil }

            // The stride has to be 4KB-aligned and give a square ASTC image at one
            // byte per pixel, and the resulting slot count has to land just above the
            // number of assets — not far above it.
            //
            // That second condition is what keeps this honest. A too-small stride
            // always "fits", it just carves the file into far more slots than there
            // are photos and reads each one from the wrong offset, producing noise.
            // Requiring the count to be within 50% of the asset count rejects that.
            // A file whose layout we cannot pin down this way is skipped, and the
            // caller falls back to a metadata tile — a missing picture is a fair
            // answer, a garbled one is not.
            let candidates = Self.plausibleSides
                .map { (side: $0, stride: $0 * $0) }
                .filter { $0.stride % Self.alignment == 0 }
                .map { (side: $0.side, stride: $0.stride, slots: Int(file.bytes / Int64($0.stride))) }
                .filter { $0.slots >= slotsNeeded }
                .filter { Double($0.slots) < Double(slotsNeeded) * 1.5 }
                .sorted { $0.stride > $1.stride }   // biggest that still qualifies

            guard let best = candidates.first else { return nil }
            return Format(
                id: id,
                stride: best.stride,
                side: best.side,
                slots: best.slots,
                fileName: file.name
            )
        }
        .sorted { $0.side > $1.side }   // best quality first
    }

    /// Where an asset's thumbnail lives, best format first.
    public func locations(forIndex index: Int) -> [(format: Format, offset: Int64)] {
        guard index >= 0 else { return [] }
        return formats.compactMap { format in
            guard index < format.slots else { return nil }
            return (format, Int64(index) * Int64(format.stride))
        }
    }

    /// A record of all zero bytes is an empty slot, not a black picture.
    public static func isEmptySlot(_ data: Data) -> Bool {
        !data.contains { $0 != 0 }
    }
}
