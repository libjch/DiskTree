import Foundation
import Darwin

@main
struct ScheduledScanMain {
    private enum ExitCode {
        static let ioError: Int32 = 74
        static let temporaryFailure: Int32 = 75
        static let noPermission: Int32 = 77
    }

    static func main() {
        let startedAt = Date()
        ScanStore.writeScheduledScanStatus(ScheduledScanStatus(
            startedAt: startedAt, finishedAt: nil, outcome: .running,
            message: "Scanning the startup disk", processID: getpid()
        ))

        // launchd uses "/". A redirected dev/test run may select a small fixture
        // without ever scanning or archiving into the user's real data store.
        let environment = ProcessInfo.processInfo.environment
        let testRoot = environment["DISKTREE_DATA_DIR"] == nil
            ? nil : environment["DISKTREE_SCHEDULED_SCAN_ROOT"]
        let rootPath = testRoot ?? "/"

        if rootPath == "/" && DiskAccess.status == .denied {
            finish(startedAt: startedAt, outcome: .failed,
                   message: "Full Disk Access is required for the scheduled scan")
            exit(ExitCode.noPermission)
        }

        guard let runLock = ScanExecutionLock.acquire(wait: true) else {
            finish(startedAt: startedAt, outcome: .failed,
                   message: "Could not acquire the DiskTree scan lock")
            exit(ExitCode.temporaryFailure)
        }

        let engine = ScanEngine(rootURL: URL(fileURLWithPath: rootPath), generation: 0)
        let result = engine.run()
        guard let root = result.root else {
            withExtendedLifetime(runLock) {}
            finish(startedAt: startedAt, outcome: .failed,
                   message: "The startup disk could not be read")
            exit(ExitCode.ioError)
        }

        do {
            try ScanStore.saveAndArchiveSynchronously(root, date: Date())
            withExtendedLifetime(runLock) {}
            finish(startedAt: startedAt, outcome: .succeeded,
                   message: "Scanned \(result.count) items")
        } catch {
            withExtendedLifetime(runLock) {}
            finish(startedAt: startedAt, outcome: .failed,
                   message: "Could not save the scan: \(error.localizedDescription)")
            exit(ExitCode.ioError)
        }
    }

    private static func finish(startedAt: Date, outcome: ScheduledScanOutcome,
                               message: String) {
        ScanStore.writeScheduledScanStatus(ScheduledScanStatus(
            startedAt: startedAt, finishedAt: Date(), outcome: outcome,
            message: message, processID: nil
        ))
        print("DiskTree weekly scan: \(message)")
    }
}
