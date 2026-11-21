import Foundation
import Testing
@testable import PhotoDiffCore

/// These two tests are the read-only guarantee. If either fails, the build has broken
/// its main promise and must not ship.
@Suite("Read-only guarantee")
struct ReadOnlyGuaranteeTests {

    // MARK: - Enforcement point 5: the source tree police

    /// Writing APIs must not appear in any file that can name a Photos library. A
    /// future edit that adds one fails here instead of on someone's photos.
    @Test("No write API in any file that can reach a library")
    func noWriteAPIsNearLibraryPaths() throws {
        let forbidden = [
            "createFile", "removeItem", "write(to:", "writeData", "O_WRONLY", "O_RDWR",
            "O_CREAT", "O_TRUNC", "moveItem", "copyItem", "replaceItem",
            "FileHandle(forWritingTo", "FileHandle(forUpdating", "createDirectory",
            "setAttributes", "performChanges", "unlink(", "truncate(", "rename(",
        ]
        // A file is "near a library" if it can name one or hold one.
        let libraryMarkers = ["photoslibrary", "bundleURL"]

        var offences: [String] = []
        for file in try Self.sourceFiles() {
            let text = try Self.code(in: file)
            guard libraryMarkers.contains(where: text.contains) else { continue }
            for api in forbidden where text.contains(api) {
                offences.append("\(file.lastPathComponent) uses \(api)")
            }
        }

        #expect(
            offences.isEmpty,
            """
            A file that can name a Photos library also contains a write API. \
            Move the write into TempStore or the thumbnail cache, which cannot name a \
            library. Offences: \(offences.joined(separator: "; "))
            """
        )
    }

    /// The app must never ask PhotoKit to change anything.
    @Test("PhotoKit is never asked to modify the library")
    func noPhotoKitWrites() throws {
        let forbidden = [
            "performChanges", "PHAssetChangeRequest", "PHAssetCollectionChangeRequest",
            "PHAssetCreationRequest", "deleteAssets",
        ]
        var offences: [String] = []
        for file in try Self.sourceFiles() {
            let text = try Self.code(in: file)
            for api in forbidden where text.contains(api) {
                offences.append("\(file.lastPathComponent) uses \(api)")
            }
        }
        #expect(offences.isEmpty, "PhotoKit write API found: \(offences.joined(separator: "; "))")
    }

    /// SQLite must only ever be opened read-only.
    @Test("SQLite is opened read-only and nothing else")
    func sqliteIsReadOnly() throws {
        let text = try Self.code(
            in: Self.sourceRoot().appendingPathComponent("PhotoDiffCore/SQLiteRead.swift")
        )
        #expect(text.contains("SQLITE_OPEN_READONLY"))
        #expect(!text.contains("SQLITE_OPEN_READWRITE"))
        #expect(!text.contains("SQLITE_OPEN_CREATE"))
        #expect(!text.contains("sqlite3_exec"))
    }

    // MARK: - Enforcement point 4: the tripwire, tested against a real bundle

    /// Builds a fake library, takes a byte-level fingerprint of it, runs a full read
    /// over it, and asserts the fingerprint is identical afterwards.
    @Test("A full read leaves a library byte-for-byte identical")
    func readingChangesNothing() throws {
        let fixture = try FakeLibrary.make(assetCount: 25)
        defer { fixture.cleanUp() }

        let before = try Self.fingerprint(of: fixture.bundleURL)

        let reader = try LibraryReader(bundleURL: fixture.bundleURL)
        let outcome = try reader.read()
        #expect(outcome.assets.count == 25)

        let after = try Self.fingerprint(of: fixture.bundleURL)
        let changed = before.keys.filter { before[$0] != after[$0] }
        let appeared = after.keys.filter { before[$0] == nil }
        let vanished = before.keys.filter { after[$0] == nil }

        #expect(changed.isEmpty, "contents changed: \(changed.sorted())")
        #expect(appeared.isEmpty, "files appeared: \(appeared.sorted())")
        #expect(vanished.isEmpty, "files vanished: \(vanished.sorted())")
    }

    /// The tripwire itself must actually fire when something does change, or it is
    /// decoration rather than a safeguard.
    @Test("The tripwire catches a change it is meant to catch")
    func tripwireFires() throws {
        let fixture = try FakeLibrary.make(assetCount: 3)
        defer { fixture.cleanUp() }

        let library = try ReadOnlyLibrary(bundleURL: fixture.bundleURL)
        let before = library.snapshot()
        #expect(before.fileCount > 0)

        // Nothing has changed yet, so this must pass.
        try library.verifyUnchanged(since: before)

        // Now change something behind its back, the way a bug would.
        try fixture.tamper()

        #expect(throws: ReadOnlyLibrary.Failure.self) {
            try library.verifyUnchanged(since: before)
        }
    }

    @Test("A path with .. cannot escape the bundle")
    func pathEscapeIsRefused() throws {
        let fixture = try FakeLibrary.make(assetCount: 1)
        defer { fixture.cleanUp() }
        let library = try ReadOnlyLibrary(bundleURL: fixture.bundleURL)

        #expect(throws: ReadOnlyLibrary.Failure.self) {
            _ = try library.open("../../../etc/passwd")
        }
        #expect(library.exists("../../../etc/passwd") == false)
    }

    // MARK: - Helpers

    static func sourceRoot() -> URL {
        // Tests/PhotoDiffCoreTests/thisFile.swift -> repo/Sources
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhotoDiffCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
    }

    /// A file's source with comments and string literals removed, so the scan reads
    /// what the code actually does and not what a comment says about it. Without this,
    /// documenting "there is no `createFile` here" would itself fail the test.
    static func code(in file: URL) throws -> String {
        let raw = try String(contentsOf: file, encoding: .utf8)
        var out = ""
        var i = raw.startIndex
        var depth = 0           // nesting level of /* */
        var inLine = false
        var inString = false

        while i < raw.endIndex {
            let c = raw[i]
            let next = raw.index(after: i) < raw.endIndex ? raw[raw.index(after: i)] : "\0"

            if depth > 0 {
                if c == "*" && next == "/" { depth -= 1; i = raw.index(i, offsetBy: 2); continue }
                if c == "/" && next == "*" { depth += 1; i = raw.index(i, offsetBy: 2); continue }
            } else if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inString {
                if c == "\\" { i = raw.index(i, offsetBy: min(2, raw.distance(from: i, to: raw.endIndex))); continue }
                if c == "\"" { inString = false }
            } else {
                if c == "/" && next == "/" { inLine = true; i = raw.index(i, offsetBy: 2); continue }
                if c == "/" && next == "*" { depth = 1; i = raw.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = true; i = raw.index(after: i); continue }
                out.append(c)
            }
            i = raw.index(after: i)
        }
        return out
    }

    static func sourceFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot(), includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// SHA-256 of every file in a directory tree, keyed by relative path.
    static func fingerprint(of root: URL) throws -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        let prefix = root.path.count + 1
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return out }

        for case let url as URL in walker {
            var st = stat()
            guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let data = try Data(contentsOf: url)
            out[String(url.path.dropFirst(prefix))] = Self.sha256(data)
        }
        return out
    }

    static func sha256(_ data: Data) -> String {
        // Avoid a CryptoKit import in tests; a size + simple digest is enough to catch
        // any byte-level change in a fixture this small.
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return "\(data.count):\(hash)"
    }
}
