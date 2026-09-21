import Foundation
import Combine
import ServiceManagement
import Darwin

@MainActor
final class WeeklyScanScheduler: ObservableObject {
    static let plistName = "com.libjch.disktree.weekly-scan.plist"
    private static let registrationRevision = 2
    private static let registrationRevisionKey = "weeklyScanRegistrationRevision"

    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastRun: ScheduledScanStatus?

    private let service = SMAppService.agent(plistName: plistName)

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                UserDefaults.standard.set(Self.registrationRevision,
                                          forKey: Self.registrationRevisionKey)
            } else {
                try service.unregister()
                UserDefaults.standard.removeObject(forKey: Self.registrationRevisionKey)
            }
            refresh()
        } catch {
            statusMessage = error.localizedDescription
            refresh(keepingError: true)
        }
    }

    func refresh(keepingError: Bool = false) {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            if !keepingError { statusMessage = "Scheduled for Monday at 08:00" }
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            if !keepingError { statusMessage = "Approval required in System Settings" }
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            if !keepingError { statusMessage = "Automatic scans are off" }
        case .notFound:
            isEnabled = false
            requiresApproval = false
            if !keepingError { statusMessage = "The bundled scan helper was not found" }
        @unknown default:
            isEnabled = false
            requiresApproval = false
            if !keepingError { statusMessage = "Unknown background-service status" }
        }
        lastRun = ScanStore.scheduledScanStatus().map(normalizedStatus)
    }

    func openBackgroundItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// launchd caches a registered plist and executable. Re-register an enabled
    /// helper once after a bundled helper/plist revision changes, but never kill
    /// a scan that is genuinely still running.
    static func refreshRegistrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: registrationRevisionKey) < registrationRevision else {
            return
        }
        let service = SMAppService.agent(plistName: plistName)
        guard service.status == .enabled, !scheduledHelperIsRunning else { return }

        let unregisterError: Error? = await withCheckedContinuation { continuation in
            service.unregister { error in continuation.resume(returning: error) }
        }
        guard unregisterError == nil else { return }
        do {
            try service.register()
            defaults.set(registrationRevision, forKey: registrationRevisionKey)
        } catch {
            // Settings exposes the service status and lets the user retry by
            // switching automatic scans off and on.
        }
    }

    private static var scheduledHelperIsRunning: Bool {
        guard let status = ScanStore.scheduledScanStatus(), status.outcome == .running else {
            return false
        }
        if let processID = status.processID {
            return kill(processID, 0) == 0
        }
        return Date().timeIntervalSince(status.startedAt) < 24 * 60 * 60
    }

    private func normalizedStatus(_ status: ScheduledScanStatus) -> ScheduledScanStatus {
        guard status.outcome == .running else { return status }
        let processEnded: Bool
        if let processID = status.processID {
            processEnded = kill(processID, 0) != 0 && errno == ESRCH
        } else {
            // Older helpers did not record a PID. Treat a day-old "running"
            // marker as interrupted rather than showing it forever.
            processEnded = Date().timeIntervalSince(status.startedAt) > 24 * 60 * 60
        }
        guard processEnded else { return status }
        return ScheduledScanStatus(
            startedAt: status.startedAt, finishedAt: nil, outcome: .failed,
            message: "The previous automatic scan was interrupted",
            processID: nil
        )
    }
}
