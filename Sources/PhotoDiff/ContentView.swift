import SwiftUI
import PhotoDiffCore

struct ContentView: View {
    @Bindable var coordinator: ScanCoordinator
    @State private var detail: ScanCoordinator.Item?
    @State private var exportReport: ScanCoordinator.ExportReport?

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(coordinator: coordinator)
                .navigationSplitViewColumnWidth(min: 260, ideal: 290)
        } detail: {
            main
        }
        .toolbar { toolbarContent }
        .sheet(item: $detail) { item in
            PhotoDetail(item: item, coordinator: coordinator) { detail = nil }
        }
        .alert("Export finished", isPresented: .constant(exportReport != nil)) {
            Button("OK") { exportReport = nil }
        } message: {
            if let r = exportReport { Text(Self.describe(r)) }
        }
    }

    @ViewBuilder
    private var main: some View {
        switch coordinator.phase {
        case .needsPermission:
            PermissionGate(coordinator: coordinator, denied: false)
        case .permissionDenied:
            PermissionGate(coordinator: coordinator, denied: true)
        case .permissionLimited:
            Notice(
                icon: "exclamationmark.triangle",
                title: "PhotoDiff can only see some of your photos",
                detail: """
                    macOS gave this app a hand-picked selection rather than your whole                     library. Every photo outside that selection would be reported as                     missing, which would be badly wrong, so the scan has stopped.

                    Open System Settings › Privacy & Security › Photos, find PhotoDiff,                     and change it to Full Access. Then scan again.
                    """
            )
        case .idle where coordinator.items.isEmpty:
            EmptyState(coordinator: coordinator)
        case .failed(let why):
            Notice(
                icon: "exclamationmark.triangle",
                title: "That didn't work",
                detail: why
            )
        default:
            if coordinator.phase.isBusy {
                Progressing(coordinator: coordinator)
            } else {
                MissingGrid(coordinator: coordinator) { detail = $0 }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if let folder = Panels.chooseFolderOfLibraries() {
                    let bundles = ScanCoordinator.discoverLibraries(in: folder)
                    Task { await coordinator.scan(bundles: bundles) }
                }
            } label: {
                Label("Open Folder of Libraries", systemImage: "folder")
            }
            .disabled(coordinator.phase.isBusy)

            Button {
                if let bundle = Panels.chooseSingleLibrary() {
                    Task { await coordinator.scan(bundles: [bundle]) }
                }
            } label: {
                Label("Add One Library", systemImage: "photo.stack")
            }
            .disabled(coordinator.phase.isBusy)

            Spacer()

            if !coordinator.selection.isEmpty {
                Text("\(coordinator.selection.count) selected")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Button {
                if let folder = Panels.chooseExportFolder() {
                    exportReport = coordinator.exportSelected(to: folder)
                }
            } label: {
                Label("Export Selected", systemImage: "square.and.arrow.up")
            }
            .disabled(coordinator.selection.isEmpty || coordinator.phase.isBusy)
        }
    }

    static func describe(_ r: ScanCoordinator.ExportReport) -> String {
        var lines = ["Copied \(r.written) \(r.written == 1 ? "file" : "files")."]
        if !r.byKind.isEmpty {
            let parts = r.byKind.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            lines.append(parts.joined(separator: ", ") + ".")
        }
        if r.skippedWithoutPicture > 0 {
            lines.append("\(r.skippedWithoutPicture) had no recoverable picture and were skipped.")
        }
        if !r.failures.isEmpty {
            lines.append("Could not write: \(r.failures.prefix(5).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Bindable var coordinator: ScanCoordinator

    var body: some View {
        List {
            if coordinator.currentLibraryCount > 0 {
                Section("Your current library") {
                    LabeledContent("Photos") {
                        Text("\(coordinator.currentPhotoCount)").monospacedDigit()
                    }
                    LabeledContent("Videos") {
                        Text("\(coordinator.currentVideoCount)").monospacedDigit()
                    }
                    LabeledContent("Total") {
                        Text("\(coordinator.currentLibraryCount)").monospacedDigit().bold()
                    }
                    Text("Compare these with what Photos shows at the bottom of its Library view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !coordinator.libraries.isEmpty {
                Section("Old libraries (\(coordinator.libraries.count))") {
                    ForEach($coordinator.libraries) { $library in
                        LibraryRow(library: $library)
                    }
                }
            }

            if let summary = coordinator.summary {
                Section("Result") {
                    LabeledContent("Missing photos") {
                        Text("\(coordinator.missingPhotoCount)").monospacedDigit().bold()
                    }
                    LabeledContent("Missing videos") {
                        Text("\(coordinator.missingVideoCount)").monospacedDigit().bold()
                    }
                    LabeledContent("Already in yours") {
                        Text("\(summary.presentCount)").monospacedDigit()
                    }
                    LabeledContent("Duplicates folded") {
                        Text("\(summary.duplicateCopiesFolded)").monospacedDigit()
                    }
                    if summary.sharedSkipped > 0 {
                        LabeledContent("Shared albums skipped") {
                            Text("\(summary.sharedSkipped)").monospacedDigit()
                        }
                    }
                    if coordinator.withoutPictureCount > 0 {
                        LabeledContent("No picture recovered") {
                            Text("\(coordinator.withoutPictureCount)").monospacedDigit()
                        }
                        .foregroundStyle(.orange)
                    }
                }

                Section("How each match was decided") {
                    ForEach(
                        summary.byTier.sorted { $0.key.rawValue < $1.key.rawValue },
                        id: \.key
                    ) { tier, count in
                        LabeledContent(tier.description) {
                            Text("\(count)").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }

            if coordinator.pictureStoreBytes > 0 {
                Section("Recovered pictures") {
                    LabeledContent("Held on disk") {
                        Text(ByteCountFormatter.string(
                            fromByteCount: coordinator.pictureStoreBytes,
                            countStyle: .file
                        ))
                    }
                    Text("Kept so you can delete the library copies and still export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear", role: .destructive) {
                        coordinator.clearPictureStore()
                    }
                    .controlSize(.small)
                }
            }

            if !coordinator.timings.isEmpty {
                Section("Timing") {
                    ForEach(coordinator.timings.sorted { $0.key < $1.key }, id: \.key) { k, v in
                        LabeledContent(k) {
                            Text(k == "Filename lookups"
                                 ? "\(Int(v))"
                                 : String(format: "%.1fs", v))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct LibraryRow: View {
    @Binding var library: ScanCoordinator.LibraryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if library.error == nil {
                    Toggle(isOn: $library.included) { Text(library.name).lineLimit(1) }
                        .toggleStyle(.checkbox)
                } else {
                    Label(library.name, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                if library.missingCount > 0 {
                    Text("\(library.missingCount)")
                        .monospacedDigit()
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.tint.opacity(0.18)))
                }
            }

            if let error = library.error {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts = ["\(library.photoCount) photos", "\(library.videoCount) videos"]
        if library.trashedCount > 0 { parts.append("\(library.trashedCount) in trash") }
        if library.sharedCount > 0 { parts.append("\(library.sharedCount) shared") }
        parts.append(library.schema == "ZASSET" ? "newer format" : "older format")
        return parts.joined(separator: " · ")
    }
}

// MARK: - States

private struct PermissionGate: View {
    @Bindable var coordinator: ScanCoordinator
    let denied: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("PhotoDiff needs to read your current library")
                .font(.title3.weight(.semibold))
            Text("""
                To work out what's missing, it has to see what you already have. \
                It reads your library through Apple's Photos API and never changes \
                anything in it.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if denied {
                Text("Permission was declined. You can change it in System Settings › Privacy & Security › Photos.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Button("Allow Access") {
                    Task { await coordinator.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyState: View {
    @Bindable var coordinator: ScanCoordinator

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.questionmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open your old libraries")
                .font(.title3.weight(.semibold))
            Text("""
                Copy the old .photoslibrary bundles somewhere on this Mac, then pick \
                the folder holding them. Every one is opened at once and compared \
                against your current library.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            Button("Open Folder of Libraries…") {
                if let folder = Panels.chooseFolderOfLibraries() {
                    let bundles = ScanCoordinator.discoverLibraries(in: folder)
                    Task { await coordinator.scan(bundles: bundles) }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Label(
                "Libraries are only ever read. Nothing inside one is written, edited or deleted.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Progressing: View {
    @Bindable var coordinator: ScanCoordinator

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            Text(coordinator.phase.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fraction: Double? {
        switch coordinator.phase {
        case .readingLibraries(let d, let t), .recoveringPictures(let d, let t),
             .indexingCurrentLibrary(let d, let t):
            return t > 0 ? Double(d) / Double(t) : nil
        default:
            return nil
        }
    }
}

private struct Notice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.orange)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
