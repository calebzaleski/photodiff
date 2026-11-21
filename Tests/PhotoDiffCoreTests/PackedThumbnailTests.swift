import Foundation
import Testing
@testable import PhotoDiffCore

/// The container layout here was worked out from a real library and checked against
/// its database. These tests pin it down so a later change cannot quietly break it.
@Suite("Packed thumbnail container")
struct PackedThumbnailTests {

    /// Builds one synthetic record. No real library data is used.
    static func record(uuid: String, width: Int, height: Int, fill: UInt8) -> Data {
        var d = Data()
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
        d.append(Data(repeating: fill, count: PackedThumbnails.pixelDataLength))
        return d
    }

    @Test("Record offsets follow a 4096-byte header and a 4124-byte stride")
    func offsets() {
        // These exact numbers were verified against a real library: the assets with
        // ZTHUMBNAILINDEX 0...6 had their UUIDs at precisely these offsets.
        #expect(PackedThumbnails.offset(forIndex: 0) == 4096)
        #expect(PackedThumbnails.offset(forIndex: 1) == 8220)
        #expect(PackedThumbnails.offset(forIndex: 2) == 12344)
        #expect(PackedThumbnails.offset(forIndex: 3) == 16468)
        #expect(PackedThumbnails.offset(forIndex: 6) == 28840)
    }

    @Test("A record yields its uuid, dimensions and pixel bytes")
    func parsing() throws {
        let id = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        let r = try #require(
            PackedThumbnails.parse(record: Self.record(uuid: id, width: 30, height: 64, fill: 7),
                                   expecting: id)
        )
        #expect(r.uuid == id)
        #expect(r.width == 30)
        #expect(r.height == 64)
        #expect(r.pixelData.count == 4096)
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
            expecting: asked
        ) == nil)
    }

    @Test("An empty slot is not mistaken for a picture")
    func emptySlot() {
        let empty = Data(repeating: 0, count: PackedThumbnails.recordStride)
        #expect(PackedThumbnails.parse(record: empty, expecting: nil) == nil)
    }

    @Test("Impossible dimensions are rejected rather than trusted")
    func absurdDimensions() {
        let id = "9451791F-F5D8-437B-82CE-0C40AC1EE156"
        for (w, h) in [(0, 64), (64, 0), (9999, 64), (64, 9999)] {
            #expect(PackedThumbnails.parse(
                record: Self.record(uuid: id, width: w, height: h, fill: 3),
                expecting: id
            ) == nil, "accepted \(w)x\(h)")
        }
    }

    @Test("Record counts come from the file length")
    func recordCounts() {
        // The real 4133.ithmb from the library that was examined.
        let p = PackedThumbnails(files: [("4133.ithmb", 54_634_752)])
        #expect(p.files.count == 1)
        #expect(p.files[0].formatID == 4133)
        // (54634752 - 4096) / 4124, and it must cover the 13,224 slots that library needs.
        #expect(p.files[0].recordCount == 13_247)
        #expect(p.files[0].recordCount >= 13_224)
    }

    @Test("A file too small to hold even a header is ignored")
    func tinyFileIgnored() {
        #expect(PackedThumbnails(files: [("4133.ithmb", 64)]).files.isEmpty)
    }
}
