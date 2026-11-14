import Foundation
import Darwin

/// Foundation-only Full Disk Access probe shared by the GUI and background
/// helper. FullDiskAccess.swift adds the AppKit guidance around this check.
///
/// There is no public API that reports the FDA state, so we try to read a few
/// locations macOS only opens with FDA. One readable location proves the grant.
/// Only a TCC refusal (`EPERM`) counts as proof that FDA is missing; anything
/// else (location absent, unexpected error) is "undetermined", so a single odd
/// probe can never make DiskTree nag a user who has already granted access.
enum DiskAccess {
    enum Status: Sendable, Equatable {
        case granted
        case denied
        case undetermined
    }

    enum ProbeResult: Sendable, Equatable {
        case readable
        /// TCC refused the read (`EPERM`): FDA is not in effect for this process.
        case denied
        case missing
        case failed(Int32)
    }

    struct Probe: Sendable {
        let relativePath: String
        let isDirectory: Bool
    }

    /// FDA-protected locations under the user's home. None of these raise a
    /// consent dialog when refused (unlike other apps' `~/Library/Containers`,
    /// which triggers "access data from other apps" on macOS 14+), so probing
    /// stays silent.
    static let probes: [Probe] = [
        Probe(relativePath: "Library/Application Support/com.apple.TCC/TCC.db", isDirectory: false),
        Probe(relativePath: "Library/Safari", isDirectory: true),
        Probe(relativePath: "Library/Mail", isDirectory: true),
        Probe(relativePath: "Library/Messages", isDirectory: true),
    ]

    static var status: Status {
        status(for: probes.map { check($0) })
    }

    /// True only when a probe actually succeeded.
    static var hasFullDiskAccess: Bool { status == .granted }

    static func status(for results: [ProbeResult]) -> Status {
        if results.contains(.readable) { return .granted }
        if results.contains(.denied) { return .denied }
        return .undetermined
    }

    static func path(of probe: Probe) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(probe.relativePath).path
    }

    static func check(_ probe: Probe) -> ProbeResult {
        let path = path(of: probe)
        if probe.isDirectory {
            guard let dir = opendir(path) else { return classify(errno) }
            defer { closedir(dir) }
            errno = 0
            if readdir(dir) == nil, errno != 0 { return classify(errno) }
            return .readable
        } else {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return classify(errno) }
            close(fd)
            return .readable
        }
    }

    private static func classify(_ code: Int32) -> ProbeResult {
        switch code {
        case EPERM: return .denied
        case ENOENT, ENOTDIR: return .missing
        default: return .failed(code)
        }
    }

    /// Human-readable probe results, for `--check-full-disk-access`.
    static func diagnosticLines() -> [String] {
        var results: [ProbeResult] = []
        var lines: [String] = []
        for probe in probes {
            let result = check(probe)
            results.append(result)
            let label: String
            switch result {
            case .readable: label = "readable"
            case .denied: label = "denied (EPERM: Operation not permitted)"
            case .missing: label = "not present"
            case .failed(let code): label = "error \(code): \(String(cString: strerror(code)))"
            }
            lines.append("  ~/\(probe.relativePath): \(label)")
        }
        lines.append("Full Disk Access: \(status(for: results))")
        return lines
    }
}
