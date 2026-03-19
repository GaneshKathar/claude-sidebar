import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "TerminalDetector")

// MARK: - PS Scan Result (shared process tree data)

struct PSScanResult {
    var claudeTTYs: Set<String> = []
    var busyTTYs: Set<String> = []      // TTYs with a non-shell, non-Claude foreground process
    var shellPIDs: [String: Int32] = [:]
    var pidToPPID: [Int32: Int32] = [:]
    var pidToComm: [Int32: String] = [:]
    var pidToTTY: [Int32: String] = [:]  // pid → full TTY path (e.g., "/dev/ttys005")
}

// MARK: - Terminal Detector (extracted from ITermScanner)

class TerminalDetector {
    // Known terminal emulators: keyword in process name -> (displayName, scriptName for AppleScript)
    static let terminalAppMappings: [(keyword: String, displayName: String, scriptName: String)] = [
        ("iterm2",    "iTerm2",    "iTerm2"),
        ("ghostty",   "Ghostty",   "Ghostty"),
        ("alacritty", "Alacritty", "Alacritty"),
        ("warp",      "Warp",      "Warp"),
        ("kitty",     "Kitty",     "Kitty"),
        ("hyper",     "Hyper",     "Hyper"),
        ("tabby",     "Tabby",     "Tabby"),
        ("rio",       "Rio",       "Rio"),
        ("cursor",    "Cursor",    "Cursor"),
        ("terminal",  "Terminal",  "Terminal"),
        ("code",      "VS Code",   "Visual Studio Code"),
    ]

    // Returns true if the lowercase window-owner name belongs to a supported terminal
    static func isKnownTerminal(_ lowerName: String) -> Bool {
        terminalAppMappings.contains { lowerName.contains($0.keyword) }
    }

    // Run ps -eo pid,ppid,tty,comm to find ALL Claude processes and build process tree
    func scanProcesses() -> PSScanResult {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,ppid,tty,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            os_log("scanProcesses ps failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            return PSScanResult()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return PSScanResult() }

        var result = PSScanResult()
        for line in output.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            guard let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let ttyShort = String(parts[2])
            let comm = String(parts[3])

            result.pidToPPID[pid] = ppid
            result.pidToComm[pid] = comm

            guard ttyShort != "??" else { continue }
            let fullTTY = "/dev/" + ttyShort
            result.pidToTTY[pid] = fullTTY

            // Strip leading dash from login shells (-zsh, -bash)
            let strippedComm = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
            let baseName = (strippedComm as NSString).lastPathComponent.lowercased()

            if baseName == "claude" {
                result.claudeTTYs.insert(fullTTY)
            } else if ["zsh", "bash", "fish", "sh", "csh", "tcsh", "dash", "ksh",
                       "login"].contains(baseName) {
                if ["zsh", "bash", "fish", "sh", "csh", "tcsh", "dash", "ksh"].contains(baseName),
                   result.shellPIDs[fullTTY] == nil {
                    result.shellPIDs[fullTTY] = pid
                }
            } else {
                result.busyTTYs.insert(fullTTY)
            }
        }
        return result
    }

    // Map TERM_PROGRAM env var value → display name
    func appNameFromTermProgram(_ tp: String?) -> String? {
        guard let s = tp?.lowercased(), !s.isEmpty else { return nil }
        for m in Self.terminalAppMappings {
            if s.contains(m.keyword) { return m.displayName }
        }
        return nil
    }

    // Walk the process tree from the shell on this TTY to identify the terminal app.
    func detectTerminalApp(for tty: String, psInfo: PSScanResult, focusByTTY: [String: TerminalFocus]) -> (name: String, pid: Int32?) {
        if let focus = focusByTTY[tty] {
            let hostName = appNameFromTermProgram(focus.term_program)
            let tp = focus.term_program?.lowercased() ?? ""
            let hasCmux = !(focus.cmux_workspace_id ?? "").isEmpty
            let ownFocusMechanism = tp == "vscode" || tp.contains("iterm")
            let isCmux = hasCmux && !ownFocusMechanism
            let displayName = isCmux ? "cmux" : (hostName ?? "Other Terminal")
            let activationName = hostName ?? displayName
            let pid = pidForTerminalApp(name: activationName, tty: tty, psInfo: psInfo)
            return (displayName, pid)
        }
        // Fallback: walk process tree
        guard let shellPID = psInfo.shellPIDs[tty] else { return ("Other Terminal", nil) }
        var pid = shellPID
        var lastAncestorPID: Int32 = shellPID
        for _ in 0..<10 {
            guard let ppid = psInfo.pidToPPID[pid], ppid > 1,
                  let comm = psInfo.pidToComm[ppid] else { break }
            lastAncestorPID = ppid
            let lower = (comm as NSString).lastPathComponent.lowercased()
            for mapping in Self.terminalAppMappings {
                if lower.contains(mapping.keyword) {
                    return (mapping.displayName, ppid)
                }
            }
            pid = ppid
        }
        return ("Other Terminal", lastAncestorPID)
    }

    // Returns list of ancestor process names for a TTY (used by adapter claimsSession)
    func processAncestry(for tty: String, psInfo: PSScanResult) -> [String] {
        guard let shellPID = psInfo.shellPIDs[tty] else { return [] }
        var result: [String] = []
        var pid = shellPID
        for _ in 0..<10 {
            guard let ppid = psInfo.pidToPPID[pid], ppid > 1,
                  let comm = psInfo.pidToComm[ppid] else { break }
            result.append((comm as NSString).lastPathComponent.lowercased())
            pid = ppid
        }
        return result
    }

    // Find the PID of a running terminal app by matching its name
    func pidForTerminalApp(name: String, tty: String, psInfo: PSScanResult) -> Int32? {
        let lower = name.lowercased()
        if let shellPID = psInfo.shellPIDs[tty] {
            var pid = shellPID
            for _ in 0..<10 {
                guard let ppid = psInfo.pidToPPID[pid], ppid > 1,
                      let comm = psInfo.pidToComm[ppid] else { break }
                if (comm as NSString).lastPathComponent.lowercased().contains(lower) { return ppid }
                pid = ppid
            }
        }
        return NSWorkspace.shared.runningApplications
            .first { $0.localizedName?.lowercased().contains(lower) ?? false }
            .map { Int32($0.processIdentifier) }
    }

    // Script name for AppleScript activation
    func scriptNameForApp(_ displayName: String) -> String {
        Self.terminalAppMappings.first { $0.displayName == displayName }?.scriptName ?? displayName
    }
}
