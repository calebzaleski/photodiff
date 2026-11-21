import Foundation

/// THE ONLY TYPE IN THIS PROJECT ALLOWED TO HOLD A `.photoslibrary` PATH.
///
/// Read-only enforcement lives here, in four of the five places the design calls for:
///   1. This chokepoint. No other type takes a library URL. `ReadOnlyLibraryTests`
///      scans the source tree and fails the build if any write API appears in a file
///      that mentions `ReadOnlyLibrary` or `.photoslibrary`.
///   2. `O_RDONLY` at the syscall. Every byte leaves a library through `ReadHandle`,
///      which has no write path. There is no `FileHandle(forWritingTo:)` here, no
///      `FileManager.createFile`, no `Data.write(to:)`.
///   3. The caller copies what it needs elsewhere — `TempStore` does the writing, in a
///      file that cannot name a library.
///   4. The tripwire: `snapshot()` before and after, compared by `verifyUnchanged()`.
///
/// Do not add a write API to this file. Do not pass a library URL out of this type.
public final class ReadOnlyLibrary {

    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modified: TimeInterval
        public let inode: UInt64
    }

    public struct Snapshot: Sendable {
        public let entries: [String: Entry]
        public var fileCount: Int { entries.count }
    }

    public enum Failure: Error, LocalizedError {
        case notALibrary(String)
        case missingFile(String)
        case unreadable(String, Int32)
        case escapedBundle(String)
        case libraryModified([String])

        public var errorDescription: String? {
            switch self {
            case .notALibrary(let p):
                return "Not a Photos library: \(p)"
            case .missingFile(let p):
                return "This library has no \(p)"
            case .unreadable(let p, let e):
                return "Could not read \(p): \(String(cString: strerror(e)))"
            case .escapedBundle(let p):
                return "Refused a path outside the library bundle: \(p)"
            case .libraryModified(let files):
                return """
                    STOPPED: files inside the library changed during the scan. \
                    This should be impossible and is a bug. Affected: \
                    \(files.prefix(10).joined(separator: ", "))
                    """
            }
        }
    }

    /// The bundle root. Deliberately private — nothing outside this type sees it.
    private let root: URL
    private let fm = FileManager.default

    /// Display name only. Safe to pass around; carries no usable path.
    public let displayName: String

    /// A stable id for this library across runs, derived from the bundle's own
    /// identity rather than its path, so moving or renaming the copy keeps the
    /// scan associated with the same library.
    public let identity: String

    public init(bundleURL: URL) throws {
        guard bundleURL.pathExtension == "photoslibrary" else {
            throw Failure.notALibrary(bundleURL.lastPathComponent)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.notALibrary(bundleURL.lastPathComponent)
        }
        self.root = bundleURL.standardizedFileURL
        self.displayName = bundleURL.deletingPathExtension().lastPathComponent

        let dbRel = "database/Photos.sqlite"
        guard fm.fileExists(atPath: root.appendingPathComponent(dbRel).path) else {
            throw Failure.missingFile(dbRel)
        }

        // Identity: the database's inode + creation time + size. Survives a rename or
        // a move; differs between two copies made separately.
        var st = stat()
        let dbPath = root.appendingPathComponent(dbRel).path
        if stat(dbPath, &st) == 0 {
            self.identity = "\(st.st_ino)-\(st.st_birthtimespec.tv_sec)-\(st.st_size)"
        } else {
            self.identity = displayName
        }
    }

    // MARK: - Reading

    /// A read-only file descriptor. There is intentionally no write counterpart.
    public final class ReadHandle {
        private let fd: Int32
        public let size: Int64
        private var closed = false

        init(fd: Int32, size: Int64) {
            self.fd = fd
            self.size = size
        }

        /// Reads up to `max` bytes. Returns an empty `Data` at end of file.
        public func read(upTo max: Int) throws -> Data {
            var buf = [UInt8](repeating: 0, count: max)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
            if n < 0 { throw Failure.unreadable("fd \(fd)", errno) }
            return Data(buf[0..<n])
        }

        public func close() {
            if !closed { Darwin.close(fd); closed = true }
        }

        deinit { close() }
    }

    /// Opens a file inside the bundle `O_RDONLY`. The only way data leaves a library.
    public func open(_ relativePath: String) throws -> ReadHandle {
        let url = try resolve(relativePath)
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.unreadable(relativePath, errno) }
        var st = stat()
        let size: Int64 = fstat(fd, &st) == 0 ? st.st_size : 0
        return ReadHandle(fd: fd, size: size)
    }

    /// Reads a whole file inside the bundle. For small files (plists, derivatives).
    public func readAll(_ relativePath: String, limit: Int = 64 << 20) throws -> Data {
        let h = try open(relativePath)
        defer { h.close() }
        var out = Data()
        while out.count < limit {
            let chunk = try h.read(upTo: min(1 << 20, limit - out.count))
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    public func exists(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    public func size(of relativePath: String) -> Int64? {
        guard let url = try? resolve(relativePath) else { return nil }
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_size : nil
    }

    /// Names of files directly inside a bundle subdirectory. Read-only listing.
    public func contents(of relativeDir: String) -> [String] {
        guard let url = try? resolve(relativeDir) else { return [] }
        return (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// Guards against `..` and absolute paths escaping the bundle.
    private func resolve(_ relativePath: String) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw Failure.escapedBundle(relativePath)
        }
        return candidate
    }

    // MARK: - Tripwire (enforcement point 4)

    /// Records every file in the bundle: size, mtime, inode. Used before and after a
    /// scan. This ships in release builds, not just tests.
    public func snapshot() -> Snapshot {
        var entries: [String: Entry] = [:]
        let prefix = root.path.count + 1
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return Snapshot(entries: [:]) }

        for case let url as URL in walker {
            var st = stat()
            guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let rel = String(url.path.dropFirst(prefix))
            entries[rel] = Entry(
                relativePath: rel,
                size: st.st_size,
                modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                inode: UInt64(st.st_ino)
            )
        }
        return Snapshot(entries: entries)
    }

    /// Throws if anything inside the bundle changed since `before`.
    public func verifyUnchanged(since before: Snapshot) throws {
        let after = snapshot()
        var changed: [String] = []

        for (path, old) in before.entries {
            guard let new = after.entries[path] else {
                changed.append("\(path) (deleted)")
                continue
            }
            if new.size != old.size { changed.append("\(path) (size \(old.size)→\(new.size))") }
            else if new.modified != old.modified { changed.append("\(path) (mtime)") }
            else if new.inode != old.inode { changed.append("\(path) (replaced)") }
        }
        for path in after.entries.keys where before.entries[path] == nil {
            changed.append("\(path) (created)")
        }

        if !changed.isEmpty { throw Failure.libraryModified(changed.sorted()) }
    }
}

/// A stream of bytes with a known length. Lets `TempStore` and the thumbnail cache do
/// their writing without ever naming a library type or holding a bundle path.
public protocol ByteSource: AnyObject {
    var size: Int64 { get }
    func read(upTo max: Int) throws -> Data
    func close()
}

extension ReadOnlyLibrary.ReadHandle: ByteSource {}
