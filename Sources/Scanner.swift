import Foundation
import Combine
import Darwin

/// Uniquely identifies a file/directory on this machine: same (device, inode)
/// means the same on-disk object reached via a different path.
private struct InodeKey: Hashable {
    let dev: Int64
    let ino: UInt64
}

/// Look up a path's (device, inode) without following symlinks.
private func inodeKey(for url: URL) -> InodeKey? {
    var st = stat()
    let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return lstat(path, &st) == 0
    }
    guard ok else { return nil }
    return InodeKey(dev: Int64(st.st_dev), ino: UInt64(st.st_ino))
}

// Keys fetched for every item during the walk.
private let scanResourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .isRegularFileKey,
    .totalFileAllocatedSizeKey,
    .fileAllocatedSizeKey,
    .fileSizeKey,
    .nameKey,
]

/// How often, at most, a partial snapshot of the growing tree is pushed to the
/// UI during a scan. Raise this for fewer refreshes on huge scans; lower it for
/// a livelier treemap. Snapshotting is O(tree size) each time.
private let snapshotInterval: TimeInterval = 2.0

/// Drives a parallel disk scan on a background worker pool and publishes a tree
/// of `FileNode`s plus live progress. The interface (scan/cancel + @Published
/// state) is unchanged from the single-threaded version.
@MainActor
final class Scanner: ObservableObject {
    @Published var root: FileNode?
    /// Progressively updated snapshot shown while `isScanning` is true.
    @Published var partialRoot: FileNode?
    @Published var isScanning = false
    @Published var scannedItems = 0
    @Published var currentPath = ""
    @Published var errorMessage: String?
    /// Path of the folder currently being re-scanned in place (nil when none).
    @Published var rescanningPath: String?
    /// When the currently shown results were produced (for "scanned …" display).
    @Published var lastScanDate: Date?
    /// True while restoring the saved scan on launch.
    @Published var isLoadingSaved = false

    private var task: Task<Void, Never>?
    private var engine: ScanEngine?
    /// Bumped whenever a scan is started or cancelled, so a superseded scan's
    /// late UI updates can be recognized and dropped.
    private var generation = 0

    func scan(_ url: URL) {
        cancel()                 // supersede any running scan (bumps generation)
        let gen = generation
        isScanning = true
        scannedItems = 0
        currentPath = url.path
        errorMessage = nil
        root = nil
        partialRoot = nil

        let rootURL = url
        let engine = ScanEngine(rootURL: rootURL, generation: gen)
        engine.onProgress = { [weak self] partial, count, path in
            self?.publishProgress(gen: gen, partial: partial, count: count, path: path)
        }
        self.engine = engine

        task = Task.detached(priority: .userInitiated) {
            let result = engine.run()
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.root = result.root
                self.partialRoot = nil
                self.scannedItems = result.count
                self.isScanning = false
                self.currentPath = ""
                if let finished = result.root {
                    self.persist(finished)
                    // Archive this scan to the append-only history (kept forever).
                    ScanStore.archive(finished, date: self.lastScanDate ?? Date())
                } else {
                    self.errorMessage = "Couldn't read \(rootURL.path). It may require Full Disk Access in System Settings › Privacy & Security."
                }
            }
        }
    }

    func cancel() {
        engine?.requestCancel()
        engine = nil
        task?.cancel()
        task = nil
        generation += 1          // invalidate any in-flight updates
        if isScanning { isScanning = false }
    }

    /// Record the current tree as the last scan and persist it to disk (the
    /// fast-launch copy). Does not add to history — call `archive` for that.
    func persist(_ root: FileNode) {
        let date = Date()
        lastScanDate = date
        ScanStore.saveCurrent(root, date: date)
    }

    /// On launch, restore the last scan (if any) so the app isn't empty. Only
    /// applies when nothing is loaded or scanning.
    func loadSaved() {
        guard root == nil, !isScanning else { return }
        isLoadingSaved = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = ScanStore.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingSaved = false
                guard self.root == nil, !self.isScanning, let loaded else { return }
                self.root = loaded.root
                self.lastScanDate = loaded.date
            }
        }
    }

    /// Re-scan a single folder in place and splice the fresh result back into the
    /// existing tree, updating ancestor sizes — so you can refresh one part
    /// without re-scanning everything.
    func rescanSubtree(_ target: FileNode) {
        guard !isScanning, rescanningPath == nil, target.isDirectory else { return }
        let url = target.url
        let gen = generation
        rescanningPath = url.path

        Task.detached(priority: .userInitiated) { [weak self] in
            let engine = ScanEngine(rootURL: url, generation: gen)
            let result = engine.run()
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.rescanningPath = nil }
                // Bail if a full scan started/finished meanwhile (tree replaced).
                guard gen == self.generation else { return }
                if !FileManager.default.fileExists(atPath: target.path) {
                    // The folder is gone — drop it and reclaim its size.
                    self.remove(target)
                } else if let fresh = result.root {
                    self.splice(fresh, into: target)
                }
                // else: present but unreadable (e.g. permissions) — leave as-is.
            }
        }
    }

    /// Remove a node from the tree, rolling its freed size/count up the ancestors.
    private func remove(_ node: FileNode) {
        guard let parent = node.parent else {
            // The scanned root itself is gone.
            root = nil
            lastScanDate = nil
            return
        }
        let dSize = node.size
        let dCount = node.fileCount
        var ancestor: FileNode? = parent
        while let a = ancestor {
            a.size -= dSize
            a.fileCount -= dCount
            a.children?.sort { $0.size > $1.size }
            ancestor = a.parent
        }
        parent.children?.removeAll { $0 === node }
        objectWillChange.send()
        if let root { persist(root) }
    }

    /// Replace `target`'s subtree with `fresh`, roll the size/count delta up the
    /// ancestor chain, and re-sort affected levels.
    private func splice(_ fresh: FileNode, into target: FileNode) {
        let dSize = fresh.size - target.size
        let dCount = fresh.fileCount - target.fileCount

        target.children = fresh.children
        for c in target.children ?? [] { c.parent = target }
        target.size = fresh.size
        target.fileCount = fresh.fileCount

        var ancestor: FileNode? = target.parent
        while let node = ancestor {
            node.size += dSize
            node.fileCount += dCount
            node.children?.sort { $0.size > $1.size }
            ancestor = node.parent
        }
        objectWillChange.send()
        if let root = self.root { persist(root) }   // keep the saved copy current
    }

    private nonisolated func publishProgress(gen: Int, partial: FileNode?, count: Int, path: String) {
        Task { @MainActor [weak self] in
            guard let self, gen == self.generation else { return }
            if let partial { self.partialRoot = partial }
            self.scannedItems = count
            self.currentPath = path
        }
    }
}

/// Parallel directory-tree scanner.
///
/// Concurrency design: each directory is a unit of work processed by exactly one
/// worker, which reads its entries and assigns that node's `children` array once.
/// So no two workers ever touch the same node — the tree is partitioned by
/// ownership. The only shared state is the work queue, the progress counters, and
/// the snapshot read, all guarded by a single `NSCondition`. File I/O (the slow
/// part) happens entirely outside the lock.
// All mutable engine state and its live tree are protected by `cond`. The final
// result and snapshots are no longer mutated by the engine after publication.
private final class ScanEngine: @unchecked Sendable {
    struct Result: Sendable { let root: FileNode?; let count: Int }

    let rootURL: URL
    let generation: Int
    var onProgress: ((FileNode?, Int, String) -> Void)?

    private let cond = NSCondition()
    private var stack: [(URL, FileNode)] = []   // directories awaiting processing
    private var pending = 0                      // enqueued-but-unfinished directories
    private var cancelled = false
    /// Directories already counted, so firmlinks / bind mounts / hard-linked
    /// directories aren't traversed (and counted) twice. Guarded by `cond`.
    private var visited = Set<InodeKey>()
    private var counter = 0
    private var lastPath = ""
    private var rootNode: FileNode?
    private var lastSnapshot = Date()

    // Balance parallelism against I/O saturation; a handful of workers hides
    // syscall latency without thrashing.
    private let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

    init(rootURL: URL, generation: Int) {
        self.rootURL = rootURL
        self.generation = generation
    }

    func requestCancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    func run() -> Result {
        let values = try? rootURL.resourceValues(forKeys: scanResourceKeys)
        let isDir = values?.isDirectory ?? false
        let name = values?.name ?? rootURL.lastPathComponent
        let root = FileNode(url: rootURL, name: name.isEmpty ? rootURL.path : name, isDirectory: isDir)
        rootNode = root

        if !isDir {
            // A single file (or an unreadable path). Confirm we can stat it.
            if values == nil { return Result(root: nil, count: 0) }
            root.size = Int64(values?.totalFileAllocatedSize
                ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
            root.fileCount = 1
            return Result(root: root, count: 1)
        }

        // Verify the root directory is actually listable; otherwise report error.
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [])
        } catch {
            return Result(root: nil, count: 0)
        }

        cond.lock()
        if let key = inodeKey(for: rootURL) { visited.insert(key) }
        stack.append((rootURL, root))
        pending = 1
        cond.unlock()

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for _ in 0..<workerCount {
            group.enter()
            queue.async { self.workerLoop(); group.leave() }
        }
        group.wait()

        if cancelled { return Result(root: nil, count: counter) }
        return Result(root: deepCopySorted(root), count: counter)
    }

    private func workerLoop() {
        while true {
            cond.lock()
            while stack.isEmpty && pending > 0 && !cancelled { cond.wait() }
            if cancelled || (stack.isEmpty && pending == 0) {
                cond.unlock()
                return
            }
            let (url, node) = stack.removeLast()
            cond.unlock()

            process(url, node)

            cond.lock()
            pending -= 1
            if pending == 0 { cond.broadcast() }   // wake the others to exit
            cond.unlock()
        }
    }

    /// Read one directory's entries (outside the lock), then publish the results
    /// and enqueue subdirectories (inside the lock).
    private func process(_ url: URL, _ node: FileNode) {
        cond.lock(); let stop = cancelled; cond.unlock()
        if stop { return }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: []
        )) ?? []

        var fileChildren: [FileNode] = []
        // Directory candidates with their inode key (lstat'd outside the lock).
        var dirCandidates: [(node: FileNode, url: URL, key: InodeKey?)] = []

        for entry in entries {
            let v = try? entry.resourceValues(forKeys: scanResourceKeys)
            // Never follow symlinks.
            if v?.isSymbolicLink == true { continue }
            let isDir = v?.isDirectory ?? false
            let cname = v?.name ?? entry.lastPathComponent
            let child = FileNode(url: entry, name: cname.isEmpty ? entry.path : cname, isDirectory: isDir)
            child.parent = node
            if isDir {
                dirCandidates.append((child, entry, inodeKey(for: entry)))
            } else {
                child.size = Int64(v?.totalFileAllocatedSize
                    ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
                child.fileCount = 1
                fileChildren.append(child)
            }
        }

        cond.lock()
        var children = fileChildren
        var enqueued = 0
        for c in dirCandidates {
            // Skip a directory already reached via another path (firmlink, bind
            // mount, hard-linked dir) so its contents aren't counted twice.
            if let key = c.key {
                if visited.contains(key) { continue }
                visited.insert(key)
            }
            children.append(c.node)
            stack.append((c.url, c.node))
            pending += 1
            enqueued += 1
        }
        node.children = children              // assigned once, under the lock
        counter += entries.count
        lastPath = url.path
        maybeSnapshotLocked()
        if enqueued > 0 { cond.broadcast() }   // wake idle workers for new work
        cond.unlock()
    }

    /// Called while holding `cond`. Since every assigned `children` array is
    /// immutable thereafter and we hold the lock, the tree is stable to copy.
    private func maybeSnapshotLocked() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshot) >= snapshotInterval,
              let live = rootNode else { return }
        lastSnapshot = now
        let snap = deepCopySorted(live)
        onProgress?(snap, counter, lastPath)
    }

    /// Immutable, size-sorted copy of a subtree. Directory sizes/counts are
    /// computed bottom-up here (the live tree stores only per-file sizes).
    private func deepCopySorted(_ node: FileNode) -> FileNode {
        let copy = FileNode(path: node.path, name: node.name, isDirectory: node.isDirectory)
        if let kids = node.children {
            var copies = kids.map { deepCopySorted($0) }
            copies.sort { $0.size > $1.size }
            var total: Int64 = 0
            var files = 0
            for c in copies { c.parent = copy; total += c.size; files += c.fileCount }
            copy.children = copies
            copy.size = total
            copy.fileCount = files
        } else {
            // Leaf: a file carries its own bytes; an unscanned dir is still 0.
            copy.size = node.size
            copy.fileCount = node.fileCount
        }
        return copy
    }
}
