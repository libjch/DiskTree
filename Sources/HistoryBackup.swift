import Foundation

/// A safety net around the one irreplaceable thing DiskTree stores: the
/// append-only scan history. Before any version of the app writes something
/// new in `history/` — a new archive, or the summaries built by a migration —
/// the existing history is cloned once, and never touched again.
///
/// On APFS `copyItem` clones, so the copy is instant and costs no extra space
/// until one of the two sides changes. Backups are never deleted automatically.
enum HistoryBackup {
    /// Bump when a future change rewrites or adds to `history/` in a new way;
    /// that takes a fresh backup instead of trusting the previous one.
    static let currentMigrationVersion = 1

    /// Clone `history/` (archives and index) next to the data directory unless
    /// this migration version has already been backed up. Safe to call often
    /// and from several processes: the marker is written only after a complete
    /// copy, and a half-finished copy is left in place rather than deleted.
    static func ensureBackup(dataDirectory: URL,
                             version: Int = currentMigrationVersion) {
        let manager = FileManager.default
        let marker = dataDirectory.appendingPathComponent(".history-backup-v\(version)")
        guard !manager.fileExists(atPath: marker.path) else { return }

        let history = dataDirectory.appendingPathComponent("history", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: history.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? manager.contentsOfDirectory(atPath: history.path),
              !contents.isEmpty else {
            // Nothing to lose yet — record the version so a first-run app does
            // not keep probing, and let the next migration take its own copy.
            try? Data().write(to: marker, options: .atomic)
            return
        }

        let stamp = timestampFormatter.string(from: Date())
        let backups = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("DiskTree Backups", isDirectory: true)
        let destination = backups.appendingPathComponent("history-\(stamp)", isDirectory: true)
        do {
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            guard !manager.fileExists(atPath: destination.path) else { return }
            try manager.copyItem(at: history, to: destination)
            try Data().write(to: marker, options: .atomic)
            NSLog("DiskTree: history backed up to \(destination.path)")
        } catch {
            // No marker is written, so the next launch tries again. Never
            // block or discard the user's data because a backup failed.
            NSLog("DiskTree: history backup failed — \(error.localizedDescription)")
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
