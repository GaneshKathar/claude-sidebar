import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "StateReader")

class StateReader {
    private let stateDir = "/tmp/claude-sidebar"

    func readStates() -> HookStates {
        var result = HookStates()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return result }

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path) else {
                os_log("Failed to read state file: %{public}@", log: logger, type: .error, file)
                continue
            }
            guard let hookState = try? JSONDecoder().decode(HookState.self, from: data) else {
                os_log("Failed to parse state file (corrupted?): %{public}@", log: logger, type: .error, file)
                // Remove corrupted file
                try? fm.removeItem(atPath: path)
                continue
            }
            if Date().timeIntervalSince1970 - hookState.timestamp > (appConfig.staleTimeout ?? 1800) {
                if (try? fm.removeItem(atPath: path)) == nil {
                    os_log("Failed to remove stale state file: %{public}@", log: logger, type: .error, file)
                }
                continue
            }
            let repo = hookState.repo
            let state = hookState.state

            // Per-TTY state and repo mapping for individual session matching
            if let tty = hookState.tty, !tty.isEmpty {
                result.byTTY[tty] = state
                if repo > 0 {
                    result.byTTYRepo[tty] = repo
                }
            }

            // Per-repo: keep highest priority (only for valid repo nums)
            if repo > 0 {
                if let existing = result.byRepo[repo] {
                    if existing == "alert" { continue }
                    if existing == "working" && state != "alert" { continue }
                }
                result.byRepo[repo] = state
            }
        }
        return result
    }
}
