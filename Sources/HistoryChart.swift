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
    @State private var summaries: [(date: Date, summary: HistorySummary)] = []
    @State private var chart = ChartData()
    @State private var timelineDates: [Date] = []
    @State private var hover: Hover?
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
        let lower: Double
        let upper: Double
    }

    private struct StackSample {
        let date: Date
        /// The bottom of the stack followed by the top of each category.
        let edges: [Int64]
    }

    private struct BandHit: Equatable {
        let date: Date
        let category: CategorySize
        let size: Int64?
    }

    private enum Hover: Equatable {
        case scan(Date)
        case band(BandHit)

        var date: Date {
            switch self {
            case .scan(let date): date
            case .band(let band): band.date
            }
        }
    }

    private struct ScanLine {
        let date: Date
        let x: CGFloat
    }

    /// Everything the chart and legend draw, computed once per data change
    /// rather than on every `body` evaluation.
    private struct ChartData {
        var categories: [CategorySize] = []
        var identities: [String] = []
        var colors: [Color] = []
        var colorByIdentity: [String: Color] = [:]
        var points: [Point] = []
        var stacks: [StackSample] = []
        var largestCategoriesByDate: [Date: [CategorySize]] = [:]
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
            } else if !loading && chart.stacks.isEmpty {
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
        .onChange(of: sliceID) {
            hover = nil
            refreshChart()
        }
    }

    // MARK: Loading (once per sheet) and slicing (instant)

    private func loadSummaries() async {
        loading = true
        summaries = []
        chart = ChartData()
        hover = nil
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
        await withTaskGroup(of: (Date, HistorySummary?).self) { group in
            for _ in 0..<Self.maxConcurrentLoads {
                guard let entry = pending.next() else { break }
                group.addTask { (entry.date, await HistorySummaryStore.shared.summary(for: entry)) }
            }
            for await (date, summary) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let summary {
                    // The index supplies the plot dates. Summary dates can differ
                    // slightly after encoding against a different epoch.
                    summaries.append((date, summary))
                    summaries.sort { $0.date < $1.date }
                }
                loadedSnapshots += 1
                refreshChart()
                if let entry = pending.next() {
                    group.addTask { (entry.date, await HistorySummaryStore.shared.summary(for: entry)) }
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
        let samples = summaries.compactMap { snapshot -> HistorySample? in
            guard let categories = snapshot.summary.categories(folderPath: folderPath, depth: depth)
            else { return nil }
            return HistorySample(date: snapshot.date, categories: categories)
        }

        let categories = orderedCategories(in: samples)
        let colors = categories.indices.map { NodePalette.categoryColor($0) }
        let identities = categories.map(\.identity)
        var colorByIdentity: [String: Color] = [:]
        for (identity, color) in zip(identities, colors) { colorByIdentity[identity] = color }

        var points: [Point] = []
        var stacks: [StackSample] = []
        var largestCategoriesByDate: [Date: [CategorySize]] = [:]
        points.reserveCapacity(samples.count * categories.count)
        for sample in samples {
            // The summary orders named items by size and appends the aggregate "Other".
            largestCategoriesByDate[sample.date] = Array(
                sample.categories.lazy.filter { $0.path != nil }.prefix(5)
            )
            let sizes = Dictionary(sample.categories.map { ($0.identity, $0.size) },
                                   uniquingKeysWith: { first, _ in first })
            let stamp = sample.date.timeIntervalSince1970
            var edges: [Int64] = [0]
            var total: Int64 = 0
            for identity in identities {
                let lower = total
                total += sizes[identity] ?? 0
                points.append(Point(id: "\(stamp)|\(identity)", date: sample.date,
                                    categoryID: identity,
                                    lower: Double(lower), upper: Double(total)))
                edges.append(total)
            }
            stacks.append(StackSample(date: sample.date, edges: edges))
        }

        chart = ChartData(categories: categories, identities: identities, colors: colors,
                          colorByIdentity: colorByIdentity, points: points, stacks: stacks,
                          largestCategoriesByDate: largestCategoriesByDate)
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
                     : "\(currentFolder.path) · \(chart.stacks.count) scans · \(historyDepth) \(historyDepth == 1 ? "layer" : "layers")")
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
            Text("Hover a band or date line for sizes")
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
                yStart: .value("Band start", point.lower),
                yEnd: .value("Band end", point.upper),
                series: .value("Folder", point.categoryID)
            )
            .foregroundStyle(by: .value("Folder", point.categoryID))
            .interpolationMethod(.linear)
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
                if let date = value.as(Date.self) {
                    let isFirst = date == timelineDates.first
                    let isLast = date == timelineDates.last
                    let anchor: UnitPoint = if isFirst {
                        .topLeading
                    } else if isLast {
                        .topTrailing
                    } else {
                        .top
                    }
                    AxisValueLabel(centered: false, anchor: anchor,
                                   collisionResolution: .greedy(priority: isFirst || isLast ? 1 : 0,
                                                                minimumSpacing: 6)) {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    scanOverlay(plotFrame: geometry[anchor], proxy: proxy)
                }
            }
        }
    }

    private func scanOverlay(plotFrame: CGRect, proxy: ChartProxy) -> some View {
        let lines = timelineDates.compactMap { date in
            proxy.position(forX: date).map { ScanLine(date: date, x: plotFrame.minX + $0) }
        }
        let selected = lines.first { $0.date == hover?.date }

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let guides = Path { path in
                    for line in lines {
                        path.move(to: CGPoint(x: line.x, y: plotFrame.minY))
                        path.addLine(to: CGPoint(x: line.x, y: plotFrame.maxY))
                    }
                }
                context.stroke(guides, with: .color(.primary.opacity(0.38)),
                               style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                if let selected, case .scan = hover {
                    let highlight = Path { path in
                        path.move(to: CGPoint(x: selected.x, y: plotFrame.minY))
                        path.addLine(to: CGPoint(x: selected.x, y: plotFrame.maxY))
                    }
                    context.stroke(highlight, with: .color(.primary.opacity(0.85)), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                let target: Hover? = switch phase {
                case .active(let location):
                    scanDate(near: location, plotFrame: plotFrame, lines: lines).map(Hover.scan)
                    ?? band(at: location, plotFrame: plotFrame, proxy: proxy).map(Hover.band)
                case .ended: nil
                }
                if hover != target { hover = target }
            }
            .gesture(
                SpatialTapGesture().onEnded { event in
                    if let hit = band(at: event.location, plotFrame: plotFrame, proxy: proxy) {
                        drillDown(to: hit.category)
                    }
                }
            )

            if let hover, let selected, plotFrame.width > 32 {
                hoverDetails(for: hover, anchor: selected, plotFrame: plotFrame)
                    .allowsHitTesting(false)
            }
        }
    }

    private func scanDate(near location: CGPoint, plotFrame: CGRect, lines: [ScanLine]) -> Date? {
        guard (plotFrame.minX...plotFrame.maxX).contains(location.x),
              (plotFrame.minY...plotFrame.maxY).contains(location.y),
              let nearest = lines.min(by: { abs($0.x - location.x) < abs($1.x - location.x) }),
              abs(nearest.x - location.x) <= 7 else { return nil }
        return nearest.date
    }

    private func hoverDetails(for target: Hover, anchor line: ScanLine, plotFrame: CGRect) -> some View {
        let inset: CGFloat = 8
        let placeOnRight = line.x <= plotFrame.midX
        let sideWidth = placeOnRight ? plotFrame.maxX - line.x : line.x - plotFrame.minX
        let width = min(260, sideWidth - 2 * inset)
        let x = placeOnRight ? line.x + inset : line.x - inset - width
        return VStack(alignment: .leading, spacing: 5) {
            Text(line.date.formatted(date: .abbreviated, time: .shortened))
                .fontWeight(.semibold)
            switch target {
            case .scan(let date):
                let items = chart.largestCategoriesByDate[date]
                if let items, !items.isEmpty {
                    ForEach(items) { item in
                        detailRow(for: item, size: item.size)
                    }
                } else {
                    Text(loading && items == nil ? "Loading scan details…" : "No items tracked for this folder")
                        .foregroundStyle(.secondary)
                }
            case .band(let band):
                detailRow(for: band.category, size: band.size)
                if band.size == nil {
                    Text("Not tracked in this scan")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15))
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .offset(x: x, y: plotFrame.minY + inset)
    }

    private func detailRow(for category: CategorySize, size: Int64?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(chart.colorByIdentity[category.identity] ?? .gray)
                .frame(width: 8, height: 8)
            Text(category.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let size {
                Spacer(minLength: 4)
                Text(formatBytes(size))
                    .monospacedDigit()
                    .fixedSize()
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

    private func band(at location: CGPoint, plotFrame: CGRect, proxy: ChartProxy) -> BandHit? {
        guard plotFrame.contains(location) else { return nil }
        let plotPoint = CGPoint(x: location.x - plotFrame.minX,
                                y: location.y - plotFrame.minY)
        guard let date = proxy.value(atX: plotPoint.x, as: Date.self),
              let value = proxy.value(atY: plotPoint.y, as: Double.self) else { return nil }
        return band(at: date, value: value)
    }

    /// Interpolate the same boundaries drawn by AreaMark, then read the
    /// selected band's measured size from the closer of the two scans.
    private func band(at date: Date, value: Double) -> BandHit? {
        let stacks = chart.stacks
        guard stacks.count > 1, date >= stacks[0].date, value >= 0,
              let index = stacks.firstIndex(where: { $0.date >= date }) else { return nil }
        let right = stacks[index]
        let left = stacks[max(0, index - 1)]
        let interval = right.date.timeIntervalSince(left.date)
        let fraction = interval > 0 ? date.timeIntervalSince(left.date) / interval : 0
        let measured = fraction <= 0.5 ? left : right

        var lower = 0.0
        for index in chart.categories.indices {
            let end = index + 1
            let upper = Double(left.edges[end]) + fraction * Double(right.edges[end] - left.edges[end])
            if upper > lower && value <= upper {
                let size = measured.edges[end] - measured.edges[index]
                return BandHit(date: measured.date, category: chart.categories[index],
                               size: size > 0 ? size : nil)
            }
            lower = upper
        }
        return nil
    }
}
