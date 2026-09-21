import Foundation

/// Foundation-only Full Disk Access probe shared by the GUI and background
/// helper. FullDiskAccess.swift adds the AppKit guidance around this check.
enum DiskAccess {
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = home.appendingPathComponent(
            "Library/Application Support/com.apple.TCC/TCC.db"
        )
        guard FileManager.default.fileExists(atPath: probe.path),
              let handle = try? FileHandle(forReadingFrom: probe) else {
            return false
        }
        try? handle.close()
        return true
    }
}
