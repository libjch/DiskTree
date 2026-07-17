import Foundation

/// A top-level folder's size at scan time (for the history chart).
struct CategorySize: Codable, Hashable {
    let name: String
    let size: Int64
}

/// One archived scan in the (append-only) history.
struct ScanHistoryEntry: Codable, Identifiable {
    let file: String        // filename within the history directory
    let date: Date
    let rootPath: String
    let totalSize: Int64
    let fileCount: Int
    /// Top-level breakdown, stored inline so the history chart doesn't need to
    /// decode full archives. Optional for backward compatibility.
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

    private static var baseDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("DiskTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var currentURL: URL { baseDir.appendingPathComponent("lastScan.dtscan") }
    private static var historyDir: URL {
        let dir = baseDir.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexURL: URL { historyDir.appendingPathComponent("index.json") }

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
        let rootPath = root.path
        let stamp = Int64(date.timeIntervalSince1970 * 1_000)
        let name = "\(stamp)_\(UUID().uuidString)_\(sanitize(rootPath)).dtscan"
        let entry = ScanHistoryEntry(file: name, date: date, rootPath: rootPath,
                                     totalSize: root.size, fileCount: root.fileCount,
                                     categories: topCategories(of: root))
        // Update the (small) index right away so the history is immediately
        // available; write the heavy tree archive off-main.
        var index = readIndex()
        index.append(entry)
        writeIndex(index)

        let encoded = encodeTree(rootPath: rootPath, date: date, root: root)
        writeQueue.async {
            let payload = pack(encoded)
            try? payload.write(to: historyDir.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Top-level folders (largest first, capped with an "Other" bucket) for the
    /// history chart.
    private static func topCategories(of root: FileNode) -> [CategorySize] {
        let kids = (root.children ?? []).filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let capped = kids.prefix(14).map { CategorySize(name: $0.name, size: $0.size) }
        let rest = kids.dropFirst(14).reduce(Int64(0)) { $0 + $1.size }
        return rest > 0 ? capped + [CategorySize(name: "Other", size: rest)] : Array(capped)
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
        out.append(contentsOf: [0x44, 0x54, 0x53, 0x31])           // "DTS1"
        appendF64(date.timeIntervalSince1970, &out)
        appendStr(rootPath, &out)
        encodeNode(root, &out)
        return out
    }

    private static func encodeNode(_ n: FileNode, _ out: inout Data) {
        appendStr(n.name, &out)
        out.append(n.isDirectory ? 1 : 0)
        appendI64(n.size, &out)
        let kids = n.children ?? []
        appendI32(Int32(clamping: n.fileCount), &out)
        appendI32(Int32(clamping: kids.count), &out)
        for c in kids { encodeNode(c, &out) }
    }

    private static func decodeTree(_ data: Data) -> (root: FileNode, date: Date)? {
        var cursor = DecodeCursor(data)
        guard cursor.readBytes(count: 4) == [0x44, 0x54, 0x53, 0x31],
              let timestamp = cursor.readF64(),
              timestamp.isFinite,
              let rootPath = cursor.readString(),
              !rootPath.isEmpty,
              let root = decodeNode(&cursor, path: rootPath, parent: nil),
              cursor.isAtEnd else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return (root, date)
    }

    private static func decodeNode(_ cursor: inout DecodeCursor, path: String,
                                   parent: FileNode?) -> FileNode? {
        guard let name = cursor.readString(),
              let directoryFlag = cursor.readByte(),
              directoryFlag <= 1,
              let size = cursor.readI64(),
              size >= 0,
              let rawFileCount = cursor.readI32(),
              rawFileCount >= 0,
              let rawChildCount = cursor.readI32(),
              rawChildCount >= 0 else { return nil }
        let isDir = directoryFlag == 1
        let fileCount = Int(rawFileCount)
        let childCount = Int(rawChildCount)
        // Every encoded node needs at least 19 bytes. This both rejects corrupt
        // counts and avoids reserving attacker-controlled amounts of memory.
        guard childCount <= cursor.remaining / 19,
              isDir || childCount == 0 else { return nil }

        let node = FileNode(path: path, name: name, isDirectory: isDir)
        node.size = size
        node.fileCount = fileCount
        node.parent = parent
        if isDir {
            var kids: [FileNode] = []
            kids.reserveCapacity(childCount)
            for _ in 0..<childCount {
                guard let child = decodeChild(&cursor, parentPath: path, parent: node)
                else { return nil }
                kids.append(child)
            }
            node.children = kids
        }
        return node
    }

    /// A child's path is parent + "/" + its name (read inside).
    private static func decodeChild(_ cursor: inout DecodeCursor, parentPath: String,
                                    parent: FileNode) -> FileNode? {
        let start = cursor.index
        guard let name = cursor.readString() else { return nil }
        cursor.index = start
        let separator = parentPath.hasSuffix("/") ? "" : "/"
        return decodeNode(&cursor, path: parentPath + separator + name, parent: parent)
    }

    // MARK: Byte helpers

    private static func appendStr(_ s: String, _ out: inout Data) {
        let bytes = Array(s.utf8)
        appendU16(UInt16(min(bytes.count, 0xFFFF)), &out)
        out.append(contentsOf: bytes.prefix(0xFFFF))
    }
    private static func appendU16(_ v: UInt16, _ out: inout Data) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
    }
    private static func appendI32(_ v: Int32, _ out: inout Data) {
        var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
    private static func appendI64(_ v: Int64, _ out: inout Data) {
        var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
    private static func appendF64(_ v: Double, _ out: inout Data) {
        appendI64(Int64(bitPattern: v.bitPattern), &out)
    }

    private struct DecodeCursor {
        private let bytes: [UInt8]
        fileprivate var index = 0

        init(_ data: Data) {
            bytes = Array(data)
        }

        var remaining: Int { bytes.count - index }
        var isAtEnd: Bool { index == bytes.count }

        mutating func readByte() -> UInt8? {
            guard remaining >= 1 else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func readBytes(count: Int) -> [UInt8]? {
            guard count >= 0, remaining >= count else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        mutating func readString() -> String? {
            guard let lengthBytes = readBytes(count: 2) else { return nil }
            let count = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
            guard let value = readBytes(count: count) else { return nil }
            return String(bytes: value, encoding: .utf8)
        }

        mutating func readI32() -> Int32? {
            guard let value = readBytes(count: 4) else { return nil }
            var bits: UInt32 = 0
            for offset in 0..<4 {
                bits |= UInt32(value[offset]) << UInt32(8 * offset)
            }
            return Int32(bitPattern: bits)
        }

        mutating func readI64() -> Int64? {
            guard let value = readBytes(count: 8) else { return nil }
            var bits: UInt64 = 0
            for offset in 0..<8 {
                bits |= UInt64(value[offset]) << UInt64(8 * offset)
            }
            return Int64(bitPattern: bits)
        }

        mutating func readF64() -> Double? {
            guard let value = readI64() else { return nil }
            return Double(bitPattern: UInt64(bitPattern: value))
        }
    }

    // MARK: Misc

    private static func readIndex() -> [ScanHistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data)
        else { return [] }
        return list
    }

    private static func writeIndex(_ index: [ScanHistoryEntry]) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func sanitize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safe = trimmed.isEmpty ? "root" : trimmed
        return String(safe.map { "/: ".contains($0) ? "-" : $0 }.prefix(80))
    }
}
