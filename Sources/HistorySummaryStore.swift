import Foundation

/// In-memory cache of the history summaries, plus the one-time migration that
/// creates them for archives written before the format existed.
///
/// The history sheet reads every snapshot through this store exactly once per
/// launch; after that, drilling down, going back or changing the depth is pure
/// in-memory work with no disk I/O at all.
actor HistorySummaryStore {
    static let shared = HistorySummaryStore()

    private var cache: [String: HistorySummary] = [:]
    private var inFlight: [String: Task<HistorySummary?, Never>] = [:]

    /// Summary for one archived scan: from memory, from `history/summaries/`,
    /// or built from the archive (and stored) the first time it is needed.
    func summary(for entry: ScanHistoryEntry,
                 priority: TaskPriority = .userInitiated) async -> HistorySummary? {
        if let cached = cache[entry.file] { return cached }
        if let running = inFlight[entry.file] { return await running.value }

        let task = Task.detached(priority: priority) { () -> HistorySummary? in
            if let stored = ScanStore.loadSummary(forArchive: entry.file) { return stored }
            return ScanStore.buildSummary(forArchive: entry)
        }
        inFlight[entry.file] = task
        let summary = await task.value
        inFlight[entry.file] = nil
        if let summary { cache[entry.file] = summary }
        return summary
    }

    /// Back up the history and build whatever summaries are missing, one at a
    /// time in the background, so the first history sheet of a release opens
    /// instantly instead of paying for the migration.
    func migrateMissingSummaries() async {
        let directory = ScanStore.dataDirectory
        await Task.detached(priority: .utility) {
            HistoryBackup.ensureBackup(dataDirectory: directory)
        }.value

        for entry in ScanStore.history() where !ScanStore.hasSummary(forArchive: entry.file) {
            if Task.isCancelled { return }
            _ = await summary(for: entry, priority: .utility)
        }
    }
}
