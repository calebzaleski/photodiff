import Foundation
import Testing
@testable import PhotoDiffCore

/// The container layout here was worked out from a real library and checked against
/// its database. These tests pin it down so a later change cannot quietly break it.
@Suite("Packed thumbnail container")
struct PackedThumbnailTests {

    /// Builds one synthetic record. No real library data is used.
    static let sixtyFour = PackedThumbnails.describe(name: "4133.ithmb", bytes: 54_634_752)!

    static func record(
        uuid: String, width: Int, height: Int, fill: UInt8,
        in file: PackedThumbnails.File? = nil
    ) -> Data {
        let f = file ?? sixtyFour
        // Pixels first, then the UUID and dimensions as a trailer — the real layout.
        var d = Data(repeating: fill, count: f.pixelCapacity)
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        for i in stride(from: 0, to: hex.count, by: 2) {
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2)
            d.append(UInt8(hex[s..<e], radix: 16)!)
        }
        func u32(_ v: Int) -> Data {
            Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                  UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        d.append(u32(width)); d.append(u32(height)); d.append(u32(0))
        return d
    }

    /// All three sizes seen in one real library. The stride is recovered from the
    /// file length alone, because the name is a format id and says nothing about size.
    @Test("Each file's record size is recovered from its length")
    func strideFromLength() throws {
        let small = try #require(PackedThumbnails.describe(name: "3356.ithmb", bytes: 13_936_896))
        #expect(small.stride == 1052)
        #expect(small.pixelCapacity == 1024)
        #expect(small.maximumSide == 32)

        let medium = try #require(PackedThumbnails.describe(name: "4133.ithmb", bytes: 54_634_752))
        #expect(medium.stride == 4124)
        #expect(medium.maximumSide == 64)

        let large = try #require(PackedThumbnails.describe(name: "4532.ithmb", bytes: 191_142_144))
        #expect(large.stride == 14428)
        #expect(large.pixelCapacity == 14400)
        #expect(large.maximumSide == 120)

        // Every file in that library held the same number of records.
        #expect(small.recordCount == 13_248)
        #expect(medium.recordCount == 13_248)
        #expect(large.recordCount == 13_248)
    }

    @Test("The largest thumbnails are offered first")
    func largestFirst() {
        let p = PackedThumbnails(files: [
            ("4133.ithmb", 54_634_752),
            ("3356.ithmb", 13_936_896),
            ("4532.ithmb", 191_142_144),
        ])
        #expect(p.files.map(\.maximumSide) == [120, 64, 32])
    }

    @Test("Records are a stride apart, starting at zero")
    func offsets() {
        let f = Self.sixtyFour
        #expect(f.offset(forIndex: 0) == 0)
        #expect(f.offset(forIndex: 1) == 4124)
        #expect(f.offset(forIndex: 2) == 8248)
    }

    /// The layout was confirmed this way against a real library: the UUID of the asset
    /// with ZTHUMBNAILINDEX = k appeared at k*4124 + 4096, for k = 0...6.
    @Test("The uuid trailer lands where the real library put it")
    func uuidTrailerOffsets() {
        let f = Self.sixtyFour
        func uuidAt(_ k: Int) -> Int64 {
            f.offset(forIndex: k) + Int64(f.pixelCapacity)
        }
        #expect(uuidAt(0) == 4096)
        #expect(uuidAt(1) == 8220)
        #expect(uuidAt(2) == 12344)
        #expect(uuidAt(3) == 16468)
        #expect(uuidAt(6) == 28840)
    }

    @Test("Pixel length follows the BC7 block grid, not the whole 4096 bytes")
    func blockMaths() throws {
        let id = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        // 30x64 -> 8x16 blocks -> 2048 bytes. This matched the real file exactly:
        // record 0 had precisely 2048 non-zero bytes.
        let r = try #require(PackedThumbnails.parse(
            record: Self.record(uuid: id, width: 30, height: 64, fill: 9),
            in: Self.sixtyFour, expecting: id))
        #expect(r.blocksWide == 8)
        #expect(r.blocksHigh == 16)
        #expect(r.blockBytes == 2048)
        #expect(r.pixelData.count == 2048)
        #expect(r.paddedWidth == 32)
        #expect(r.paddedHeight == 64)

        // A full 64x64 uses all 4096 bytes.
        let full = try #require(PackedThumbnails.parse(
            record: Self.record(uuid: id, width: 64, height: 64, fill: 9),
            in: Self.sixtyFour, expecting: id))
        #expect(full.blockBytes == 4096)
    }

    @Test("A record yields its uuid, dimensions and pixel bytes")
    func parsing() throws {
        let id = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        let r = try #require(
            PackedThumbnails.parse(record: Self.record(uuid: id, width: 30, height: 64, fill: 7),
                                   in: Self.sixtyFour, expecting: id)
        )
        #expect(r.uuid == id)
        #expect(r.width == 30)
        #expect(r.height == 64)
        #expect(r.pixelData.count == r.blockBytes)
        #expect(r.pixelData.allSatisfy { $0 == 7 })
    }

    /// The UUID inside each record is the safeguard: if the offset maths is ever
    /// wrong, this catches it instead of showing someone else's photo.
    @Test("A record belonging to a different photo is refused")
    func wrongPhotoRefused() {
        let stored = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        let asked  = "C4D05BC2-8798-4AFC-AECD-1A8E94B591A1"
        #expect(PackedThumbnails.parse(
            record: Self.record(uuid: stored, width: 64, height: 48, fill: 1),
            in: Self.sixtyFour, expecting: asked
        ) == nil)
    }

    @Test("An empty slot is not mistaken for a picture")
    func emptySlot() {
        let empty = Data(repeating: 0, count: Self.sixtyFour.stride)
        #expect(PackedThumbnails.parse(record: empty, in: Self.sixtyFour, expecting: nil) == nil)
    }

    @Test("Impossible dimensions are rejected rather than trusted")
    func absurdDimensions() {
        let id = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        for (w, h) in [(0, 64), (64, 0), (9999, 64), (64, 9999)] {
            #expect(PackedThumbnails.parse(
                record: Self.record(uuid: id, width: w, height: h, fill: 3),
                in: Self.sixtyFour, expecting: id
            ) == nil, "accepted \(w)x\(h)")
        }
    }

    @Test("A file whose length fits no record size is left alone")
    func unknownLayoutIgnored() {
        // A prime-ish length that is not a multiple of any (blocks^2 * 16 + 28).
        #expect(PackedThumbnails.describe(name: "9999.ithmb", bytes: 1_000_003) == nil)
        #expect(PackedThumbnails(files: [("4133.ithmb", 0)]).files.isEmpty)
    }
}
