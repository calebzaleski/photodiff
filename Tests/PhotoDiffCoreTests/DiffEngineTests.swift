import Foundation
import Testing
@testable import PhotoDiffCore

private let t0 = Date(timeIntervalSinceReferenceDate: 600_000_000)

private func asset(
    _ uuid: String,
    library: String = "Old",
    at date: Date? = t0,
    size: (Int, Int) = (4032, 3024),
    duration: Double? = nil,
    name: String? = "IMG_0001.HEIC",
    bytes: Int64? = 2_000_000,
    fingerprint: String? = nil,
    shared: Bool = false,
    filename: String? = "IMG_0001.HEIC"
) -> AssetRecord {
    AssetRecord(
        uuid: uuid,
        libraryIdentity: library,
        libraryName: library,
        captureDate: date,
        timeZoneOffset: nil,
        width: size.0,
        height: size.1,
        duration: duration,
        originalFilename: name,
        originalFileSize: bytes,
        kind: duration == nil ? .photo : .video,
        isHidden: false,
        isShared: shared,
        fingerprint: fingerprint,
        placement: .init(directory: "2019/04", filename: filename, thumbnailIndex: 0)
    )
}

@Suite("Matching tiers")
struct MatchIndexTests {

    @Test("A fingerprint match is reported as certain")
    func fingerprintWins() {
        var index = MatchIndex()
        index.insert(asset("a", fingerprint: "fp-1", filename: nil))
        // Different date, different size, different name — only the fingerprint agrees.
        let probe = asset(
            "b", at: t0.addingTimeInterval(99_999), size: (100, 100),
            name: "OTHER.JPG", bytes: 5, fingerprint: "fp-1"
        )
        #expect(index.tier(matching: probe) == .fingerprint)
        #expect(MatchTier.fingerprint.isCertain)
    }

    @Test("Same second and same dimensions matches, and survives a one-second drift")
    func timeAndSize() {
        var index = MatchIndex()
        index.insert(asset("a"))

        #expect(index.tier(matching: asset("b", name: nil, bytes: nil)) == .timeAndSize)
        #expect(index.tier(matching: asset("c", at: t0.addingTimeInterval(1), name: nil, bytes: nil)) == .timeAndSize)
        #expect(index.tier(matching: asset("d", at: t0.addingTimeInterval(-1), name: nil, bytes: nil)) == .timeAndSize)
        // Two seconds out is beyond the tolerance.
        #expect(index.tier(matching: asset("e", at: t0.addingTimeInterval(2), name: nil, bytes: nil)) == nil)
    }

    @Test("A rotated copy of the same photo still matches")
    func orientationDoesNotMatter() {
        var index = MatchIndex()
        index.insert(asset("a", size: (4032, 3024)))
        #expect(index.tier(matching: asset("b", size: (3024, 4032), name: nil, bytes: nil)) == .timeAndSize)
    }

    @Test("A re-encode with new dimensions matches on date and filename")
    func timeAndName() {
        var index = MatchIndex()
        index.insert(asset("a", size: (4032, 3024), name: "IMG_7788.HEIC"))
        let reencoded = asset("b", size: (1024, 768), name: "IMG_7788.jpg", bytes: 99)
        #expect(index.tier(matching: reencoded) == .timeAndName)
    }

    @Test("An asset with no date matches on filename and byte size")
    func nameAndSize() {
        var index = MatchIndex()
        index.insert(asset("a", name: "IMG_4242.HEIC", bytes: 3_333_333))
        let dateless = asset("b", at: nil, size: (0, 0), name: "IMG_4242.HEIC", bytes: 3_333_333)
        #expect(index.tier(matching: dateless) == .nameAndSize)
    }

    // The failure that actually costs something: calling a photo "missing" when it is
    // already there leads to a duplicate import. These guard the other direction too.

    @Test("Two different photos taken in the same second do not match")
    func sameSecondDifferentPhoto() {
        var index = MatchIndex()
        index.insert(asset("a", size: (4032, 3024), name: "IMG_1111.HEIC", bytes: 1))
        let other = asset("b", size: (1920, 1080), name: "IMG_2222.HEIC", bytes: 2)
        #expect(index.tier(matching: other) == nil)
    }

    @Test("Two clips at the same instant and resolution are told apart by length")
    func videoDurationMatters() {
        var index = MatchIndex()
        index.insert(asset("a", duration: 12.0, name: nil, bytes: nil))

        #expect(index.tier(matching: asset("b", duration: 12.2, name: nil, bytes: nil)) == .timeAndSize)
        #expect(index.tier(matching: asset("c", duration: 40.0, name: nil, bytes: nil)) == nil)
    }

    @Test("A photo never matches a video, even at the same instant and size")
    func photoIsNotAVideo() {
        var index = MatchIndex()
        index.insert(asset("a", duration: 8.0, name: nil, bytes: nil))
        #expect(index.tier(matching: asset("b", duration: nil, name: nil, bytes: nil)) == nil)
    }

    @Test("An empty index matches nothing")
    func emptyIndex() {
        #expect(MatchIndex().tier(matching: asset("a")) == nil)
    }

    @Test("A blank fingerprint is not treated as a match")
    func blankFingerprintIgnored() {
        var index = MatchIndex()
        index.insert(asset("a", at: nil, size: (0, 0), name: nil, bytes: nil, fingerprint: ""))
        let probe = asset("b", at: nil, size: (0, 0), name: nil, bytes: nil, fingerprint: "")
        #expect(index.tier(matching: probe) == nil)
    }
}

@Suite("Diffing libraries")
struct DiffEngineTests {

    @Test("Assets already in the current library are not reported")
    func presentAssetsExcluded() {
        var current = MatchIndex()
        current.insert(asset("here", at: t0))

        let result = DiffEngine.diff(
            oldAssets: [asset("old-copy", at: t0, name: nil, bytes: nil)],
            against: current
        )
        #expect(result.missing.isEmpty)
        #expect(result.summary.presentCount == 1)
        #expect(result.summary.byTier[.timeAndSize] == 1)
    }

    @Test("An asset the current library lacks is reported missing")
    func missingAssetReported() {
        let result = DiffEngine.diff(
            oldAssets: [asset("gone", at: t0)],
            against: MatchIndex()
        )
        #expect(result.missing.count == 1)
        #expect(result.missing[0].representative.uuid == "gone")
        #expect(result.summary.missingCount == 1)
    }

    @Test("The same photo in several old libraries becomes one entry")
    func duplicatesAcrossLibrariesFold() {
        let same = t0
        let result = DiffEngine.diff(
            oldAssets: [
                asset("a", library: "Library 2", at: same),
                asset("b", library: "Library 5", at: same),
                asset("c", library: "Library 8", at: same),
            ],
            against: MatchIndex()
        )
        #expect(result.missing.count == 1)
        #expect(result.missing[0].copies.count == 3)
        #expect(result.missing[0].otherLibraryCount == 2)
        #expect(result.missing[0].libraryNames == ["Library 2", "Library 5", "Library 8"])
        #expect(result.summary.duplicateCopiesFolded == 2)
    }

    @Test("Genuinely different photos stay separate")
    func distinctPhotosStaySeparate() {
        let result = DiffEngine.diff(
            oldAssets: [
                asset("a", at: t0, name: "A.HEIC", bytes: 1),
                asset("b", at: t0.addingTimeInterval(5000), size: (1920, 1080), name: "B.HEIC", bytes: 2),
                asset("c", at: t0.addingTimeInterval(9000), size: (800, 600), name: "C.HEIC", bytes: 3),
            ],
            against: MatchIndex()
        )
        #expect(result.missing.count == 3)
    }

    @Test("Shared-album photos are left out by default and counted separately")
    func sharedExcludedByDefault() {
        let assets = [
            asset("mine", at: t0, name: "A.HEIC", bytes: 1),
            asset("theirs", at: t0.addingTimeInterval(5000), name: "B.HEIC", bytes: 2, shared: true),
        ]
        let excluded = DiffEngine.diff(oldAssets: assets, against: MatchIndex())
        #expect(excluded.missing.count == 1)
        #expect(excluded.summary.sharedSkipped == 1)

        let included = DiffEngine.diff(oldAssets: assets, against: MatchIndex(), includeShared: true)
        #expect(included.missing.count == 2)
    }

    @Test("The representative is the copy most likely to still have a picture")
    func representativePrefersRealFiles() {
        let result = DiffEngine.diff(
            oldAssets: [
                asset("thin", library: "A", at: t0, bytes: 100, filename: nil),
                asset("fat", library: "B", at: t0, bytes: 9_000_000, filename: "IMG_0001.HEIC"),
            ],
            against: MatchIndex()
        )
        #expect(result.missing.count == 1)
        #expect(result.missing[0].representative.uuid == "fat")
    }

    @Test("The same input always gives the same result")
    func resultIsDeterministic() {
        let assets = (1...50).map {
            asset("u\($0)", library: "L\($0 % 4)", at: t0.addingTimeInterval(Double($0) * 700),
                  name: "IMG_\($0).HEIC", bytes: Int64($0))
        }
        let a = DiffEngine.diff(oldAssets: assets, against: MatchIndex())
        let b = DiffEngine.diff(oldAssets: assets.shuffled(), against: MatchIndex())
        #expect(a.missing.map(\.id) == b.missing.map(\.id))
    }
}
