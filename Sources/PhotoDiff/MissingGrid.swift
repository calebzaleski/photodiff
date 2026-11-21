import SwiftUI
import PhotoDiffCore

/// The grid of photos the current library doesn't have.
struct MissingGrid: View {
    @Bindable var coordinator: ScanCoordinator
    let onOpen: (ScanCoordinator.Item) -> Void

    @State private var sort: Sort = .date
    @State private var onlyWithPictures = false

    enum Sort: String, CaseIterable, Identifiable {
        case date = "Date taken"
        case library = "Library"
        var id: String { rawValue }
    }

    private var shown: [ScanCoordinator.Item] {
        var list = coordinator.visibleItems
        if onlyWithPictures { list = list.filter { $0.picture != nil } }
        switch sort {
        case .date:
            return list.sorted {
                ($0.photo.representative.captureDate ?? .distantPast)
                    > ($1.photo.representative.captureDate ?? .distantPast)
            }
        case .library:
            return list.sorted {
                ($0.photo.representative.libraryName, $0.id)
                    < ($1.photo.representative.libraryName, $1.id)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if shown.isEmpty {
                ContentUnavailableView(
                    "Nothing missing",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Every photo in the libraries you've ticked is already in your current library."
                    )
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(shown) { item in
                            PhotoCell(
                                item: item,
                                isSelected: coordinator.selection.contains(item.id),
                                store: coordinator.pictureStore,
                                onToggle: { toggle(item) },
                                onOpen: { onOpen(item) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("\(shown.count) missing")
                .font(.headline)
                .monospacedDigit()

            if coordinator.withoutPictureCount > 0 {
                Toggle("Only ones with a picture", isOn: $onlyWithPictures)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            Spacer()

            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Button(allShownSelected ? "Deselect All" : "Select All") {
                if allShownSelected {
                    shown.forEach { coordinator.selection.remove($0.id) }
                } else {
                    shown.forEach { coordinator.selection.insert($0.id) }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var allShownSelected: Bool {
        !shown.isEmpty && shown.allSatisfy { coordinator.selection.contains($0.id) }
    }

    private func toggle(_ item: ScanCoordinator.Item) {
        if coordinator.selection.contains(item.id) {
            coordinator.selection.remove(item.id)
        } else {
            coordinator.selection.insert(item.id)
        }
    }
}

// MARK: - One cell

private struct PhotoCell: View {
    let item: ScanCoordinator.Item
    let isSelected: Bool
    let store: PictureStore
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                thumbnail
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                    .onTapGesture(count: 2, perform: onOpen)
                    .onTapGesture(perform: onToggle)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.85))
                    .shadow(radius: 1.5)
                    .padding(6)
                    .onTapGesture(perform: onToggle)
            }

            Text(dateLine)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            HStack(spacing: 4) {
                Badge(
                    text: item.photo.representative.libraryName,
                    tone: .neutral
                )
                if let kind = item.picture?.kind {
                    Badge(text: kind, tone: kind == "original" ? .good : .soft)
                } else {
                    Badge(text: "no picture", tone: .warn)
                }
                if item.photo.otherLibraryCount > 0 {
                    Badge(text: "+\(item.photo.otherLibraryCount)", tone: .soft)
                }
            }
        }
        .task {
            guard !tried, let stored = item.picture else { return }
            tried = true
            image = await ThumbnailCache.shared.load(
                id: item.id, store: store, stored: stored
            )
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                VStack(spacing: 4) {
                    Image(systemName: item.picture == nil
                          ? "photo.badge.exclamationmark" : "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    if item.picture == nil {
                        Text(metaTile)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                    }
                }
            }
        }
    }

    private var dateLine: String {
        guard let date = item.photo.representative.captureDate else { return "No date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var metaTile: String {
        let a = item.photo.representative
        let dims = a.width > 0 ? "\(a.width)×\(a.height)" : "size unknown"
        return "\(a.originalFilename ?? "unnamed")\n\(dims)"
    }
}

struct Badge: View {
    enum Tone { case neutral, good, soft, warn }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(fill)
            )
            .foregroundStyle(stroke)
    }

    private var fill: Color {
        switch tone {
        case .neutral: return .primary.opacity(0.08)
        case .good: return .green.opacity(0.16)
        case .soft: return .blue.opacity(0.13)
        case .warn: return .orange.opacity(0.18)
        }
    }

    private var stroke: Color {
        switch tone {
        case .neutral: return .secondary
        case .good: return .green
        case .soft: return .blue
        case .warn: return .orange
        }
    }
}

// MARK: - Detail

struct PhotoDetail: View {
    let item: ScanCoordinator.Item
    @Bindable var coordinator: ScanCoordinator
    let onClose: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.04)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No picture survived in any of these libraries.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 340)

            Divider()

            Form {
                let a = item.photo.representative
                LabeledContent("Taken") {
                    Text(a.captureDate?.formatted(date: .complete, time: .standard) ?? "Unknown")
                }
                LabeledContent("File name") { Text(a.originalFilename ?? "Unknown") }
                if a.width > 0 {
                    LabeledContent("Dimensions") { Text("\(a.width) × \(a.height)") }
                }
                if let duration = a.duration {
                    LabeledContent("Length") { Text(String(format: "%.1f seconds", duration)) }
                }
                if let bytes = a.originalFileSize, bytes > 0 {
                    LabeledContent("Original size") {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                }
                LabeledContent("Found in") {
                    Text(item.photo.libraryNames.joined(separator: ", "))
                }
                LabeledContent("Recovered as") {
                    Text(item.picture?.kind ?? "nothing recoverable")
                }
                if a.fingerprint != nil {
                    LabeledContent("Fingerprint") { Text("recorded") }
                }
            }
            .formStyle(.grouped)
            .frame(height: 230)

            Divider()
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.escape)
                Spacer()
                Button(
                    coordinator.selection.contains(item.id) ? "Deselect" : "Select"
                ) {
                    if coordinator.selection.contains(item.id) {
                        coordinator.selection.remove(item.id)
                    } else {
                        coordinator.selection.insert(item.id)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 640, height: 680)
        .task {
            guard let stored = item.picture else { return }
            let url = coordinator.pictureStore.url(for: stored)
            // Read off the main thread, but build the NSImage here: NSImage is not
            // Sendable and must not cross a task boundary.
            let bytes = await Task.detached { ThumbnailCache.fullSizeData(from: url) }.value
            image = bytes.flatMap { NSImage(data: $0) }
        }
    }
}
