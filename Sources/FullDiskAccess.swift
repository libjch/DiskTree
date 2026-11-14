import Foundation
import AppKit
import Security

/// Full Disk Access can't be requested programmatically on macOS — only the user
/// can grant it in System Settings. What we *can* do is detect whether we have it
/// and deep-link the user straight to the correct settings pane.
///
/// macOS binds a grant to the code signature ("designated requirement") that was
/// approved. Notarized releases share one requirement (Team ID + bundle ID), so
/// updates keep the grant. A copy signed differently (ad-hoc, Apple Development
/// vs. Developer ID) does not: System Settings still shows the switch on, but
/// the grant is stale. We remember the requirement that last had access, so a
/// later denial can be explained as "approve this copy again" instead of
/// "grant access", and offer to reset the stale entry.
enum FullDiskAccess {
    /// Designated requirement of the last build that actually had FDA.
    static let grantedRequirementKey = "fullDiskAccessGrantedRequirement"

    /// True only when an FDA-protected location could actually be read.
    static var isGranted: Bool {
        DiskAccess.hasFullDiskAccess
    }

    /// Open System Settings directly at Privacy & Security › Full Disk Access.
    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launch-time check. Records the signature when access works, and when it
    /// is provably denied shows either first-time guidance or, if an earlier
    /// copy had access, the stale-grant guidance with a reset option.
    @MainActor
    static func promptIfNeeded() {
        let defaults = UserDefaults.standard
        switch DiskAccess.status {
        case .granted:
            if let requirement = signature().requirement {
                defaults.set(requirement, forKey: grantedRequirementKey)
            }
        case .undetermined:
            return   // Only nag on proof of denial.
        case .denied:
            if let previous = defaults.string(forKey: grantedRequirementKey) {
                promptStaleGrant(signatureChanged: previous != signature().requirement)
            } else {
                promptFirstGrant()
            }
        }
    }

    @MainActor
    private static func promptFirstGrant() {
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

        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    @MainActor
    private static func promptStaleGrant(signatureChanged: Bool) {
        let cause = signatureChanged
            ? """
            This copy of DiskTree is signed differently from the one you approved \
            earlier (for example after an update or reinstall), so macOS no longer \
            applies that approval — even if System Settings still shows DiskTree \
            switched on.
            """
            : """
            DiskTree had Full Disk Access before, but macOS no longer applies it. \
            The switch may have been turned off, or the approval is out of date.
            """

        let alert = NSAlert()
        alert.messageText = "Approve DiskTree for Full Disk Access again"
        alert.informativeText = """
        \(cause)

        1. Click “Reset & Open Settings”. This removes the outdated entry.
        2. Add DiskTree with “+” (choose it in Applications) and turn it on.
        3. Quit and reopen DiskTree.

        If DiskTree is still listed after the reset, select it and remove it \
        with “−” first.
        """
        alert.addButton(withTitle: "Reset & Open Settings")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !resetGrant() {
                let failure = NSAlert()
                failure.messageText = "Couldn’t reset the entry automatically"
                failure.informativeText = """
                In the Full Disk Access list, select DiskTree, remove it with “−”, \
                then add it again with “+” and turn it on.
                """
                failure.runModal()
            }
            openSettings()
        case .alertSecondButtonReturn:
            openSettings()
        default:
            break
        }
    }

    /// Removes DiskTree's Full Disk Access entry (equivalent to clicking “−”).
    /// It only clears the record; access still has to be granted by the user.
    @MainActor
    @discardableResult
    static func resetGrant() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "SystemPolicyAllFiles", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: Diagnostics

    /// Printed by `DiskTree --check-full-disk-access`. Shows what the probes see
    /// and how this binary is signed compared with the copy that last had access.
    static func diagnosticReport() -> String {
        let current = signature()
        var lines = ["DiskTree Full Disk Access check",
                     "Executable: \(Bundle.main.executablePath ?? "?")"]
        lines.append(current.summary)
        lines.append("Designated requirement: \(current.requirement ?? "?")")
        if let previous = UserDefaults.standard.string(forKey: grantedRequirementKey) {
            lines.append(previous == current.requirement
                ? "Last copy with access: same signature"
                : "Last copy with access had a DIFFERENT signature: \(previous)")
        } else {
            lines.append("Last copy with access: none recorded")
        }
        if isatty(STDIN_FILENO) != 0 {
            lines.append("WARNING: started from a terminal, so macOS checks the terminal's")
            lines.append("  permission, not DiskTree's. Launch via `open` (see README).")
        }
        lines.append("Probes:")
        lines += DiskAccess.diagnosticLines()
        return lines.joined(separator: "\n")
    }

    struct Signature {
        var summary: String
        var requirement: String?
    }

    static func signature() -> Signature {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return Signature(summary: "Signature: unavailable", requirement: nil)
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return Signature(summary: "Signature: unavailable", requirement: nil)
        }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? "?"
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHoc = codeFlags & 0x0002 != 0   // kSecCodeSignatureAdhoc

        var requirement: SecRequirement?
        var requirementText: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            _ = SecRequirementCopyString(requirement, [], &requirementText)
        }
        return Signature(
            summary: "Signature: identifier=\(identifier) team=\(team)\(adHoc ? " (ad-hoc)" : "")",
            requirement: requirementText as String?
        )
    }
}
