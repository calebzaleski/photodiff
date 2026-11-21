import Foundation
import SQLite3

/// A synthetic `.photoslibrary` for tests. Nothing here comes from a real library —
/// the rows are generated, so no personal data ever enters the repo.
struct FakeLibrary {

    let bundleURL: URL
    private let container: URL

    enum Schema {
        /// Photos 7+ — the `ZASSET` table.
        case modern
        /// Photos 5–6 — the `ZGENERICASSET` table.
        case legacy

        var assetTable: String {
            switch self {
            case .modern: return "ZASSET"
            case .legacy: return "ZGENERICASSET"
            }
        }
    }

    static func make(
        assetCount: Int,
        schema: Schema = .modern,
        name: String = "Test Library",
        startingAt base: Date = Date(timeIntervalSinceReferenceDate: 600_000_000),
        sharedEvery: Int? = nil,
        trashedEvery: Int? = nil
    ) throws -> FakeLibrary {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("photodiff-fixture-\(UUID().uuidString)", isDirectory: true)
        let bundle = container.appendingPathComponent("\(name).photoslibrary", isDirectory: true)

        for sub in ["database", "originals", "resources/derivatives/thumbs"] {
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }

        let dbPath = bundle.appendingPathComponent("database/Photos.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            throw NSError(domain: "FakeLibrary", code: 1)
        }
        defer { sqlite3_close_v2(db) }

        func run(_ sql: String) throws {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                throw NSError(
                    domain: "FakeLibrary", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }

        try run("""
            CREATE TABLE \(schema.assetTable) (
              Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDATECREATED REAL,
              ZWIDTH INTEGER, ZHEIGHT INTEGER, ZKIND INTEGER, ZDURATION REAL,
              ZTRASHEDSTATE INTEGER, ZHIDDEN INTEGER, ZTHUMBNAILINDEX INTEGER,
              ZDIRECTORY TEXT, ZFILENAME TEXT, ZLIBRARYSCOPE INTEGER
            )
            """)
        try run("""
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (
              Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZORIGINALFILENAME TEXT,
              ZORIGINALFILESIZE INTEGER, ZTIMEZONEOFFSET INTEGER
            )
            """)
        try run("""
            CREATE TABLE ZINTERNALRESOURCE (
              Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZFINGERPRINT TEXT,
              ZRESOURCETYPE INTEGER, ZLOCALAVAILABILITY INTEGER
            )
            """)

        for i in 1...max(1, assetCount) {
            let uuid = String(format: "FAKE%04d-0000-0000-0000-00000000FACE", i)
            // One photo every ten minutes, so no two share a capture second.
            let capture = base.timeIntervalSinceReferenceDate + Double(i) * 600
            let isVideo = i % 7 == 0
            let shared = sharedEvery.map { i % $0 == 0 } ?? false
            let trashed = trashedEvery.map { i % $0 == 0 } ?? false
            let w = 4032, h = 3024

            try run("""
                INSERT INTO \(schema.assetTable)
                  (Z_PK, ZUUID, ZDATECREATED, ZWIDTH, ZHEIGHT, ZKIND, ZDURATION,
                   ZTRASHEDSTATE, ZHIDDEN, ZTHUMBNAILINDEX, ZDIRECTORY, ZFILENAME,
                   ZLIBRARYSCOPE)
                VALUES (\(i), '\(uuid)', \(capture), \(w), \(h), \(isVideo ? 1 : 0),
                        \(isVideo ? 12.5 : 0), \(trashed ? 1 : 0), 0, \(i - 1),
                        '2019/04', 'IMG_\(1000 + i).HEIC', \(shared ? 1 : 0))
                """)
            try run("""
                INSERT INTO ZADDITIONALASSETATTRIBUTES
                  (Z_PK, ZASSET, ZORIGINALFILENAME, ZORIGINALFILESIZE, ZTIMEZONEOFFSET)
                VALUES (\(i), \(i), 'IMG_\(1000 + i).HEIC', \(1_000_000 + i), -18000)
                """)
            // Half the assets carry a fingerprint, matching how patchy real libraries are.
            if i % 2 == 0 {
                try run("""
                    INSERT INTO ZINTERNALRESOURCE
                      (Z_PK, ZASSET, ZFINGERPRINT, ZRESOURCETYPE, ZLOCALAVAILABILITY)
                    VALUES (\(i), \(i), 'fp-\(uuid)', 0, 1)
                    """)
            }
        }

        return FakeLibrary(bundleURL: bundle, container: container)
    }

    /// Changes a file inside the bundle, to prove the tripwire notices.
    func tamper() throws {
        let marker = bundleURL.appendingPathComponent("originals/tampered.txt")
        try Data("changed".utf8).write(to: marker)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: container)
    }
}
