import SwiftUI

@main
struct DiskTreeApp: App {
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
