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
///
/// Every archived scan is read once, as a compact `HistorySummary`, when the
/// sheet opens. Drilling down, going back and changing the depth then only
/// re-slice those in memory, so navigation never touches the disk.
struct HistoryChartView: View {
    let request: HistoryRequest
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.historyDepthKey)
    private var historyDepth = AppSettings.defaultHistoryDepth

    @State private var navigation: [HistoryLocation]
    @State private var summaries: [HistorySummary] = []
    @State private var chart = ChartData()
    @State private var timelineDates: [Date] = []
    @State private var loadedSnapshots = 0
    @State private var loading = true

    /// Peak memory, not throughput, is the limit while summaries are still
    /// being built: each build decompresses a whole archive.
    private static let maxConcurrentLoads = 4
    /// Roughly how many dates the X axis should label before thinning.
    private static let maxAxisLabels = 8

    private struct HistoryLocation: Hashable, Identifiable {
        let path: String
        let name: String
        var id: String { path }
    }

    private struct Point: Identifiable {
        /// Stable across recomputations, so SwiftUI reuses marks instead of
        /// rebuilding the whole chart whenever another snapshot arrives.
        let id: String
        let date: Date
        let categoryID: String
        let size: Double
    }

    /// Everything the chart and legend draw, computed once per data change
    /// rather than on every `body` evaluation.
    private struct ChartData {
        var categories: [CategorySize] = []
        var identities: [String] = []
        var colors: [Color] = []
        var colorByIdentity: [String: Color] = [:]
        var points: [Point] = []
        var samples: [HistorySample] = []
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

    private var sliceID: String { "\(currentFolder.path)|\(historyDepth)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading && timelineDates.isEmpty {
                loadingView
            } else if timelineDates.count < 2 {
                notEnoughView
            } else if !loading && chart.samples.isEmpty {
                tooSmallView
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
        .task(id: request.rootPath) { await loadSummaries() }
        .onChange(of: sliceID) { refreshChart() }
    }

    // MARK: Loading (once per sheet) and slicing (instant)

    private func loadSummaries() async {
        loading = true
        summaries = []
        chart = ChartData()
        loadedSnapshots = 0

        let rootPath = request.rootPath
        let entries = await Task.detached(priority: .userInitiated) {
            ScanStore.history(forRootPath: rootPath)
        }.value
        guard !Task.isCancelled else { return }
        timelineDates = entries.map(\.date)
        guard !entries.isEmpty else {
            loading = false
            return
        }

        // Newest first, so the most useful part of the chart appears first.
        var pending = Array(entries.reversed()).makeIterator()
        await withTaskGroup(of: HistorySummary?.self) { group in
            for _ in 0..<Self.maxConcurrentLoads {
                guard let entry = pending.next() else { break }
                group.addTask { await HistorySummaryStore.shared.summary(for: entry) }
            }
            for await summary in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let summary {
                    summaries.append(summary)
                    summaries.sort { $0.date < $1.date }
                }
                loadedSnapshots += 1
                refreshChart()
                if let entry = pending.next() {
                    group.addTask { await HistorySummaryStore.shared.summary(for: entry) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        loading = false
    }

    /// Re-slice the loaded summaries for the current folder and depth. Pure
    /// in-memory work over a few thousand nodes per snapshot.
    private func refreshChart() {
        let folderPath = currentFolder.path
        let depth = historyDepth
        let samples = summaries.compactMap { summary -> HistorySample? in
            guard let categories = summary.categories(folderPath: folderPath, depth: depth)
            else { return nil }
            return HistorySample(date: summary.date, categories: categories)
        }

        let categories = orderedCategories(in: samples)
        let colors = categories.indices.map { NodePalette.categoryColor($0) }
        let identities = categories.map(\.identity)
        var colorByIdentity: [String: Color] = [:]
        for (identity, color) in zip(identities, colors) { colorByIdentity[identity] = color }

        var points: [Point] = []
        points.reserveCapacity(samples.count * categories.count)
        for sample in samples {
            let sizes = Dictionary(sample.categories.map { ($0.identity, $0.size) },
                                   uniquingKeysWith: { first, _ in first })
            let stamp = sample.date.timeIntervalSince1970
            for identity in identities {
                points.append(Point(id: "\(stamp)|\(identity)", date: sample.date,
                                    categoryID: identity,
                                    size: Double(sizes[identity] ?? 0)))
            }
        }

        chart = ChartData(categories: categories, identities: identities, colors: colors,
                          colorByIdentity: colorByIdentity, points: points, samples: samples)
    }

    /// Categories ordered by their size in the most recent scan, with any that
    /// only appear in older scans appended after. Walking the samples from
    /// newest to oldest keeps colors stable as older snapshots arrive.
    private func orderedCategories(in samples: [HistorySample]) -> [CategorySize] {
        guard let latest = samples.last else { return [] }
        let order = latest.categories.sorted { $0.size > $1.size }
        var seen = Set(order.map(\.identity))
        var extra: [CategorySize] = []
        for sample in samples.reversed() {
            for category in sample.categories where !seen.contains(category.identity) {
                seen.insert(category.identity)
                extra.append(category)
            }
        }
        return order + extra.sorted { $0.size > $1.size }
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
                     ? "\(currentFolder.path) · \(loadedSnapshots) of \(timelineDates.count) scans read"
                     : "\(currentFolder.path) · \(chart.samples.count) scans · \(historyDepth) \(historyDepth == 1 ? "layer" : "layers")")
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
            ProgressView(value: Double(loadedSnapshots),
                         total: Double(max(timelineDates.count, 1)))
                .frame(width: 150)
            Text("Loading snapshots newest first — \(loadedSnapshots) of \(timelineDates.count)")
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

    private var tooSmallView: some View {
        VStack(spacing: 8) {
            Image(systemName: "scalemass")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Too small to be tracked in history").font(.headline)
            Text("History keeps only the largest folders of each scan, and \(currentFolder.name) was below that limit in every one. Open it in the treemap to see its current contents.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
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
            chartView
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
                    ForEach(chart.categories) { category in
                        Button {
                            drillDown(to: category)
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(chart.colorByIdentity[category.identity] ?? .gray)
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

    private var chartView: some View {
        Chart(chart.points) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value("Size", point.size),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Folder", point.categoryID))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: chart.identities, range: chart.colors)
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
            AxisMarks(values: axisDates) { value in
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

    /// Evenly spaced scan dates, so a long history does not crowd the axis
    /// with one label per scan. The last scan is always labelled.
    private var axisDates: [Date] {
        guard timelineDates.count > Self.maxAxisLabels else { return timelineDates }
        let stride = Int((Double(timelineDates.count) / Double(Self.maxAxisLabels)).rounded(.up))
        var picked = timelineDates.enumerated()
            .filter { $0.offset % stride == 0 }
            .map(\.element)
        if let last = timelineDates.last, picked.last != last { picked.append(last) }
        return picked
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
              let sample = chart.samples.min(by: {
                  abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
              }) else { return }

        let sizes = Dictionary(sample.categories.map { ($0.identity, $0.size) },
                               uniquingKeysWith: { first, _ in first })
        var cumulative = 0.0
        for category in chart.categories {
            cumulative += Double(sizes[category.identity] ?? 0)
            if value <= cumulative {
                drillDown(to: category)
                return
            }
        }
    }
}
