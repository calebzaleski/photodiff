import Foundation

/// Opens one old `.photoslibrary` and reads out its assets.
///
/// Two things make this more than a SELECT:
///  * **Two schemas.** `ZASSET` is Photos 7 and later; `ZGENERICASSET` is Photos 5–6.
///    Columns also drift between point releases, so every column is looked up by name
///    at runtime and a missing one degrades that field instead of failing the library.
///  * **The write-ahead log.** A library closed mid-session keeps real data in
///    `Photos.sqlite-wal`. Reading the database in place would let SQLite recover the
///    log and write to the library. So the database and its log are copied out byte
///    for byte first, and the copy is what gets opened.
public final class LibraryReader {

    public struct Outcome: Sendable {
        public let libraryIdentity: String
        public let libraryName: String
        public let schema: String
        public let assets: [AssetRecord]
        public var photoCount: Int { assets.filter { $0.kind == .photo }.count }
        public var videoCount: Int { assets.filter { $0.kind == .video }.count }
        /// Assets skipped because they were in the trash.
        public let trashedCount: Int
        /// How we decided an asset came from a shared album, and how many did. Recorded
        /// so the number can be sanity-checked against a real library rather than
        /// trusted blindly.
        public let sharedColumnUsed: String?
        public let sharedCount: Int
        public let duration: TimeInterval
    }

    public enum Schema: String {
        case modern = "ZASSET"        // Photos 7+ (macOS 12+)
        case legacy = "ZGENERICASSET" // Photos 5–6 (macOS 10.15–11)
    }

    private let library: ReadOnlyLibrary
    private let temp: TempStore

    /// The same read-only handle, reachable from this file's extensions. Still never
    /// handed outside the module, and still the only route to a library's bytes.
    var libraryHandle: ReadOnlyLibrary { library }

    public init(bundleURL: URL) throws {
        self.library = try ReadOnlyLibrary(bundleURL: bundleURL)
        self.temp = try TempStore(label: "db")
    }

    public var displayName: String { library.displayName }
    public var identity: String { library.identity }

    /// Reads the whole library. Takes a tripwire snapshot first and verifies it after,
    /// so a scan that somehow modified the bundle fails loudly instead of silently.
    public func read() throws -> Outcome {
        let started = Date()
        let before = library.snapshot()

        let dbPath = try copyDatabaseOut()
        let db = try SQLiteRead(path: dbPath.path)

        let tables = db.tableNames()
        guard let schema: Schema = tables.contains(Schema.modern.rawValue) ? .modern
            : tables.contains(Schema.legacy.rawValue) ? .legacy
            : nil
        else {
            throw ReadOnlyLibrary.Failure.missingFile("a recognisable asset table")
        }

        let result = try readAssets(db: db, schema: schema)

        // Enforcement point 4: prove we changed nothing.
        try library.verifyUnchanged(since: before)

        return Outcome(
            libraryIdentity: library.identity,
            libraryName: library.displayName,
            schema: schema.rawValue,
            assets: result.assets,
            trashedCount: result.trashed,
            sharedColumnUsed: result.sharedColumn,
            sharedCount: result.assets.filter(\.isShared).count,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Copying the database out of the library

    /// Streams `Photos.sqlite` and its log files into scratch space. The log files keep
    /// their exact names so SQLite pairs them with the copied database.
    private func copyDatabaseOut() throws -> URL {
        let main = "database/Photos.sqlite"
        let db = try temp.absorb(try library.open(main), as: "Photos.sqlite")

        for suffix in ["-wal", "-shm"] {
            let rel = main + suffix
            guard library.exists(rel) else { continue }
            try temp.absorb(try library.open(rel), as: "Photos.sqlite" + suffix)
        }
        return db
    }

    // MARK: - Reading assets

    private struct ReadResult {
        let assets: [AssetRecord]
        let trashed: Int
        let sharedColumn: String?
    }

    private func readAssets(db: SQLiteRead, schema: Schema) throws -> ReadResult {
        let assetTable = schema.rawValue
        let cols = db.columnNames(of: assetTable)

        // Column names drift between macOS releases. Pick the first that exists.
        func pick(_ candidates: String...) -> String? {
            candidates.first { cols.contains($0) }
        }

        let uuidCol = pick("ZUUID") ?? "ZUUID"
        let dateCol = pick("ZDATECREATED", "ZSORTTOKEN")
        let widthCol = pick("ZWIDTH")
        let heightCol = pick("ZHEIGHT")
        let kindCol = pick("ZKIND")
        let trashCol = pick("ZTRASHEDSTATE")
        let hiddenCol = pick("ZHIDDEN")
        let thumbCol = pick("ZTHUMBNAILINDEX")
        let dirCol = pick("ZDIRECTORY")
        let nameCol = pick("ZFILENAME")
        let durCol = pick("ZDURATION", "ZVIDEODURATION")
        // A non-null value in any of these means the asset came in through a share
        // rather than the user's own library.
        let sharedCol = pick("ZLIBRARYSCOPE", "ZMOMENTSHARE", "ZSHARE", "ZCLOUDSHAREDALBUM")

        var select = ["A.Z_PK AS pk", "A.\(uuidCol) AS uuid"]
        func add(_ col: String?, as alias: String) {
            if let col { select.append("A.\(col) AS \(alias)") }
        }
        add(dateCol, as: "capture")
        add(widthCol, as: "w")
        add(heightCol, as: "h")
        add(kindCol, as: "kind")
        add(trashCol, as: "trashed")
        add(hiddenCol, as: "hidden")
        add(thumbCol, as: "thumbidx")
        add(dirCol, as: "dir")
        add(nameCol, as: "fname")
        add(durCol, as: "dur")
        add(sharedCol, as: "shared")

        // The extras table holds the import filename and size. Its columns moved
        // between releases too, hence the same treatment.
        var joins = ""
        let extrasCols = db.columnNames(of: "ZADDITIONALASSETATTRIBUTES")
        if !extrasCols.isEmpty {
            func extra(_ candidates: String...) -> String? {
                candidates.first { extrasCols.contains($0) }
            }
            let fk = extra("ZASSET") ?? "ZASSET"
            if let f = extra("ZORIGINALFILENAME") { select.append("X.\(f) AS origname") }
            if let s = extra("ZORIGINALFILESIZE") { select.append("X.\(s) AS origsize") }
            if let t = extra("ZTIMEZONEOFFSET") { select.append("X.\(t) AS tzoffset") }
            if let m = extra("ZMASTERFINGERPRINT", "ZORIGINALSTABLEHASH") {
                select.append("X.\(m) AS masterfp")
            }
            joins += " LEFT JOIN ZADDITIONALASSETATTRIBUTES X ON X.\(fk) = A.Z_PK"
        }

        let sql = """
            SELECT \(select.joined(separator: ", "))
            FROM \(assetTable) A\(joins)
            """

        // Fingerprints live one-to-many in ZINTERNALRESOURCE. Pull them in one pass
        // rather than a query per asset.
        let fingerprints = readFingerprints(db: db)

        var assets: [AssetRecord] = []
        assets.reserveCapacity(12_000)
        var trashed = 0

        try db.query(sql) { row in
            if let t = row["trashed"].intValue, t != 0 { trashed += 1; return }
            guard let uuid = row["uuid"].textValue else { return }
            let pk = row["pk"].intValue ?? -1

            let isVideo = (row["kind"].intValue ?? 0) == 1
            let record = AssetRecord(
                uuid: uuid,
                libraryIdentity: library.identity,
                libraryName: library.displayName,
                captureDate: .fromCoreDataTimestamp(row["capture"].doubleValue),
                timeZoneOffset: row["tzoffset"].intValue.map(Int.init),
                width: Int(row["w"].intValue ?? 0),
                height: Int(row["h"].intValue ?? 0),
                duration: isVideo ? row["dur"].doubleValue : nil,
                originalFilename: row["origname"].textValue ?? row["fname"].textValue,
                originalFileSize: row["origsize"].intValue,
                kind: isVideo ? .video : .photo,
                isHidden: (row["hidden"].intValue ?? 0) != 0,
                isShared: row["shared"].intValue.map { $0 != 0 } ?? false,
                fingerprint: fingerprints[pk] ?? row["masterfp"].textValue,
                placement: .init(
                    directory: row["dir"].textValue,
                    filename: row["fname"].textValue,
                    thumbnailIndex: row["thumbidx"].intValue.map(Int.init)
                )
            )
            assets.append(record)
        }

        return ReadResult(assets: assets, trashed: trashed, sharedColumn: sharedCol)
    }

    /// Apple's content fingerprint per asset. Resource type 0 is the original, which is
    /// the fingerprint worth matching on; anything else is a fallback.
    private func readFingerprints(db: SQLiteRead) -> [Int64: String] {
        let cols = db.columnNames(of: "ZINTERNALRESOURCE")
        guard cols.contains("ZFINGERPRINT") else { return [:] }
        let fk = cols.contains("ZASSET") ? "ZASSET" : "ZASSETFORORIGINALRESOURCE"
        guard cols.contains(fk) else { return [:] }

        let typeCol = cols.contains("ZRESOURCETYPE") ? "ZRESOURCETYPE" : nil
        let order = typeCol.map { " ORDER BY \($0) DESC" } ?? ""

        var out: [Int64: String] = [:]
        // Descending resource type means type 0 (the original) is written last and so
        // wins over derivative fingerprints.
        try? db.query("""
            SELECT \(fk) AS pk, ZFINGERPRINT AS fp FROM ZINTERNALRESOURCE
            WHERE ZFINGERPRINT IS NOT NULL\(order)
            """) { row in
            if let pk = row["pk"].intValue, let fp = row["fp"].textValue {
                out[pk] = fp
            }
        }
        return out
    }
}
