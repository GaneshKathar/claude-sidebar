import AppKit
import Foundation

// MARK: - Protocol Abstractions (DIP + ISP Foundation)

/// Scans terminal windows and returns structured info about each.
protocol TerminalScanning {
    func scan() -> [TerminalWindow]
    func readHookStates() -> HookStates
    func getBranch(cwd: String) -> String?
}

/// kqueue-based process watcher + batched ps discovery.
protocol ProcessMonitoring {
    func watchPID(_ pid: Int32, tty: String, onExit: @escaping (Int32) -> Void)
    func unwatchPID(_ pid: Int32)
    func discoverProcesses(ttys: [String]) -> ProcessScanResult
    func detectCWDs(shellPIDs: [String: Int32]) -> [String: String]
}

/// Reads hook state files and terminal focus files from /tmp/claude-sidebar.
protocol StateReading {
    func readStates() -> HookStates
    func readFocusFiles() -> [String: TerminalFocus]
}
