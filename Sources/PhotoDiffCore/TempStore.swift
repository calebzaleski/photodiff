import Foundation

/// Writes bytes to scratch space the app owns. This is where every write in the
/// project happens, and it is deliberately unable to name a library: it accepts only
/// a `ByteSource`, never a bundle path, so no edit here can reach a Photos library.
public final class TempStore {

    public enum Failure: Error, LocalizedError {
        case cannotCreate(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "Could not create scratch space at \(p)"
            case .writeFailed(let p): return "Could not write \(p)"
            }
        }
    }

    public let directory: URL
    private let fm = FileManager.default

    /// Creates a private scratch directory that is removed when this object dies.
    public init(label: String) throws {
        let base = fm.temporaryDirectory
            .appendingPathComponent("PhotoDiff", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreate(base.path)
        }
        self.directory = base
    }

    /// Streams a source into a file here, 4MB at a time, so a 140MB database never
    /// sits in memory whole.
    @discardableResult
    public func absorb(_ source: ByteSource, as name: String) throws -> URL {
        let target = directory.appendingPathComponent(name)
        defer { source.close() }

        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw Failure.cannotCreate(target.path)
        }
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        while true {
            let chunk = try source.read(upTo: 4 << 20)
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
        return target
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func discard() {
        try? fm.removeItem(at: directory)
    }

    deinit { discard() }
}

/// Writes a byte stream to a chosen file. Like `TempStore`, it is deliberately unable
/// to name a Photos library — it takes only a `ByteSource` — so no edit here can reach
/// one. Streaming matters: the originals include videos well over a gigabyte, and
/// reading those into memory first is not an option.
public enum StreamCopier {

    public enum Failure: Error, LocalizedError {
        case cannotCreate(String)
        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "Could not create \(p)"
            }
        }
    }

    /// Copies `source` to `target`, 4MB at a time. Returns the bytes written.
    @discardableResult
    public static func copy(_ source: ByteSource, to target: URL) throws -> Int64 {
        defer { source.close() }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw Failure.cannotCreate(target.path)
        }
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        var written: Int64 = 0
        while true {
            let chunk = try source.read(upTo: 4 << 20)
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        return written
    }
}
