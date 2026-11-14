import SwiftUI

@main
struct DiskTreeApp: App {
    init() {
        // Headless diagnostic. Launch via `open -n -W --stdout FILE DiskTree.app
        // --args --check-full-disk-access` so TCC evaluates DiskTree itself.
        if CommandLine.arguments.contains("--check-full-disk-access") {
            print(FullDiskAccess.diagnosticReport())
            exit(DiskAccess.status == .granted ? 0 : 1)
        }
        // Headless update check: `… --check-for-updates`
        if CommandLine.arguments.contains("--check-for-updates") {
            let report = UpdateChecker.commandLineReport()
            print(report.text)
            exit(report.ok ? 0 : 1)
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateChecker.checkNow() }
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
