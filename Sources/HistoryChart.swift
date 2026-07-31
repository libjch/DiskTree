import SwiftUI
import Charts

/// Identifies which folder's history to show — used with `.sheet(item:)` so the
/// value is passed straight into the sheet (avoiding stale `@State` reads).
struct HistoryRequest: Identifiable {
    let id = UUID()
    let rootPath: String     // the scanned root the history is indexed under
    let folderPath: String   // the folder whose children to chart (== rootPath for the whole scan)
    let folderName: String   // display name for the title
}

/// Stacked-area chart of how a folder's children evolved across the archived
/// scans of its enclosing scan.
struct HistoryChartView: View {
    let request: HistoryRequest
    @Environment(\.dismiss) private var dismiss

    @State private var samples: [HistorySample] = []
    @State private var loading = true

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let size: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                loadingView
            } else if samples.count < 2 {
                notEnoughView
            } else {
                chart.padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await load() }
    }

    private func load() async {
        let req = request
        let result = await Task.detached(priority: .userInitiated) {
            ScanStore.folderHistory(rootPath: req.rootPath, folderPath: req.folderPath)
        }.value
        samples = result
        loading = false
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History — \(request.folderName)").font(.headline)
                Text(loading ? request.folderPath : "\(request.folderPath) · \(samples.count) scans")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading past scans…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var notEnoughView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Not enough history yet").font(.headline)
            Text("This folder appears in fewer than two past scans. Scan again later to see how it changes over time.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Data

    /// Children ordered by their size in the most recent scan (so stacking order
    /// and colors match the treemap), with any that only appear in older scans
    /// appended after.
    private var orderedCategories: [String] {
        guard let latest = samples.last else { return [] }
        var order = latest.categories.sorted { $0.size > $1.size }.map(\.name)
        var seen = Set(order)
        var extra: [(String, Int64)] = []
        for sample in samples {
            for cat in sample.categories where !seen.contains(cat.name) {
                seen.insert(cat.name)
                extra.append((cat.name, cat.size))
            }
        }
        order += extra.sorted { $0.1 > $1.1 }.map(\.0)
        return order
    }

    private var points: [Point] {
        let categories = orderedCategories
        guard !categories.isEmpty else { return [] }
        return samples.flatMap { sample -> [Point] in
            let sizes = Dictionary(sample.categories.map { ($0.name, $0.size) },
                                   uniquingKeysWith: { a, _ in a })
            return categories.map { name in
                Point(date: sample.date, category: name, size: Double(sizes[name] ?? 0))
            }
        }
    }

    private var colors: [Color] {
        orderedCategories.indices.map { NodePalette.categoryColor($0) }
    }

    // MARK: Chart

    private var chart: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value("Size", point.size),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Folder", point.category))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: orderedCategories, range: colors)
        .chartLegend(position: .trailing, alignment: .top)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(formatBytes(Int64(bytes)))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: samples.map(\.date)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
    }
}
