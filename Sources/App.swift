import SwiftUI

@main
struct DiskTreeApp: App {
    init() {
        // Headless diagnostic: `DiskTree.app/Contents/MacOS/DiskTree --check-full-disk-access`
        if CommandLine.arguments.contains("--check-full-disk-access") {
            print(FullDiskAccess.diagnosticReport())
            exit(DiskAccess.status == .granted ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await WeeklyScanScheduler.refreshRegistrationIfNeeded() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
