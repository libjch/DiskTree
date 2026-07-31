import SwiftUI
import Charts

/// Identifies which folder's history to show — used with `.sheet(item:)` so the
/// value is passed straight into the sheet (avoiding stale `@State` reads).
struct HistoryRequest: Identifiable {
    let id = UUID()
    let rootPath: String     // the scanned root the history is indexed under
    let folderPath: String   // the folder whose descendants to chart
    let folderName: String   // display name for the title
}

/// Stacked-area chart of how a folder's contents evolved across the archived
/// scans of its enclosing scan. Directory bands and legend entries can be used
/// to navigate deeper without closing the sheet.
struct HistoryChartView: View {
    let request: HistoryRequest
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.historyDepthKey)
    private var historyDepth = AppSettings.defaultHistoryDepth

    @State private var navigation: [HistoryLocation]
    @State private var samples: [HistorySample] = []
    @State private var timelineDates: [Date] = []
    @State private var processedSnapshots = 0
    @State private var loading = true

    private struct HistoryLocation: Hashable, Identifiable {
        let path: String
        let name: String
        var id: String { path }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let categoryID: String
        let size: Double
    }

    init(request: HistoryRequest) {
        self.request = request
        _navigation = State(initialValue: [
            HistoryLocation(path: request.folderPath, name: request.folderName)
        ])
    }

    private var currentFolder: HistoryLocation {
        navigation.last ?? HistoryLocation(path: request.folderPath,
                                           name: request.folderName)
    }

    private var loadID: String {
        "\(currentFolder.path)|\(historyDepth)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading && timelineDates.isEmpty {
                loadingView
            } else if timelineDates.count < 2 {
                notEnoughView
            } else {
                VStack(spacing: 0) {
                    chartAndLegend.padding(16)
                    if loading {
                        Divider()
                        loadingProgress
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .task(id: loadID) {
            await load(folder: currentFolder, depth: historyDepth)
        }
    }

    private func load(folder: HistoryLocation, depth: Int) async {
        loading = true
        samples = []
        timelineDates = []
        processedSnapshots = 0
        let rootPath = request.rootPath
        let entries = await Task.detached(priority: .userInitiated) {
            ScanStore.history(forRootPath: rootPath)
        }.value
        guard currentFolder.path == folder.path, historyDepth == depth else { return }
        timelineDates = entries.map(\.date)

        for entry in entries.reversed() {
            guard !Task.isCancelled else { return }
            let sample = await Task.detached(priority: .userInitiated) {
                ScanStore.folderHistorySample(entry: entry, folderPath: folder.path,
                                              depth: depth)
            }.value
            guard !Task.isCancelled, currentFolder.path == folder.path,
                  historyDepth == depth else { return }
            if let sample {
                samples.append(sample)
                samples.sort { $0.date < $1.date }
            }
            processedSnapshots += 1
        }
        loading = false
    }

    // MARK: Header and navigation

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                guard navigation.count > 1 else { return }
                navigation.removeLast()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(navigation.count < 2)
            .help("Back to the previous folder")

            VStack(alignment: .leading, spacing: 4) {
                Text("History — \(currentFolder.name)").font(.headline)
                breadcrumb
                Text(loading
                     ? "\(currentFolder.path) · \(processedSnapshots) of \(timelineDates.count) scans read"
                     : "\(currentFolder.path) · \(samples.count) scans · \(historyDepth) \(historyDepth == 1 ? "layer" : "layers")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(navigation, id: \.path) { (folder: HistoryLocation) in
                let index = navigation.firstIndex(of: folder) ?? 0
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(folder.name) {
                    navigation = Array(navigation.prefix(index + 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == navigation.count - 1
                                 ? Color.primary : Color.accentColor)
                .disabled(index == navigation.count - 1)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading history timeline…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var loadingProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(processedSnapshots),
                         total: Double(max(timelineDates.count, 1)))
                .frame(width: 150)
            Text("Loading snapshots newest first — \(processedSnapshots) of \(timelineDates.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
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

    /// Categories ordered by their size in the most recent scan, with any that
    /// only appear in older scans appended after.
    private var orderedCategories: [CategorySize] {
        guard let latest = samples.last else { return [] }
        var order = latest.categories.sorted { $0.size > $1.size }
        var seen = Set(order.map(\.identity))
        var extra: [CategorySize] = []
        // Samples are stored oldest-to-newest, but loading happens in the other
        // direction. Preserve that discovery order so existing colors never
        // reshuffle when another older archive arrives.
        for sample in samples.reversed() {
            for category in sample.categories where !seen.contains(category.identity) {
                seen.insert(category.identity)
                extra.append(category)
            }
        }
        order += extra.sorted { $0.size > $1.size }
        return order
    }

    private var points: [Point] {
        let categories = orderedCategories
        guard !categories.isEmpty else { return [] }
        return samples.flatMap { sample -> [Point] in
            let sizes = Dictionary(sample.categories.map { ($0.identity, $0.size) },
                                   uniquingKeysWith: { first, _ in first })
            return categories.map { category in
                Point(date: sample.date, categoryID: category.identity,
                      size: Double(sizes[category.identity] ?? 0))
            }
        }
    }

    private var colors: [Color] {
        orderedCategories.indices.map { NodePalette.categoryColor($0) }
    }

    private func drillDown(to category: CategorySize) {
        guard category.canDrillDown, let path = category.path,
              path != currentFolder.path else { return }
        navigation.append(HistoryLocation(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent
        ))
    }

    // MARK: Chart and interactive legend

    private var chartAndLegend: some View {
        HStack(alignment: .top, spacing: 16) {
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            legend
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders").font(.caption.bold())
            Text("Click a folder to explore it")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(orderedCategories) { category in
                        let color = color(for: category)
                        Button {
                            drillDown(to: category)
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color)
                                    .frame(width: 11, height: 11)
                                Text(category.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 2)
                                if category.canDrillDown {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!category.canDrillDown)
                        .help(category.canDrillDown
                              ? "Show history for \(category.name)"
                              : category.name)
                    }
                }
            }
        }
    }

    private func color(for category: CategorySize) -> Color {
        guard let index = orderedCategories.firstIndex(where: {
            $0.identity == category.identity
        }) else { return .gray }
        return colors[index]
    }

    private var chart: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value("Size", point.size),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Folder", point.categoryID))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(
            domain: orderedCategories.map(\.identity),
            range: colors
        )
        .chartLegend(.hidden)
        .chartXScale(domain: timelineDomain)
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
            AxisMarks(values: timelineDates) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { event in
                                selectBand(at: event.location, plotFrame: frame,
                                           proxy: proxy)
                            }
                        )
                }
            }
        }
    }

    private var timelineDomain: ClosedRange<Date> {
        let start = timelineDates.first ?? Date()
        let end = timelineDates.last ?? start.addingTimeInterval(1)
        return start < end ? start...end : start...start.addingTimeInterval(1)
    }

    /// Resolve a click to the nearest archived sample and then to the category
    /// occupying that vertical position in the stack.
    private func selectBand(at location: CGPoint, plotFrame: CGRect,
                            proxy: ChartProxy) {
        guard plotFrame.contains(location) else { return }
        let plotPoint = CGPoint(x: location.x - plotFrame.minX,
                                y: location.y - plotFrame.minY)
        guard let date = proxy.value(atX: plotPoint.x, as: Date.self),
              let value = proxy.value(atY: plotPoint.y, as: Double.self),
              let sample = samples.min(by: {
                  abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
              }) else { return }

        let sizes = Dictionary(sample.categories.map { ($0.identity, $0.size) },
                               uniquingKeysWith: { first, _ in first })
        var cumulative = 0.0
        for category in orderedCategories {
            cumulative += Double(sizes[category.identity] ?? 0)
            if value <= cumulative {
                drillDown(to: category)
                return
            }
        }
    }
}
