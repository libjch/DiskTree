import Foundation
import Darwin

/// Cross-process lock preventing the GUI and scheduled helper from scanning or
/// replacing persistence at the same time.
final class ScanExecutionLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(wait: Bool) -> ScanExecutionLock? {
        let url = ScanStore.dataDirectory.appendingPathComponent("scan.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        let operation = wait ? LOCK_EX : (LOCK_EX | LOCK_NB)
        guard flock(descriptor, operation) == 0 else {
            close(descriptor)
            return nil
        }
        return ScanExecutionLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
