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
