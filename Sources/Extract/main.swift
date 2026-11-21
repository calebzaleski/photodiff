import Foundation
import PhotoDiffCore

// Pulls every photo that still exists at full quality out of a folder of Photos
// libraries, deduplicated, into one plain folder.
//
// Why this is worth doing: a library that ran with iCloud "Optimize Mac Storage" keeps
// only a fraction of its photos as real files, and each library kept a *different*
// fraction. No single one is close to complete, but together they cover far more. This
// walks all of them, picks the best surviving copy of each photo, and writes it out
// once.
//
// Libraries are only ever read — the same `ReadOnlyLibrary` chokepoint the app uses.

struct Options {
    var source: URL
    var destination: URL
    var includeVideo = true
    var dryRun = false
}

func parse() -> Options? {
    var args = Array(CommandLine.arguments.dropFirst())
    var source: URL?, destination: URL?
    var opts = (video: true, dry: false)
    var positional: [String] = []
    while let a = args.first {
        args.removeFirst()
        switch a {
        case "--no-video": opts.video = false
        case "--dry-run": opts.dry = true
        case "-h", "--help": return nil
        default: positional.append(a)
        }
    }
    guard positional.count == 2 else { return nil }
    source = URL(fileURLWithPath: positional[0])
    destination = URL(fileURLWithPath: positional[1])
    return Options(source: source!, destination: destination!,
                   includeVideo: opts.video, dryRun: opts.dry)
}

guard let options = parse() else {
    print("""
        Pull every full-quality photo out of a folder of Photos libraries.

          photodiff-extract <folder-of-libraries> <output-folder> [--no-video] [--dry-run]

        Libraries are only read, never changed. Photos that survive solely as a cached
        thumbnail are reported but not written: there is no full-size file to write.
        """)
    exit(2)
}

let bundles = ((try? FileManager.default.contentsOfDirectory(
    at: options.source, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "photoslibrary" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !bundles.isEmpty else {
    FileHandle.standardError.write(Data("No .photoslibrary bundles in \(options.source.path)\n".utf8))
    exit(1)
}

print("Reading \(bundles.count) libraries…")

var assets: [AssetRecord] = []
var urlForLibrary: [String: URL] = [:]
for bundle in bundles {
    do {
        let outcome = try LibraryReader(bundleURL: bundle).read()
        assets.append(contentsOf: outcome.assets)
        urlForLibrary[outcome.libraryIdentity] = bundle
        print(String(format: "  %-26s %6d photos, %5d videos",
                     (outcome.libraryName as NSString).utf8String!,
                     outcome.photoCount, outcome.videoCount))
    } catch {
        print("  \(bundle.lastPathComponent): skipped — "
              + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
    }
}

// Same deduplication the app uses, against an empty index so nothing is excluded.
//
// Shared-album assets are kept here, unlike in the app. The app leaves them out
// because PhotoKit's view of the current library leaves them out too, so counting them
// as "missing" would be wrong. For recovery the opposite is true: those photos are
// stored full-size under scopes/ and are among the most recoverable things in the
// library. Dropping them lost 1,133 real photographs in one library alone.
let unique = DiffEngine.diff(
    oldAssets: assets, against: MatchIndex(), includeShared: true
).missing
print("\n\(assets.count) records → \(unique.count) unique photos\n")

/// One extractor per library, reused across every photo that comes from it. Opening
/// a library is cheap but not free, and there are thousands of photos per library.
final class ExtractorCache {
    private var cache: [String: PictureExtractor] = [:]
    private let urls: [String: URL]

    init(urls: [String: URL]) { self.urls = urls }

    func extractor(for identity: String) -> PictureExtractor? {
        if let e = cache[identity] { return e }
        guard let url = urls[identity],
              let e = try? PictureExtractor(bundleURL: url) else { return nil }
        cache[identity] = e
        return e
    }
}
let cache = ExtractorCache(urls: urlForLibrary)

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f
}()

var written = 0, skippedThumbnailOnly = 0, failed = 0, skippedVideo = 0
var bytes: Int64 = 0
var usedNames = Set<String>()

for (n, photo) in unique.enumerated() {
    if n % 250 == 0 && n > 0 {
        print(String(format: "  %d/%d  (%.1f GB written)",
                     n, unique.count, Double(bytes) / 1e9))
    }
    let rep = photo.representative
    if rep.kind == .video && !options.includeVideo { skippedVideo += 1; continue }

    // Try every library that has this photo; take the biggest full-size file.
    var best: (source: ByteSource, bytes: Int64, fileExtension: String)?
    for copy in photo.copies.sorted(by: { ($0.originalFileSize ?? 0) > ($1.originalFileSize ?? 0) }) {
        guard let e = cache.extractor(for: copy.libraryIdentity),
              let found = e.fullSizeFile(for: copy) else { continue }
        if let current = best, current.bytes >= found.bytes {
            found.source.close()
        } else {
            best?.source.close()
            best = found
        }
    }

    guard let chosen = best else { skippedThumbnailOnly += 1; continue }

    let date = rep.captureDate.map { stamp.string(from: $0) } ?? "no-date"
    let original = (rep.originalFilename as NSString?)?.deletingPathExtension
        ?? String(rep.uuid.prefix(8))
    var name = "\(date)_\(original).\(chosen.fileExtension)"
    var attempt = 2
    while usedNames.contains(name.lowercased()) {
        name = "\(date)_\(original) (\(attempt)).\(chosen.fileExtension)"
        attempt += 1
    }
    usedNames.insert(name.lowercased())

    if options.dryRun {
        chosen.source.close()
        written += 1; bytes += chosen.bytes
        continue
    }
    do {
        bytes += try StreamCopier.copy(
            chosen.source, to: options.destination.appendingPathComponent(name))
        written += 1
    } catch {
        failed += 1
    }
}

func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

print("""

    \(options.dryRun ? "Would write" : "Wrote") \(written) files, \(gb(bytes))
      thumbnail only, nothing to write : \(skippedThumbnailOnly)
      videos skipped                   : \(skippedVideo)
      failed                           : \(failed)
      destination                      : \(options.destination.path)
    """)
