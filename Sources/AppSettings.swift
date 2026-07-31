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
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding(.vertical, 8)
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
}
