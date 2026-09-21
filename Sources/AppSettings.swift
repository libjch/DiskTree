import SwiftUI

enum AppSettings {
    static let treemapDepthKey = "treemapDepth"
    static let historyDepthKey = "historyDepth"

    static let defaultTreemapDepth = 5
    static let defaultHistoryDepth = 2

    static let treemapDepthRange = 1...8
    static let historyDepthRange = 1...5
}

struct SettingsView: View {
    @AppStorage(AppSettings.treemapDepthKey)
    private var treemapDepth = AppSettings.defaultTreemapDepth
    @AppStorage(AppSettings.historyDepthKey)
    private var historyDepth = AppSettings.defaultHistoryDepth
    @StateObject private var weeklyScheduler = WeeklyScanScheduler()

    var body: some View {
        Form {
            Section("Treemap") {
                Stepper(value: $treemapDepth, in: AppSettings.treemapDepthRange) {
                    settingLabel("Nested layers", value: treemapDepth)
                }
                Text("More layers reveal deeper folders, but very small tiles are still kept readable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper(value: $historyDepth, in: AppSettings.historyDepthRange) {
                    settingLabel("Folder layers", value: historyDepth)
                }
                Text("Controls how many levels below the selected folder are combined into the history chart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automatic scanning") {
                Toggle("Scan the startup disk weekly", isOn: Binding(
                    get: { weeklyScheduler.isEnabled },
                    set: { weeklyScheduler.setEnabled($0) }
                ))
                Text("Runs every Monday at 08:00. External disks are excluded. If the Mac is asleep, macOS starts the scan after it wakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: weeklyScheduler.statusMessage)
                    .font(.caption)

                if weeklyScheduler.requiresApproval {
                    Button("Open Background Items Settings…") {
                        weeklyScheduler.openBackgroundItemsSettings()
                    }
                }

                if let lastRun = weeklyScheduler.lastRun {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last automatic scan")
                            .font(.caption.bold())
                        Text(lastRunSummary(lastRun))
                            .font(.caption)
                            .foregroundStyle(lastRun.outcome == .failed ? .red : .secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding(.vertical, 8)
        .onAppear { weeklyScheduler.refresh() }
    }

    private func settingLabel(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func lastRunSummary(_ status: ScheduledScanStatus) -> String {
        let date = (status.finishedAt ?? status.startedAt).formatted(
            date: .abbreviated, time: .shortened
        )
        switch status.outcome {
        case .running:
            return "Started \(date) — in progress"
        case .succeeded:
            return "\(date) — \(status.message)"
        case .failed:
            return "\(date) — failed: \(status.message)"
        }
    }
}
