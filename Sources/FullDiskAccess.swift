import Foundation
import AppKit
import Security

/// Full Disk Access can't be requested programmatically on macOS — only the user
/// can grant it in System Settings. What we *can* do is detect whether we have it
/// and deep-link the user straight to the correct settings pane.
enum FullDiskAccess {

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

    /// Show a one-time explanatory dialog at launch when FDA is missing, with a
    /// button that jumps to the right settings pane. Returns nothing; purely UI.
    @MainActor
    static func promptIfNeeded() {
        // Only nag on proof of denial; an undetermined probe stays silent.
        guard DiskAccess.status == .denied else { return }

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

    /// Printed by `DiskTree --check-full-disk-access`. Shows what the probes see
    /// and how this binary is signed: TCC binds a grant to the code signature,
    /// so a toggle that is on in System Settings but was granted to a build
    /// signed differently (ad-hoc vs. Apple Development vs. Developer ID) does
    /// not apply to this one.
    static func diagnosticReport() -> String {
        var lines = ["DiskTree Full Disk Access check",
                     "Executable: \(Bundle.main.executablePath ?? "?")"]
        lines += signingLines()
        lines.append("Probes:")
        lines += DiskAccess.diagnosticLines()
        return lines.joined(separator: "\n")
    }

    private static func signingLines() -> [String] {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return ["Signature: unavailable"]
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return ["Signature: unavailable"]
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
        return [
            "Signature: identifier=\(identifier) team=\(team)\(adHoc ? " (ad-hoc)" : "")",
            "Designated requirement: \((requirementText as String?) ?? "?")",
        ]
    }
}
