import SwiftUI
import Charts

/// Identifies which folder's history to show — used with `.sheet(item:)` so the
/// value is passed straight into the sheet (avoiding stale `@State` reads).
struct HistoryRequest: Identifiable {
    let id = UUID()
    let rootPath: String
}

/// Stacked-area chart of how a folder's top-level composition evolved across the
/// archived scans of that same folder.
struct HistoryChartView: View {
    let rootPath: String
    private let entries: [ScanHistoryEntry]     // oldest → newest, same rootPath
    @Environment(\.dismiss) private var dismiss

    init(rootPath: String) {
        self.rootPath = rootPath
        self.entries = ScanStore.history(forRootPath: rootPath)
    }

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
            if entries.count < 2 {
                ContentUnavailablePlaceholder
            } else {
                chart.padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan history").font(.headline)
                Text("\(rootPath) · \(entries.count) scans")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var ContentUnavailablePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Not enough history yet")
                .font(.headline)
            Text("Scan this folder again later to see how it changed over time.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Data

    /// Categories ordered by their size in the most recent scan (so the stacking
    /// order and colors match the treemap), with any that only appear in older
    /// scans appended after.
    private var orderedCategories: [String] {
        guard let latest = entries.last else { return [] }
        var order = (latest.categories ?? []).sorted { $0.size > $1.size }.map(\.name)
        var seen = Set(order)
        var extra: [(String, Int64)] = []
        for entry in entries {
            for cat in entry.categories ?? [] where !seen.contains(cat.name) {
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
        return entries.flatMap { entry -> [Point] in
            let sizes = Dictionary(
                (entry.categories ?? []).map { ($0.name, $0.size) },
                uniquingKeysWith: { a, _ in a })
            return categories.map { name in
                Point(date: entry.date, category: name, size: Double(sizes[name] ?? 0))
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
            AxisMarks(values: entries.map(\.date)) { value in
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
