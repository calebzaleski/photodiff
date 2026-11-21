import Foundation
import Testing
@testable import PhotoDiffCore

@Suite("Reading a library")
struct LibraryReaderTests {

    @Test("The modern schema (Photos 7 and later) is read")
    func modernSchema() throws {
        let fixture = try FakeLibrary.make(assetCount: 12, schema: .modern)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        #expect(outcome.schema == "ZASSET")
        #expect(outcome.assets.count == 12)
        #expect(outcome.assets.allSatisfy { $0.width == 4032 && $0.height == 3024 })
    }

    @Test("The older schema (Photos 5 and 6) is read by the same code path")
    func legacySchema() throws {
        let fixture = try FakeLibrary.make(assetCount: 9, schema: .legacy)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        #expect(outcome.schema == "ZGENERICASSET")
        #expect(outcome.assets.count == 9)
        // Same AssetRecord shape regardless of which schema it came from.
        #expect(outcome.assets.first?.originalFilename?.hasPrefix("IMG_") == true)
    }

    @Test("Capture dates are read in Apple's 2001 epoch, not 1970")
    func datesUseTheReferenceEpoch() throws {
        let base = Date(timeIntervalSinceReferenceDate: 600_000_000)
        let fixture = try FakeLibrary.make(assetCount: 1, startingAt: base)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        let captured = try #require(outcome.assets.first?.captureDate)
        // The fixture puts the first asset 600 seconds after the base.
        #expect(abs(captured.timeIntervalSince(base) - 600) < 1)
        // Sanity: a 1970-epoch bug would land this three decades out.
        #expect(captured.timeIntervalSince(base) < 86_400)
    }

    @Test("Trashed assets are skipped, not reported as missing photos")
    func trashedSkipped() throws {
        let fixture = try FakeLibrary.make(assetCount: 20, trashedEvery: 5)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        #expect(outcome.trashedCount == 4)
        #expect(outcome.assets.count == 16)
    }

    @Test("Shared-album assets are flagged and counted")
    func sharedFlagged() throws {
        let fixture = try FakeLibrary.make(assetCount: 20, sharedEvery: 4)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        #expect(outcome.sharedCount == 5)
        #expect(outcome.sharedColumnUsed == "ZLIBRARYSCOPE")
    }

    @Test("Fingerprints come through for the assets that have them")
    func fingerprintsRead() throws {
        let fixture = try FakeLibrary.make(assetCount: 10)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        // The fixture gives every second asset a fingerprint, as real libraries do patchily.
        #expect(outcome.assets.filter { $0.fingerprint != nil }.count == 5)
        #expect(outcome.assets.compactMap(\.fingerprint).allSatisfy { $0.hasPrefix("fp-") })
    }

    @Test("Videos keep their length; photos have none")
    func videoDurations() throws {
        let fixture = try FakeLibrary.make(assetCount: 14)
        defer { fixture.cleanUp() }

        let outcome = try LibraryReader(bundleURL: fixture.bundleURL).read()
        let videos = outcome.assets.filter { $0.kind == .video }
        #expect(videos.count == 2)                       // every seventh asset
        #expect(videos.allSatisfy { ($0.duration ?? 0) > 0 })
        #expect(outcome.assets.filter { $0.kind == .photo }.allSatisfy { $0.duration == nil })
    }

    @Test("A folder that is not a library is refused")
    func notALibrary() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ReadOnlyLibrary.Failure.self) {
            _ = try LibraryReader(bundleURL: dir)
        }
    }

    @Test("Each library gets its own identity, so copies do not collide")
    func identitiesDiffer() throws {
        let a = try FakeLibrary.make(assetCount: 2, name: "One")
        let b = try FakeLibrary.make(assetCount: 2, name: "Two")
        defer { a.cleanUp(); b.cleanUp() }

        let ra = try LibraryReader(bundleURL: a.bundleURL)
        let rb = try LibraryReader(bundleURL: b.bundleURL)
        #expect(ra.identity != rb.identity)
        #expect(ra.displayName == "One")
        #expect(rb.displayName == "Two")
    }

    @Test("Assets from two libraries diff as one combined set")
    func twoLibrariesCombine() throws {
        // Same capture times in both, so every photo is a duplicate of the other's.
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let a = try FakeLibrary.make(assetCount: 6, name: "Older", startingAt: base)
        let b = try FakeLibrary.make(assetCount: 6, name: "Newer", startingAt: base)
        defer { a.cleanUp(); b.cleanUp() }

        let assets = try LibraryReader(bundleURL: a.bundleURL).read().assets
            + LibraryReader(bundleURL: b.bundleURL).read().assets
        #expect(assets.count == 12)

        let result = DiffEngine.diff(oldAssets: assets, against: MatchIndex())
        #expect(result.missing.count == 6)
        #expect(result.missing.allSatisfy { $0.copies.count == 2 })
    }
}
