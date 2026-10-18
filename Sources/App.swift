import SwiftUI

@main
struct DiskTreeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await WeeklyScanScheduler.refreshRegistrationIfNeeded() }
                // Backs up the history and builds any missing snapshot
                // summaries in the background, so the first History sheet
                // after an update opens without waiting for the migration.
                .task { await HistorySummaryStore.shared.migrateMissingSummaries() }
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
