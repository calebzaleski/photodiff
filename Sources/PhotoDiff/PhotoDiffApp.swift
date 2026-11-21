import SwiftUI
import AppKit

@main
struct PhotoDiffApp: App {
    @State private var coordinator = ScanCoordinator()

    var body: some Scene {
        Window("PhotoDiff", id: "main") {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 940, minHeight: 620)
                .task { coordinator.checkAccess() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// A small helper for the open and save panels. `@MainActor` because `NSOpenPanel`
/// is: without it these calls are cross-actor and Swift 6 rightly complains. The app is not sandboxed, so these are
/// ordinary panels; picking a folder is still how the app learns any path at all —
/// nothing is hardcoded and nothing is scanned unasked.
@MainActor
enum Panels {

    static func chooseFolderOfLibraries() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder holding your old Photos libraries"
        panel.message = "Pick the folder that contains the .photoslibrary bundles. "
            + "They are only ever read, never changed."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSingleLibrary() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose one Photos library"
        panel.prompt = "Open"
        // A .photoslibrary is a folder, so it has to be choosable as a directory.
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Where should the photos go?"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
