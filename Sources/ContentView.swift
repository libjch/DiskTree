import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var scanner = Scanner()
    @State private var selection: FileNode?
    /// Node whose contents the treemap is currently showing (drill-down root).
    @State private var treemapRoot: FileNode?
    @State private var didCheckFDA = false
    /// Expanded outline rows, keyed by folder path so expansion survives the
    /// identity churn of progressive scan snapshots.
    @State private var expanded: Set<String> = []
    @State private var historyRequest: HistoryRequest?
    /// Cached count of archived scans for the current folder (drives the History
    /// button's enabled state without reading disk on every render).
    @State private var historyCount = 0

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .navigationTitle("")
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            guard !didCheckFDA else { return }
            didCheckFDA = true
            // Restore the last scan so the app opens with results, not empty.
            scanner.loadSaved()
            // Defer so the window is on screen before the modal appears.
            DispatchQueue.main.async { FullDiskAccess.promptIfNeeded() }
        }
        .onChange(of: scanner.root) {
            // Auto-expand the root of a freshly restored scan so its top-level
            // folders are visible right away.
            if let root = scanner.root, expanded.isEmpty { expanded = [root.path] }
            refreshHistoryCount()
        }
        .onChange(of: scanner.lastScanDate) { refreshHistoryCount() }
        .sheet(item: $historyRequest) { req in
            HistoryChartView(rootPath: req.rootPath)
        }
    }

    // MARK: Sidebar (outline tree)

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 0) {
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    /// "DiskTree v1.1 · built 2026-07-15 10:15" — the build date makes it obvious
    /// which build is running.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info?["BuildDate"] as? String, build != "unknown" {
            return "DiskTree v\(version) · built \(build)"
        }
        return "DiskTree v\(version)"
    }

    private var sidebarContent: some View {
        Group {
            // Prefer the finished tree; fall back to the progressive snapshot so
            // the outline fills in live during a scan.
            if let displayRoot = scanner.root ?? scanner.partialRoot {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            OutlineRow(node: displayRoot, total: max(displayRoot.size, 1),
                                       selection: $selection, expanded: $expanded,
                                       onRescan: { scanner.rescanSubtree($0) })
                        }
                        .listStyle(.sidebar)
                        .onChange(of: selection) { revealInOutline(selection, proxy: proxy) }
                    }
                    if scanner.isScanning {
                        Divider()
                        scanFooter
                    }
                }
            } else if scanner.isScanning {
                // Brief window before the first snapshot arrives.
                startingPlaceholder
            } else if scanner.isLoadingSaved {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading last scan…").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                welcomePlaceholder
            }
        }
    }

    private var startingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Starting scan…").font(.headline)
            Text(scanner.currentPath)
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).padding(.horizontal)
            Button("Cancel") { scanner.cancel() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Live scan status pinned to the bottom of the sidebar while scanning.
    /// Actions (Cancel / switch folder) live in the toolbar.
    private var scanFooter: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scanning… \(scanner.scannedItems) items")
                    .font(.caption).bold()
                Text(scanner.currentPath)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var welcomePlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("DiskTree").font(.largeTitle.bold())
            Text("See what's eating your disk space.")
                .foregroundStyle(.secondary)
            if let error = scanner.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            VStack(spacing: 8) {
                Button { scan(URL(fileURLWithPath: "/")) } label: {
                    Label("Scan Disk", systemImage: "externaldrive")
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .help("Scans the whole disk (/).")
                Button { chooseAndScan() } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
            }
            .padding(.top, 6)

            if !FullDiskAccess.isGranted {
                Divider().frame(width: 220).padding(.vertical, 4)
                Button {
                    FullDiskAccess.openSettings()
                } label: {
                    Label("Grant Full Disk Access…", systemImage: "lock.open")
                }
                .help("Opens System Settings so you can enable DiskTree once, avoiding per-folder prompts.")
                Text("Optional — lets DiskTree scan protected folders without repeated prompts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Detail (treemap + info)

    private var detail: some View {
        Group {
            if let mapRoot = treemapRoot ?? scanner.root ?? scanner.partialRoot {
                VStack(spacing: 0) {
                    breadcrumb(for: mapRoot)
                    Divider()
                    TreemapView(node: mapRoot, selection: $selection,
                                onDrill: { drilled in
                                    treemapRoot = drilled
                                    selection = drilled
                                },
                                onRescan: { scanner.rescanSubtree($0) })
                    .background(Color(nsColor: .textBackgroundColor))
                    Divider()
                    infoBar
                }
            } else {
                Text("Choose a folder to begin.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func breadcrumb(for mapRoot: FileNode) -> some View {
        HStack(spacing: 6) {
            if let parent = mapRoot.parent, treemapRoot != nil {
                Button {
                    treemapRoot = parent === scanner.root ? nil : parent
                    selection = parent
                } label: {
                    Label("Up", systemImage: "arrow.up.left")
                }
                .buttonStyle(.borderless)
            }
            Image(systemName: mapRoot.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(.tint)
            Text(mapRoot.url.path)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            if scanner.isScanning {
                ProgressView().controlSize(.small).padding(.leading, 4)
                Text("scanning \(scanner.scannedItems) items…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let rp = scanner.rescanningPath {
                ProgressView().controlSize(.small).padding(.leading, 4)
                Text("rescanning \((rp as NSString).lastPathComponent)…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let date = scanner.lastScanDate {
                Text("· scanned \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(mapRoot.size)).font(.callout.monospacedDigit()).bold()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var infoBar: some View {
        HStack(spacing: 16) {
            if let sel = selection {
                Image(systemName: sel.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(NodePalette.color(for: sel))
                VStack(alignment: .leading, spacing: 1) {
                    Text(sel.name).font(.callout.bold()).lineLimit(1)
                    Text(sel.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatBytes(sel.size)).font(.callout.monospacedDigit().bold())
                    Text("\(sel.fileCount) files").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Select an item to see its details. Use the toolbar to reveal it in Finder or move it to Trash.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 52)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Scan actions — left side. "Scan Disk" is the prominent default.
        ToolbarItemGroup(placement: .navigation) {
            Button { scan(URL(fileURLWithPath: "/")) } label: {
                Label("Scan Disk", systemImage: "externaldrive")
            }
            .buttonStyle(.borderedProminent)
            .labelStyle(.titleAndIcon)
            .help("Scan the whole disk (/). A full scan may need Full Disk Access.")

            Button { chooseAndScan() } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            .labelStyle(.titleAndIcon)
            .help("Pick a specific folder to scan. Starting a scan replaces the current one.")

            Button { refreshCurrent() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .disabled(scanner.root == nil || scanner.isScanning)
            .help("Re-scan the current folder to pick up changes.")

            Button {
                historyRequest = HistoryRequest(rootPath: scanner.root?.path ?? "")
            } label: {
                Label("History", systemImage: "chart.line.uptrend.xyaxis")
            }
            .labelStyle(.titleAndIcon)
            .disabled(historyCount < 2)
            .help(historyCount < 2
                  ? "Waiting for more scans — scan this folder at least twice to chart its history."
                  : "Show how this folder's size evolved across past scans.")

            if scanner.isScanning {
                Button(role: .cancel) { scanner.cancel() } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .labelStyle(.titleAndIcon)
            }
        }
        // Selection actions — right side, enabled only with a selection.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let sel = selection { NSWorkspace.shared.activateFileViewerSelecting([sel.url]) }
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .disabled(selection == nil)
            .help("Reveal the selected item in Finder.")

            Button(role: .destructive) {
                if let sel = selection { moveToTrash(sel) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(!canMoveSelectionToTrash)
            .help(canMoveSelectionToTrash
                  ? "Move the selected item to the Trash."
                  : "The root of a scan cannot be moved to the Trash.")
        }
    }

    /// Never offer to trash the scan root. A user may scan `/`, their home
    /// directory, or another important folder; destructive actions are limited
    /// to descendants that can be removed cleanly from the displayed tree.
    private var canMoveSelectionToTrash: Bool {
        guard let selection else { return false }
        return selection.parent != nil
    }

    /// Re-scan the current root to reflect on-disk changes.
    private func refreshCurrent() {
        guard let root = scanner.root else { return }
        scan(root.url)
    }

    private func refreshHistoryCount() {
        historyCount = scanner.root.map { ScanStore.history(forRootPath: $0.path).count } ?? 0
    }

    /// When something is selected (e.g. by clicking a treemap tile), expand its
    /// ancestors so the row is visible in the outline and scroll it into view.
    private func revealInOutline(_ node: FileNode?, proxy: ScrollViewProxy) {
        guard let node else { return }
        var ancestor = node.parent
        while let a = ancestor { expanded.insert(a.path); ancestor = a.parent }
        // Defer the scroll so the newly-expanded rows exist first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(node.id, anchor: .center)
            }
        }
    }

    // MARK: Actions

    private func chooseAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }

    private func scan(_ url: URL) {
        selection = nil
        treemapRoot = nil
        // Auto-expand the scan root so its top-level folders appear as they're found.
        expanded = [url.path]
        scanner.scan(url)
    }

    private func moveToTrash(_ node: FileNode) {
        guard node.parent != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to Trash?"
        alert.informativeText = "This frees \(formatBytes(node.size)). You can restore it from the Trash until it's emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // First button ("Move to Trash") has raw value 1000.
        guard alert.runModal().rawValue == 1000 else { return }

        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            // Remove from the tree and roll the freed space up to ancestors.
            removeFromTree(node)
            if selection == node { selection = nil }
            if treemapRoot == node { treemapRoot = node.parent === scanner.root ? nil : node.parent }
        } catch {
            let err = NSAlert()
            err.messageText = "Couldn't move to Trash"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    private func removeFromTree(_ node: FileNode) {
        let freed = node.size
        var ancestor = node.parent
        while let a = ancestor {
            a.size -= freed
            a.fileCount -= node.fileCount
            ancestor = a.parent
        }
        node.parent?.children?.removeAll { $0 === node }
        // Force SwiftUI to re-read the tree.
        scanner.objectWillChange.send()
        // Keep the persisted copy in sync with the freed space.
        if let root = scanner.root { scanner.persist(root) }
    }
}

/// One recursive row in the outline tree with a proportional size bar.
struct OutlineRow: View {
    let node: FileNode
    let total: Int64
    @Binding var selection: FileNode?
    @Binding var expanded: Set<String>
    var onRescan: (FileNode) -> Void

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(children) { child in
                    OutlineRow(node: child, total: total,
                               selection: $selection, expanded: $expanded,
                               onRescan: onRescan)
                }
            } label: {
                rowLabel
            }
        } else {
            rowLabel.tag(node)
        }
    }

    /// Expansion state keyed by folder path so it persists across the identity
    /// churn of progressive scan snapshots.
    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.url.path) },
            set: { isOpen in
                if isOpen { expanded.insert(node.url.path) }
                else { expanded.remove(node.url.path) }
            }
        )
    }

    private var rowLabel: some View {
        let fraction = total > 0 ? Double(node.size) / Double(total) : 0
        return HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(NodePalette.color(for: node))
                .frame(width: 16)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 8)
            // Proportional bar (share of the whole scan).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(NodePalette.color(for: node))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(width: 70, height: 6)
            Text(formatBytes(node.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .tag(node)
        .contextMenu {
            if node.isDirectory {
                Button("Rescan This Folder") { onRescan(node) }
                Divider()
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
}
