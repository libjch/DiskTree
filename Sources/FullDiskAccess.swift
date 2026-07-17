import Foundation
import AppKit

/// Full Disk Access can't be requested programmatically on macOS — only the user
/// can grant it in System Settings. What we *can* do is detect whether we have it
/// and deep-link the user straight to the correct settings pane.
enum FullDiskAccess {

    /// Probe a file that is only readable with Full Disk Access. If the read
    /// succeeds, FDA is granted. Uses the TCC database, which always exists.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // Path missing is unusual; assume we can't confirm access.
            return false
        }
        // Opening the handle for reading succeeds only with Full Disk Access.
        guard let fh = try? FileHandle(forReadingFrom: probe) else { return false }
        try? fh.close()
        return true
    }

    /// Open System Settings directly at Privacy & Security › Full Disk Access.
    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show a one-time explanatory dialog at launch when FDA is missing, with a
    /// button that jumps to the right settings pane. Returns nothing; purely UI.
    @MainActor
    static func promptIfNeeded() {
        guard !isGranted else { return }

        let alert = NSAlert()
        alert.messageText = "Grant Full Disk Access for complete scans"
        alert.informativeText = """
        To scan every folder without repeated permission prompts, DiskTree needs \
        Full Disk Access — a switch only you can turn on in System Settings.

        1. Click “Open Settings” below.
        2. Find DiskTree in the list and turn it on (add it with “+” if needed).
        3. Quit and reopen DiskTree.

        You can skip this and still scan your Home folder and any folder you pick.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal().rawValue == 1000 {   // "Open Settings"
            openSettings()
        }
    }
}
