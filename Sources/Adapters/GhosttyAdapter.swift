import AppKit
import Foundation

// MARK: - Ghostty Adapter

class GhosttyAdapter: TerminalAdapter {
    let info = TerminalInfo(
        identifier: "ghostty",
        displayName: "Ghostty",
        scriptName: "Ghostty",
        bundleIdentifier: "com.mitchellh.ghostty",
        keywords: ["ghostty"]
    )

    var capabilities: TerminalCapabilities { [.nativeOpenWithCWD] }

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.mitchellh.ghostty" }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        if focus?.term_program?.lowercased() == "ghostty" { return true }
        return processAncestry.contains { $0.contains("ghostty") }
    }

    func openWithCWD(path: String, command: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Ghostty", "--args", "--working-directory=\(path)"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
