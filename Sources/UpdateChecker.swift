import Foundation
import AppKit

/// Contents of the small JSON feed published next to the DMG by notarize.sh:
/// `{"version": "1.2", "url": "https://…/DiskTree.dmg", "notes": "…"}`
struct UpdateInfo: Decodable, Sendable {
    let version: String
    let url: URL
    let notes: String?
}

/// Checks the website feed for a newer release. The request carries no
/// identifiers or usage data, and DiskTree never installs anything itself:
/// "Download" opens the notarized DMG in the browser.
@MainActor
enum UpdateChecker {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// `DISKTREE_UPDATE_FEED_URL` overrides the Info.plist feed for testing
    /// (e.g. a test file on the same site announcing version 99.0).
    nonisolated static var feedURL: URL? {
        let override = ProcessInfo.processInfo.environment["DISKTREE_UPDATE_FEED_URL"]
        let configured = Bundle.main.object(forInfoDictionaryKey: "DiskTreeUpdateFeedURL") as? String
        return (override ?? configured).flatMap { URL(string: $0) }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Launch-time check: at most once a day, silent on errors, and quiet about
    /// a version the user chose to skip.
    static func checkInBackgroundIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppSettings.automaticUpdateCheckKey) as? Bool ?? true,
              let feedURL else { return }
        if let last = defaults.object(forKey: AppSettings.lastUpdateCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval {
            return
        }
        guard let info = try? await fetch(from: feedURL) else { return }
        defaults.set(Date(), forKey: AppSettings.lastUpdateCheckKey)
        guard isNewer(info.version, than: currentVersion),
              defaults.string(forKey: AppSettings.skippedUpdateVersionKey) != info.version
        else { return }
        present(info, manual: false)
    }

    /// "Check for Updates…": always reports an outcome.
    static func checkNow() async {
        guard let feedURL else { return }
        do {
            let info = try await fetch(from: feedURL)
            UserDefaults.standard.set(Date(), forKey: AppSettings.lastUpdateCheckKey)
            if isNewer(info.version, than: currentVersion) {
                present(info, manual: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "DiskTree is up to date"
                alert.informativeText = "Version \(currentVersion) is the latest version."
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func present(_ info: UpdateInfo, manual: Bool) {
        let alert = NSAlert()
        alert.messageText = "DiskTree \(info.version) is available"
        var text = "You have version \(currentVersion)."
        if let notes = info.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            text += "\n\n\(notes)"
        }
        text += """


        Download the disk image, then drag DiskTree to Applications to replace \
        this copy. If macOS stops applying Full Disk Access afterwards, DiskTree \
        will show how to approve it again.
        """
        alert.informativeText = text
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !manual { alert.addButton(withTitle: "Skip This Version") }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(info.url)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(info.version, forKey: AppSettings.skippedUpdateVersionKey)
        default:
            break
        }
    }

    nonisolated static func fetch(from feedURL: URL) async throws -> UpdateInfo {
        let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        // Ephemeral: no cookies or cache shared with anything else.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
        // Only ever send the user to an HTTPS download on the feed's own host.
        guard info.url.scheme == "https", info.url.host == feedURL.host else {
            throw URLError(.badURL)
        }
        return info
    }

    /// Printed by `DiskTree --check-for-updates`: same fetch and validation as
    /// the app, without any dialog. Exit status 0 when the feed was read.
    nonisolated static func commandLineReport() -> (text: String, ok: Bool) {
        final class Box: @unchecked Sendable { var value: (String, Bool) = ("", false) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let current = currentVersion
        guard let feedURL else { return ("No update feed URL configured", false) }
        Task.detached {
            var lines = ["Installed version: \(current)", "Feed: \(feedURL.absoluteString)"]
            do {
                let info = try await fetch(from: feedURL)
                lines.append("Feed version: \(info.version)")
                lines.append("Download: \(info.url.absoluteString)")
                if let notes = info.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
                lines.append(isNewer(info.version, than: current)
                    ? "Result: update available" : "Result: up to date")
                box.value = (lines.joined(separator: "\n"), true)
            } catch {
                lines.append("Result: check failed — \(error.localizedDescription)")
                box.value = (lines.joined(separator: "\n"), false)
            }
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// Numeric dotted-version comparison: "1.10" > "1.9", "1.2" == "1.2.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
