import Foundation

/// One non-overlapping category in a folder's history chart.
struct CategorySize: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let size: Int64
    /// Absolute path and node type make directory categories drillable. Both are
    /// optional so history indexes written by older versions still decode.
    let path: String?
    let isDirectory: Bool?

    init(name: String, size: Int64, path: String? = nil, isDirectory: Bool? = nil) {
        self.name = name
        self.size = size
        self.path = path
        self.isDirectory = isDirectory
    }

    var identity: String { path ?? name }
    var id: String { identity }
    var canDrillDown: Bool { isDirectory == true && path != nil }
}

/// One folder's child breakdown at a point in time (for the history chart).
struct HistorySample: Sendable {
    let date: Date
    let categories: [CategorySize]
}

enum ScheduledScanOutcome: String, Codable, Sendable {
    case running
    case succeeded
    case failed
}

struct ScheduledScanStatus: Codable, Sendable {
    let startedAt: Date
    let finishedAt: Date?
    let outcome: ScheduledScanOutcome
    let message: String
    /// Present for running scans written by current helpers. Optional so status
    /// files from earlier builds remain decodable.
    let processID: Int32?
}

/// One archived scan in the (append-only) history.
struct ScanHistoryEntry: Codable, Identifiable, Sendable {
    let file: String        // filename within the history directory
    let date: Date
    let rootPath: String
    let totalSize: Int64
    let fileCount: Int
    /// Top-level breakdown, stored inline for backward compatibility and the
    /// one-level fast path.
    var categories: [CategorySize]?
    var id: String { file }
}

/// Persists the most recent scan (so the app reopens with results) and keeps an
/// append-only, compressed archive of every completed scan so past scans can be
/// compared later.
///
/// Uses a compact custom binary format rather than a plist: restoring a large
/// (multi-million-node) `/` scan went from ~87s to ~1s. Files are LZFSE-
/// compressed; a 1-byte header records whether the payload is compressed.
enum ScanStore {
    /// Preserves save order so a slower, older save cannot overwrite a newer
    /// snapshot. Encoding happens on the main actor; only compression and I/O
    /// run here, so background work never reads a tree while the UI mutates it.
    private static let writeQueue = DispatchQueue(label: "com.libjch.disktree.persistence",
                                                   qos: .utility)

    // MARK: Locations

    static var dataDirectory: URL {
        // Tests/dev can redirect all persistence to a throwaway directory via
        // DISKTREE_DATA_DIR, so nothing ever needs to delete the real one.
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["DISKTREE_DATA_DIR"] {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
                .appendingPathComponent("DiskTree", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var currentURL: URL { dataDirectory.appendingPathComponent("lastScan.dtscan") }
    private static var historyDir: URL {
        let dir = dataDirectory.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexURL: URL { historyDir.appendingPathComponent("index.json") }
    private static var scheduledStatusURL: URL {
        dataDirectory.appendingPathComponent("scheduled-scan-status.json")
    }

    // MARK: Save current (fast-launch copy)

    @MainActor
    static func saveCurrent(_ root: FileNode, date: Date) {
        let encoded = encodeTree(rootPath: root.path, date: date, root: root)
        writeQueue.async {
            let payload = pack(encoded)
            try? payload.write(to: currentURL, options: .atomic)
        }
    }

    // MARK: Archive to history (kept forever)

    @MainActor
    static func archive(_ root: FileNode, date: Date) {
        HistoryBackup.ensureBackup(dataDirectory: dataDirectory)
        let rootPath = root.path
        let stamp = Int64(date.timeIntervalSince1970 * 1_000)
        let name = "\(stamp)_\(UUID().uuidString)_\(sanitize(rootPath)).dtscan"
        let entry = ScanHistoryEntry(file: name, date: date, rootPath: rootPath,
                                     totalSize: root.size, fileCount: root.fileCount,
                                     categories: categories(of: root, depth: 1))
        // Update the (small) index right away so the history is immediately
        // available; write the heavy tree archive off-main.
        var index = readIndex()
        index.append(entry)
        writeIndex(index)

        // Both encodings read the tree while the main actor owns it; only
        // compression and I/O move to the background.
        let encoded = encodeTree(rootPath: rootPath, date: date, root: root)
        let summary = HistorySummary.build(from: root, rootPath: rootPath, date: date)
            .encoded()
        writeQueue.async {
            let payload = pack(encoded)
            try? payload.write(to: historyDir.appendingPathComponent(name), options: .atomic)
            writeSummaryPayload(pack(summary), forArchive: name)
        }
    }

    /// Persist a completed helper scan before the short-lived helper exits.
    /// The archive file is committed before its index entry becomes visible.
    static func saveAndArchiveSynchronously(_ root: FileNode, date: Date) throws {
        HistoryBackup.ensureBackup(dataDirectory: dataDirectory)
        let rootPath = root.path
        let stamp = Int64(date.timeIntervalSince1970 * 1_000)
        let name = "\(stamp)_\(UUID().uuidString)_\(sanitize(rootPath)).dtscan"
        let entry = ScanHistoryEntry(file: name, date: date, rootPath: rootPath,
                                     totalSize: root.size, fileCount: root.fileCount,
                                     categories: categories(of: root, depth: 1))
        let payload = pack(encodeTree(rootPath: rootPath, date: date, root: root))
        let summary = pack(HistorySummary.build(from: root, rootPath: rootPath,
                                                date: date).encoded())

        try payload.write(to: currentURL, options: .atomic)
        try payload.write(to: historyDir.appendingPathComponent(name), options: .atomic)
        writeSummaryPayload(summary, forArchive: name)
        var index = readIndex()
        index.append(entry)
        try writeIndexThrowing(index)
    }

    static func scheduledScanStatus() -> ScheduledScanStatus? {
        guard let data = try? Data(contentsOf: scheduledStatusURL) else { return nil }
        return try? JSONDecoder().decode(ScheduledScanStatus.self, from: data)
    }

    static func writeScheduledScanStatus(_ status: ScheduledScanStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: scheduledStatusURL, options: .atomic)
    }

    /// A non-overlapping frontier up to `depth` levels below `root`, largest
    /// first and capped with an "Other" bucket. Descending replaces a folder
    /// with its children, so category sizes still add up to the folder total.
    private static func categories(of root: FileNode, depth: Int) -> [CategorySize] {
        var nodes: [FileNode] = []
        collectCategories(from: root, remainingDepth: max(1, depth), into: &nodes)
        nodes.sort { $0.size > $1.size }

        let capped = nodes.prefix(14).map { node in
            CategorySize(name: relativePath(of: node, below: root),
                         size: node.size, path: node.path,
                         isDirectory: node.isDirectory)
        }
        let rest = nodes.dropFirst(14).reduce(Int64(0)) { $0 + $1.size }
        return rest > 0
            ? capped + [CategorySize(name: "Other", size: rest)]
            : Array(capped)
    }

    private static func collectCategories(from node: FileNode, remainingDepth: Int,
                                          into result: inout [FileNode]) {
        for child in (node.children ?? []).filter({ $0.size > 0 }) {
            let children = child.children?.contains { $0.size > 0 } ?? false
            if remainingDepth > 1 && child.isDirectory && children {
                collectCategories(from: child, remainingDepth: remainingDepth - 1,
                                  into: &result)
            } else {
                result.append(child)
            }
        }
    }

    private static func relativePath(of node: FileNode, below root: FileNode) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard node.path.hasPrefix(prefix) else { return node.name }
        return String(node.path.dropFirst(prefix.count))
    }

    /// All archived scans, newest first.
    static func history() -> [ScanHistoryEntry] {
        readIndex().sorted { $0.date > $1.date }
    }

    /// Archived scans of one folder, oldest first (for plotting over time).
    static func history(forRootPath path: String) -> [ScanHistoryEntry] {
        readIndex().filter { $0.rootPath == path }.sorted { $0.date < $1.date }
    }

    static func loadArchived(_ entry: ScanHistoryEntry) -> (root: FileNode, date: Date)? {
        guard let raw = try? Data(contentsOf: historyDir.appendingPathComponent(entry.file)),
              let unpacked = unpack(raw)
        else { return nil }
        return decodeTree(unpacked)
    }

    /// Exact child breakdown for one archived scan, by fully decoding it.
    /// The history chart uses summaries instead; this remains the reference
    /// implementation they are verified against, and the fallback for an
    /// archive whose summary cannot be built. Decoding a `/` scan takes
    /// seconds and hundreds of MB, so never call it on the main thread.
    static func folderHistorySample(entry: ScanHistoryEntry, folderPath: String,
                                    depth: Int) -> HistorySample? {
        if folderPath == entry.rootPath && depth == 1,
           let inline = entry.categories,
           inline.allSatisfy({ categoryHasPathMetadata($0) }) {
            return HistorySample(date: entry.date, categories: inline)
        }
        guard let (root, date) = loadArchived(entry),
              let node = findNode(root, path: folderPath) else { return nil }
        return HistorySample(date: date, categories: categories(of: node, depth: depth))
    }

    private static func categoryHasPathMetadata(_ category: CategorySize) -> Bool {
        (category.path != nil && category.isDirectory != nil) || category.name == "Other"
    }

    /// Locate a node by its absolute path within an archived tree.
    private static func findNode(_ node: FileNode, path: String) -> FileNode? {
        if node.path == path { return node }
        for child in node.children ?? [] where path == child.path || path.hasPrefix(child.path + "/") {
            return findNode(child, path: path)
        }
        return nil
    }

    // MARK: Load current

    static func load() -> (root: FileNode, date: Date)? {
        guard let raw = try? Data(contentsOf: currentURL),
              let unpacked = unpack(raw) else { return nil }
        return decodeTree(unpacked)
    }

    // MARK: Compression envelope (1-byte header: 1 = LZFSE, 0 = raw)

    private static func pack(_ blob: Data) -> Data {
        if let c = (try? (blob as NSData).compressed(using: .lzfse)) as Data?, c.count < blob.count {
            return Data([1]) + c
        }
        return Data([0]) + blob
    }
    private static func unpack(_ data: Data) -> Data? {
        guard let flag = data.first else { return nil }
        let body = Data(data.dropFirst())
        switch flag {
        case 0:
            return body
        case 1:
            return (try? (body as NSData).decompressed(using: .lzfse)) as Data?
        default:
            return nil
        }
    }

    // MARK: Binary tree format
    //
    // Header: "DTS1" | date(Float64 LE) | rootPath(u16 len + UTF8)
    // Node (pre-order DFS): name(u16 len + UTF8) | isDir(u8) | size(i64 LE)
    //                       | fileCount(i32 LE) | childCount(i32 LE) | children…

    private static func encodeTree(rootPath: String, date: Date, root: FileNode) -> Data {
        var out = Data()
        let (estimated, overflow) = root.fileCount.multipliedReportingOverflow(by: 24)
        if !overflow { out.reserveCapacity(estimated + 4096) }
        out.append(contentsOf: treeMagic)                          // "DTS1"
        out.appendF64(date.timeIntervalSince1970)
        out.appendString(rootPath)
        encodeNode(root, &out)
        return out
    }

    private static func encodeNode(_ n: FileNode, _ out: inout Data) {
        out.appendString(n.name)
        out.append(n.isDirectory ? 1 : 0)
        out.appendI64(n.size)
        let kids = n.children ?? []
        out.appendI32(Int32(clamping: n.fileCount))
        out.appendI32(Int32(clamping: kids.count))
        for c in kids { encodeNode(c, &out) }
    }

    private static let treeMagic: [UInt8] = [0x44, 0x54, 0x53, 0x31]   // "DTS1"

    /// Smallest possible encoded node (empty name, no children). Used to
    /// reject corrupt child counts before reserving memory for them.
    private static let minimumNodeBytes = 19

    private static func decodeTree(_ data: Data) -> (root: FileNode, date: Date)? {
        data.withUnsafeBytes { raw -> (FileNode, Date)? in
            var reader = ByteReader(raw)
            guard reader.matches(magic: treeMagic),
                  let timestamp = reader.readF64(),
                  timestamp.isFinite,
                  let rootPath = reader.readString(),
                  !rootPath.isEmpty,
                  let root = decodeNode(&reader, parentPath: nil, ownPath: rootPath,
                                        parent: nil),
                  reader.isAtEnd else { return nil }
            return (root, Date(timeIntervalSince1970: timestamp))
        }
    }

    /// Decode one node. The root passes `ownPath`; every child derives its path
    /// from its parent's and the name read here, so the name is materialized
    /// exactly once.
    private static func decodeNode(_ reader: inout ByteReader, parentPath: String?,
                                   ownPath: String?, parent: FileNode?) -> FileNode? {
        guard let header = readNodeHeader(&reader) else { return nil }
        let name = reader.string(in: header.nameRange)
        guard header.isDirectory || header.childCount == 0 else { return nil }

        let path: String
        if let ownPath {
            path = ownPath
        } else if let parentPath {
            path = (parentPath.hasSuffix("/") ? parentPath : parentPath + "/") + name
        } else {
            return nil
        }

        let node = FileNode(path: path, name: name, isDirectory: header.isDirectory)
        node.size = header.size
        node.fileCount = header.fileCount
        node.parent = parent
        if header.isDirectory {
            var kids: [FileNode] = []
            kids.reserveCapacity(header.childCount)
            for _ in 0..<header.childCount {
                guard let child = decodeNode(&reader, parentPath: path, ownPath: nil,
                                             parent: node) else { return nil }
                kids.append(child)
            }
            node.children = kids
        }
        return node
    }

    /// Fixed-size part of a node, with the name left in the buffer so callers
    /// that are about to discard the node never allocate a `String` for it.
    private struct NodeHeader {
        let nameRange: Range<Int>
        let isDirectory: Bool
        let size: Int64
        let fileCount: Int
        let childCount: Int
    }

    private static func readNodeHeader(_ reader: inout ByteReader) -> NodeHeader? {
        guard let nameRange = reader.readStringRange(),
              let directoryFlag = reader.readByte(),
              directoryFlag <= 1,
              let size = reader.readI64(),
              size >= 0,
              let rawFileCount = reader.readI32(),
              rawFileCount >= 0,
              let rawChildCount = reader.readI32(),
              rawChildCount >= 0,
              Int(rawChildCount) <= reader.remaining / minimumNodeBytes else { return nil }
        return NodeHeader(nameRange: nameRange, isDirectory: directoryFlag == 1,
                          size: size, fileCount: Int(rawFileCount),
                          childCount: Int(rawChildCount))
    }

    // MARK: History summaries

    private static var summariesDir: URL {
        let dir = historyDir.appendingPathComponent("summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func summaryURL(forArchive file: String) -> URL {
        summariesDir.appendingPathComponent(file + ".dtsum")
    }

    static func hasSummary(forArchive file: String) -> Bool {
        FileManager.default.fileExists(atPath: summaryURL(forArchive: file).path)
    }

    private static func writeSummaryPayload(_ payload: Data, forArchive file: String) {
        try? payload.write(to: summaryURL(forArchive: file), options: .atomic)
    }

    static func loadSummary(forArchive file: String) -> HistorySummary? {
        guard let raw = try? Data(contentsOf: summaryURL(forArchive: file)),
              let unpacked = unpack(raw) else { return nil }
        return HistorySummary.decoded(unpacked)
    }

    /// Build the summary for an archive written before summaries existed and
    /// store it. The `.dtscan` file itself is only ever read.
    static func buildSummary(forArchive entry: ScanHistoryEntry) -> HistorySummary? {
        HistoryBackup.ensureBackup(dataDirectory: dataDirectory)
        guard let summary = summary(fromArchive: entry.file) else { return nil }
        writeSummaryPayload(pack(summary.encoded()), forArchive: entry.file)
        return summary
    }

    /// Stream a `.dtscan` archive into a summary: one pass over the
    /// decompressed bytes, pruning as it goes, with no `FileNode`, no path
    /// strings and no allocation at all for the subtrees it discards.
    private static func summary(fromArchive file: String) -> HistorySummary? {
        guard let raw = try? Data(contentsOf: historyDir.appendingPathComponent(file)),
              let unpacked = unpack(raw) else { return nil }
        return unpacked.withUnsafeBytes { bytes -> HistorySummary? in
            var reader = ByteReader(bytes)
            guard reader.matches(magic: treeMagic),
                  let timestamp = reader.readF64(),
                  timestamp.isFinite,
                  let rootPath = reader.readString(),
                  !rootPath.isEmpty,
                  let header = readNodeHeader(&reader),
                  header.isDirectory || header.childCount == 0 else { return nil }

            let threshold = HistorySummary.Limits.threshold(rootSize: header.size)
            let root = SummaryPruneNode(name: reader.string(in: header.nameRange),
                                        size: header.size,
                                        isDirectory: header.isDirectory)
            guard pruneChildren(count: header.childCount, into: root, depth: 1,
                                threshold: threshold, reader: &reader),
                  reader.isAtEnd else { return nil }
            root.capChildren(to: HistorySummary.Limits.maxChildren)
            return HistorySummary(rootPath: rootPath,
                                  date: Date(timeIntervalSince1970: timestamp),
                                  nodes: HistorySummary.flatten(root))
        }
    }

    private static func pruneChildren(count: Int, into parent: SummaryPruneNode,
                                      depth: Int, threshold: Int64,
                                      reader: inout ByteReader) -> Bool {
        for _ in 0..<count {
            guard let header = readNodeHeader(&reader) else { return false }
            // A child is never larger than its parent, so a subtree below the
            // threshold (or past the depth limit) can be skipped wholesale.
            if header.size >= threshold && depth <= HistorySummary.Limits.maxDepth {
                let node = SummaryPruneNode(name: reader.string(in: header.nameRange),
                                            size: header.size,
                                            isDirectory: header.isDirectory)
                parent.children.append(node)
                guard pruneChildren(count: header.childCount, into: node,
                                    depth: depth + 1, threshold: threshold,
                                    reader: &reader) else { return false }
            } else {
                guard skipSubtrees(count: header.childCount, reader: &reader)
                else { return false }
            }
        }
        return true
    }

    /// Walk past `count` sibling subtrees without building anything.
    private static func skipSubtrees(count: Int, reader: inout ByteReader) -> Bool {
        var pending = count
        while pending > 0 {
            guard let header = readNodeHeader(&reader) else { return false }
            pending += header.childCount - 1
        }
        return true
    }

    // MARK: Misc

    private static func readIndex() -> [ScanHistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data)
        else { return [] }
        return list
    }

    private static func writeIndex(_ index: [ScanHistoryEntry]) {
        try? writeIndexThrowing(index)
    }

    private static func writeIndexThrowing(_ index: [ScanHistoryEntry]) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func sanitize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safe = trimmed.isEmpty ? "root" : trimmed
        return String(safe.map { "/: ".contains($0) ? "-" : $0 }.prefix(80))
    }
}
