import Foundation
import Observation
import PhotoDiffCore

/// Drives a whole comparison: index the live library, read every old library at once,
/// diff, then recover a picture for each photo that turns out to be missing.
@MainActor
@Observable
final class ScanCoordinator {

    // MARK: Presented state

    enum Phase: Equatable {
        case idle
        case needsPermission
        case permissionDenied
        case permissionLimited
        case indexingCurrentLibrary(done: Int, total: Int)
        case readingLibraries(done: Int, total: Int)
        case comparing
        case recoveringPictures(done: Int, total: Int)
        case finished
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .indexingCurrentLibrary, .readingLibraries, .comparing, .recoveringPictures:
                return true
            default:
                return false
            }
        }

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .needsPermission: return "Needs permission to read your photos"
            case .permissionDenied: return "Permission denied"
            case .permissionLimited:
                return "Only some photos are visible, so the comparison would be wrong"
            case .indexingCurrentLibrary(let d, let t):
                return "Reading your current library — \(d) of \(t)"
            case .readingLibraries(let d, let t):
                return "Opening old libraries — \(d) of \(t)"
            case .comparing: return "Comparing"
            case .recoveringPictures(let d, let t):
                return "Recovering pictures — \(d) of \(t)"
            case .finished: return "Done"
            case .failed(let why): return why
            }
        }
    }

    struct LibraryStatus: Identifiable {
        let id: String
        let name: String
        var schema: String = ""
        var assetCount: Int = 0
        var trashedCount: Int = 0
        var sharedCount: Int = 0
        var missingCount: Int = 0
        var readSeconds: TimeInterval = 0
        var error: String?
        var included = true
        /// Whether this library still has a packed thumbnail cache we are not yet
        /// reading. Recorded so the coverage question can be answered with real numbers.
        var hasPackedThumbnails = false
    }

    struct Item: Identifiable {
        let photo: MissingPhoto
        var picture: PictureStore.Stored?
        var id: String { photo.id }

        var exportName: String {
            let date = photo.representative.captureDate
            let stamp = date.map { Item.stamper.string(from: $0) } ?? "no-date"
            let name = (photo.representative.originalFilename as NSString?)?
                .deletingPathExtension ?? photo.representative.uuid.prefix(8).description
            return "\(stamp)_\(name)"
        }

        static let stamper: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }

    var phase: Phase = .idle
    var libraries: [LibraryStatus] = []
    var items: [Item] = []
    var selection: Set<String> = []
    var summary: DiffSummary?
    var currentLibraryCount = 0
    var timings: [String: TimeInterval] = [:]
    var pictureStoreBytes: Int64 = 0

    /// Photos with no recoverable picture, shown as metadata tiles.
    var withoutPictureCount: Int { items.filter { $0.picture == nil }.count }

    var visibleItems: [Item] {
        let on = Set(libraries.filter(\.included).map(\.id))
        guard on.count != libraries.count else { return items }
        return items.filter { on.contains($0.photo.representative.libraryIdentity) }
    }

    // MARK: Collaborators

    private let current = CurrentLibraryIndex()
    private let store: PictureStore

    /// Handed to grid cells so they can read their own picture off the main thread.
    var pictureStore: PictureStore { store }
    private var bundleURLs: [String: URL] = [:]

    init() {
        do {
            self.store = try PictureStore()
        } catch {
            // A failure here means no scratch space at all; surfaced on first scan.
            self.store = try! PictureStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoDiff-fallback"))
        }
        self.pictureStoreBytes = store.totalBytes()
    }

    // MARK: Permission

    private func apply(_ access: CurrentLibraryIndex.Access) {
        switch access {
        case .granted: phase = .idle
        case .limitedToSomePhotos: phase = .permissionLimited
        case .denied: phase = .permissionDenied
        case .notAsked: phase = .needsPermission
        }
    }

    func checkAccess() { apply(CurrentLibraryIndex.currentAccess()) }

    func requestAccess() async { apply(await CurrentLibraryIndex.requestAccess()) }

    // MARK: The scan

    /// Finds every `.photoslibrary` directly inside a folder.
    static func discoverLibraries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ))?
        .filter { $0.pathExtension == "photoslibrary" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    func scan(bundles: [URL]) async {
        guard !bundles.isEmpty else {
            phase = .failed("No Photos libraries in that folder.")
            return
        }
        let access = CurrentLibraryIndex.currentAccess()
        guard access == .granted else {
            // Scanning under limited access would mark thousands of photos as
            // missing that are sitting in the library already. Refuse instead.
            apply(access)
            return
        }

        items = []
        selection = []
        summary = nil
        timings = [:]
        bundleURLs = [:]
        libraries = bundles.map {
            LibraryStatus(id: $0.path, name: $0.deletingPathExtension().lastPathComponent)
        }

        // 1. The live library, fast keys only.
        phase = .indexingCurrentLibrary(done: 0, total: 0)
        let built = current.buildFastIndex { [weak self] done, total in
            self?.phase = .indexingCurrentLibrary(done: done, total: total)
        }
        var index = built.index
        currentLibraryCount = built.assetCount
        timings["Current library"] = built.buildTime

        // 2. Every old library, concurrently.
        phase = .readingLibraries(done: 0, total: bundles.count)
        let readStarted = Date()
        var outcomes: [LibraryReader.Outcome] = []
        var failures: [(String, String)] = []
        var packed: [String: Bool] = [:]
        var finished = 0

        await withTaskGroup(
            of: (URL, Result<(LibraryReader.Outcome, Bool), Error>).self
        ) { group in
            for bundle in bundles {
                group.addTask {
                    do {
                        let reader = try LibraryReader(bundleURL: bundle)
                        let outcome = try reader.read()
                        // Cheap, and answers whether the packed cache would help here.
                        let hasPacked = (try? PictureExtractor(bundleURL: bundle))?
                            .thumbnailCacheIsAvailable ?? false
                        return (bundle, .success((outcome, hasPacked)))
                    } catch {
                        return (bundle, .failure(error))
                    }
                }
            }
            for await (bundle, result) in group {
                finished += 1
                phase = .readingLibraries(done: finished, total: bundles.count)
                switch result {
                case .success(let (outcome, hasPacked)):
                    outcomes.append(outcome)
                    packed[outcome.libraryIdentity] = hasPacked
                    bundleURLs[outcome.libraryIdentity] = bundle
                case .failure(let error):
                    // One bad library must not stop the rest.
                    failures.append((
                        bundle.path,
                        (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    ))
                }
            }
        }
        timings["Reading libraries"] = Date().timeIntervalSince(readStarted)

        // Re-key the sidebar rows onto the identities we actually read.
        libraries = outcomes
            .sorted { $0.libraryName < $1.libraryName }
            .map { outcome in
                LibraryStatus(
                    id: outcome.libraryIdentity,
                    name: outcome.libraryName,
                    schema: outcome.schema,
                    assetCount: outcome.assets.count,
                    trashedCount: outcome.trashedCount,
                    sharedCount: outcome.sharedCount,
                    readSeconds: outcome.duration,
                    hasPackedThumbnails: packed[outcome.libraryIdentity] ?? false
                )
            }
        + failures.map { path, why in
            LibraryStatus(
                id: path,
                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                error: why,
                included: false
            )
        }

        let allOldAssets = outcomes.flatMap(\.assets)
        guard !allOldAssets.isEmpty else {
            phase = failures.isEmpty
                ? .failed("Those libraries contain no photos.")
                : .failed("None of those libraries could be read.")
            return
        }

        // 3. First pass: the cheap tiers settle most of it.
        phase = .comparing
        let compareStarted = Date()
        let firstPass = DiffEngine.diff(oldAssets: allOldAssets, against: index)

        // 4. Only now pay for filenames, and only near the unexplained photos.
        let unresolvedSeconds = Set(firstPass.missing.compactMap { item -> Int64? in
            guard let date = item.representative.captureDate else { return nil }
            return Int64(date.timeIntervalSinceReferenceDate.rounded())
        })
        let hasUndated = firstPass.missing.contains { $0.representative.captureDate == nil }
        let looked = current.augment(
            &index, nearSeconds: unresolvedSeconds, includeUndated: hasUndated
        )
        timings["Filename lookups"] = Double(looked)

        // 5. Second pass over the narrowed set, with the extra keys in place.
        let secondPass = DiffEngine.diff(oldAssets: allOldAssets, against: index)
        summary = secondPass.summary
        timings["Comparing"] = Date().timeIntervalSince(compareStarted)

        var byLibrary: [String: Int] = [:]
        for photo in secondPass.missing {
            byLibrary[photo.representative.libraryIdentity, default: 0] += 1
        }
        for i in libraries.indices {
            libraries[i].missingCount = byLibrary[libraries[i].id] ?? 0
        }

        items = secondPass.missing.map { Item(photo: $0) }

        // 6. Recover a picture for each one, so the copies can be deleted afterwards.
        await recoverPictures()

        pictureStoreBytes = store.totalBytes()
        phase = .finished
    }

    /// Reads the best surviving picture for every missing photo and keeps it in the
    /// app's own store. Grouped by library so each one is opened once.
    private func recoverPictures() async {
        let total = items.count
        guard total > 0 else { return }
        phase = .recoveringPictures(done: 0, total: total)
        let started = Date()

        // Each photo may exist in several old libraries. Try the best copy first.
        var work: [String: [(itemIndex: Int, asset: AssetRecord)]] = [:]
        for (i, item) in items.enumerated() {
            let ordered = item.photo.copies.sorted {
                ($0.placement.filename != nil ? 1 : 0, $0.originalFileSize ?? 0)
                    > ($1.placement.filename != nil ? 1 : 0, $1.originalFileSize ?? 0)
            }
            for asset in ordered {
                work[asset.libraryIdentity, default: []].append((i, asset))
            }
        }

        let store = self.store
        let urls = self.bundleURLs
        var done = 0

        await withTaskGroup(of: [(Int, PictureStore.Stored)].self) { group in
            for (identity, jobs) in work {
                guard let bundle = urls[identity] else { continue }
                group.addTask {
                    guard let extractor = try? PictureExtractor(bundleURL: bundle) else {
                        return []
                    }
                    var saved: [(Int, PictureStore.Stored)] = []
                    for job in jobs {
                        guard let picture = extractor.extractPicture(for: job.asset) else {
                            continue
                        }
                        if let stored = try? store.save(
                            picture.data,
                            assetID: job.asset.id,
                            kind: picture.kind.rawValue,
                            extension: picture.fileExtension
                        ) {
                            saved.append((job.itemIndex, stored))
                        }
                    }
                    return saved
                }
            }

            for await saved in group {
                for (itemIndex, stored) in saved {
                    guard items.indices.contains(itemIndex) else { continue }
                    // Keep the best version if several libraries yielded one.
                    let existing = items[itemIndex].picture
                    let better = existing.map { old in
                        (PictureKind(rawValue: stored.kind)?.rank ?? 0)
                            > (PictureKind(rawValue: old.kind)?.rank ?? 0)
                    } ?? true
                    if better { items[itemIndex].picture = stored }
                }
                done += saved.count
                phase = .recoveringPictures(done: min(done, total), total: total)
            }
        }
        timings["Recovering pictures"] = Date().timeIntervalSince(started)
    }

    // MARK: Export

    func picture(for item: Item) -> Data? {
        item.picture.flatMap { store.data(for: $0) }
    }

    struct ExportReport {
        var written = 0
        var skippedWithoutPicture = 0
        var byKind: [String: Int] = [:]
        var failures: [String] = []
    }

    func exportSelected(to folder: URL) -> ExportReport {
        var report = ExportReport()
        for item in visibleItems where selection.contains(item.id) {
            guard let picture = item.picture else {
                report.skippedWithoutPicture += 1
                continue
            }
            do {
                try store.export(picture, to: folder, named: item.exportName)
                report.written += 1
                report.byKind[picture.kind, default: 0] += 1
            } catch {
                report.failures.append(item.exportName)
            }
        }
        return report
    }

    func clearPictureStore() {
        try? store.clear()
        for i in items.indices { items[i].picture = nil }
        pictureStoreBytes = store.totalBytes()
    }

    /// What the selection would produce, shown before exporting.
    func selectionBreakdown() -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in visibleItems where selection.contains(item.id) {
            counts[item.picture?.kind ?? "no picture", default: 0] += 1
        }
        return counts
    }
}
