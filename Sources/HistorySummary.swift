import Foundation

/// One node of a coarse history summary.
///
/// Children of a node are stored contiguously, so a whole summary is a flat,
/// `Sendable` array of value types — cheap to keep in memory, cheap to hand
/// between tasks, and free of the parent pointers and per-node path strings
/// that make `FileNode` trees expensive.
struct SummaryNode: Sendable {
    let name: String
    let size: Int64
    let isDirectory: Bool
    let firstChild: Int32
    let childCount: Int32
}

/// A pruned, size-ordered snapshot of one archived scan, small enough that the
/// history chart can hold every snapshot in memory at once.
///
/// History only ever shows a folder's largest children, so a summary keeps
/// nodes down to `Limits.threshold`, at most `Limits.maxChildren` per
/// directory and `Limits.maxDepth` levels. Everything dropped is still
/// accounted for: a folder's size minus its kept children is reported as part
/// of the "Other" band, so the stack still sums to the folder total.
struct HistorySummary: Sendable {
    let rootPath: String
    let date: Date
    /// Breadth-first; `nodes[0]` is the scan root.
    let nodes: [SummaryNode]

    enum Limits {
        /// Nodes smaller than `rootSize / relativeDivisor` are dropped…
        static let relativeDivisor: Int64 = 10_000
        /// …but never anything above this floor, so small scans keep detail.
        static let absoluteFloor: Int64 = 1 << 20   // 1 MB
        static let maxChildren = 64
        static let maxDepth = 12

        static func threshold(rootSize: Int64) -> Int64 {
            max(rootSize / relativeDivisor, absoluteFloor)
        }
    }

    /// How many categories a chart shows before the rest collapse into "Other".
    static let categoryLimit = 14

    private var rootPrefix: String {
        rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    }

    /// Index of a folder by absolute path, or nil when it was pruned out of
    /// this snapshot (or did not exist yet when the scan ran).
    func index(ofPath path: String) -> Int? {
        guard !nodes.isEmpty else { return nil }
        if path == rootPath { return 0 }
        let prefix = rootPrefix
        guard path.hasPrefix(prefix) else { return nil }
        var current = 0
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            let node = nodes[current]
            var match: Int?
            for offset in 0..<Int(node.childCount) {
                let candidate = Int(node.firstChild) + offset
                if nodes[candidate].name == component {
                    match = candidate
                    break
                }
            }
            guard let match else { return nil }
            current = match
        }
        return current
    }

    /// The non-overlapping frontier up to `depth` levels below `folderPath`,
    /// largest first, capped with an "Other" bucket — the same shape the full
    /// archive decode produces, plus the pruned remainder folded into "Other".
    /// Returns nil when the folder is not part of this snapshot.
    func categories(folderPath: String, depth: Int) -> [CategorySize]? {
        guard let folder = index(ofPath: folderPath) else { return nil }
        var frontier: [(path: String, node: SummaryNode)] = []
        var remainder: Int64 = 0
        collect(from: folder, path: folderPath, remainingDepth: max(1, depth),
                into: &frontier, remainder: &remainder)
        frontier.sort { $0.node.size > $1.node.size }

        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let capped = frontier.prefix(Self.categoryLimit).map { entry in
            CategorySize(name: entry.path.hasPrefix(prefix)
                             ? String(entry.path.dropFirst(prefix.count))
                             : entry.node.name,
                         size: entry.node.size,
                         path: entry.path,
                         isDirectory: entry.node.isDirectory)
        }
        let rest = frontier.dropFirst(Self.categoryLimit)
            .reduce(remainder) { $0 + $1.node.size }
        return rest > 0 ? capped + [CategorySize(name: "Other", size: rest)] : Array(capped)
    }

    private func collect(from index: Int, path: String, remainingDepth: Int,
                         into result: inout [(path: String, node: SummaryNode)],
                         remainder: inout Int64) {
        let node = nodes[index]
        var kept: Int64 = 0
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for offset in 0..<Int(node.childCount) {
            let childIndex = Int(node.firstChild) + offset
            let child = nodes[childIndex]
            guard child.size > 0 else { continue }
            kept += child.size
            let childPath = prefix + child.name
            if remainingDepth > 1 && child.isDirectory && child.childCount > 0 {
                collect(from: childIndex, path: childPath,
                        remainingDepth: remainingDepth - 1,
                        into: &result, remainder: &remainder)
            } else {
                result.append((childPath, child))
            }
        }
        // What the pruning dropped (and this folder's own small files) still
        // belongs to the folder, so the bands keep summing to its size.
        remainder += max(0, node.size - kept)
    }
}

// MARK: Building

/// Mutable intermediate tree used while pruning. Only surviving nodes are
/// allocated — a few thousand per scan — so this stays tiny next to the
/// millions of nodes in the source archive.
final class SummaryPruneNode {
    let name: String
    let size: Int64
    let isDirectory: Bool
    var children: [SummaryPruneNode] = []

    init(name: String, size: Int64, isDirectory: Bool) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }

    /// Keep only the largest `maxChildren` of every directory. Applied after
    /// the walk so the result does not depend on the order children appear in.
    func capChildren(to maxChildren: Int) {
        if children.count > maxChildren {
            children.sort { $0.size > $1.size }
            children.removeLast(children.count - maxChildren)
        }
        for child in children { child.capChildren(to: maxChildren) }
    }
}

extension HistorySummary {
    /// Prune a live scan tree into a summary (used when archiving a new scan).
    static func build(from root: FileNode, rootPath: String, date: Date) -> HistorySummary {
        let threshold = Limits.threshold(rootSize: root.size)
        let pruned = SummaryPruneNode(name: root.name, size: root.size,
                                      isDirectory: root.isDirectory)
        appendChildren(of: root, to: pruned, depth: 1, threshold: threshold)
        pruned.capChildren(to: Limits.maxChildren)
        return HistorySummary(rootPath: rootPath, date: date, nodes: flatten(pruned))
    }

    private static func appendChildren(of node: FileNode, to pruned: SummaryPruneNode,
                                       depth: Int, threshold: Int64) {
        guard depth <= Limits.maxDepth else { return }
        for child in node.children ?? [] where child.size >= threshold {
            let copy = SummaryPruneNode(name: child.name, size: child.size,
                                        isDirectory: child.isDirectory)
            pruned.children.append(copy)
            if child.isDirectory {
                appendChildren(of: child, to: copy, depth: depth + 1, threshold: threshold)
            }
        }
    }

    /// Breadth-first flattening, which is what makes children contiguous.
    static func flatten(_ root: SummaryPruneNode) -> [SummaryNode] {
        var nodes: [SummaryNode] = []
        var queue: [SummaryPruneNode] = [root]
        var head = 0
        var nextFreeSlot = 1
        while head < queue.count {
            let node = queue[head]
            head += 1
            nodes.append(SummaryNode(name: node.name, size: node.size,
                                     isDirectory: node.isDirectory,
                                     firstChild: Int32(nextFreeSlot),
                                     childCount: Int32(node.children.count)))
            nextFreeSlot += node.children.count
            queue.append(contentsOf: node.children)
        }
        return nodes
    }
}

// MARK: Binary format
//
// Header: "DTM1" | date(Float64 LE) | rootPath(u16 len + UTF8) | count(i32 LE)
// Node (breadth-first): name(u16 len + UTF8) | isDir(u8) | size(i64 LE)
//                       | childCount(i32 LE)

extension HistorySummary {
    static let magic: [UInt8] = [0x44, 0x54, 0x4D, 0x31]   // "DTM1"

    func encoded() -> Data {
        var out = Data()
        out.reserveCapacity(nodes.count * 48 + 64)
        out.append(contentsOf: Self.magic)
        out.appendF64(date.timeIntervalSince1970)
        out.appendString(rootPath)
        out.appendI32(Int32(clamping: nodes.count))
        for node in nodes {
            out.appendString(node.name)
            out.append(node.isDirectory ? 1 : 0)
            out.appendI64(node.size)
            out.appendI32(node.childCount)
        }
        return out
    }

    static func decoded(_ data: Data) -> HistorySummary? {
        data.withUnsafeBytes { raw -> HistorySummary? in
            var reader = ByteReader(raw)
            guard reader.matches(magic: magic),
                  let timestamp = reader.readF64(), timestamp.isFinite,
                  let rootPath = reader.readString(), !rootPath.isEmpty,
                  let rawCount = reader.readI32(), rawCount >= 0 else { return nil }
            let count = Int(rawCount)
            // Each node needs at least 15 bytes, so a corrupt count can never
            // make us reserve an absurd amount of memory.
            guard count <= reader.remaining / 15 + 1 else { return nil }

            var nodes: [SummaryNode] = []
            nodes.reserveCapacity(count)
            var childCounts: [Int] = []
            childCounts.reserveCapacity(count)
            for _ in 0..<count {
                guard let name = reader.readString(),
                      let flag = reader.readByte(), flag <= 1,
                      let size = reader.readI64(), size >= 0,
                      let rawChildren = reader.readI32(), rawChildren >= 0,
                      Int(rawChildren) <= count else { return nil }
                childCounts.append(Int(rawChildren))
                nodes.append(SummaryNode(name: name, size: size,
                                         isDirectory: flag == 1,
                                         firstChild: 0,
                                         childCount: rawChildren))
            }
            guard reader.isAtEnd else { return nil }

            // Breadth-first order makes every node's children contiguous, so
            // the first-child indexes are just a running total.
            var nextFreeSlot = 1
            for index in nodes.indices {
                let children = childCounts[index]
                guard nextFreeSlot + children <= count else { return nil }
                nodes[index] = SummaryNode(name: nodes[index].name,
                                           size: nodes[index].size,
                                           isDirectory: nodes[index].isDirectory,
                                           firstChild: Int32(nextFreeSlot),
                                           childCount: Int32(children))
                nextFreeSlot += children
            }
            return HistorySummary(rootPath: rootPath,
                                  date: Date(timeIntervalSince1970: timestamp),
                                  nodes: nodes)
        }
    }
}
