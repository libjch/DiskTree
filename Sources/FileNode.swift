import Foundation

/// A node in the scanned file tree. Reference type so the tree view and the
/// treemap can share the same instances and selection can be identity-based.
// Nodes cross concurrency boundaries in two controlled ways: ScanEngine owns and
// synchronizes its live tree, and completed/snapshot trees are handed to the main
// actor. Persistence captures a complete binary snapshot on the main actor before
// doing compression and file I/O in the background.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    /// Full filesystem path. Stored as a String (not a URL) because building
    /// millions of URLs when restoring a large saved scan is dramatically slower
    /// than string work — the URL is derived lazily only when actually needed.
    let path: String
    let name: String
    let isDirectory: Bool

    /// Total size in bytes (allocated on disk), including all descendants.
    var size: Int64 = 0
    /// Number of files contained (including self if a file).
    var fileCount: Int = 0

    /// Child nodes, sorted by size descending. `nil` for files (leaves).
    var children: [FileNode]?

    weak var parent: FileNode?

    init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }

    convenience init(url: URL, name: String, isDirectory: Bool) {
        self.init(path: url.path, name: name, isDirectory: isDirectory)
    }

    /// Derived on demand from the stored path.
    var url: URL { URL(fileURLWithPath: path) }

    // Identity is the path, so SwiftUI reuses a row across progressive scan
    // snapshots (which rebuild the tree) instead of tearing it down and
    // recreating it — that teardown is what made the outline blink.
    var id: String { path }

    /// Fraction of the parent's size this node represents (0...1).
    var fractionOfParent: Double {
        guard let parent, parent.size > 0 else { return 1 }
        return Double(size) / Double(parent.size)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Human-readable byte formatting (e.g. "1.4 GB").
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useAll]
    return formatter.string(fromByteCount: bytes)
}
