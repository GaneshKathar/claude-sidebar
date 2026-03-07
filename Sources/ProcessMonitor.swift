import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "ProcessMonitor")

// MARK: - Process Monitor (kqueue-based)

class ProcessMonitor {
    private var kq: Int32 = -1
    private var watchedPIDs: [Int32: (tty: String, callback: (Int32) -> Void)] = [:]
    private let pidLock = NSLock()  // Thread-safe access to watchedPIDs
    private static let maxWatchedPIDs = 500
    private var monitorThread: Thread?
    private var running = false

    init() {
        kq = kqueue()
        guard kq >= 0 else {
            os_log("Failed to create kqueue", log: logger, type: .error)
            return
        }
        running = true
        monitorThread = Thread { [weak self] in self?.monitorLoop() }
        monitorThread?.qualityOfService = .utility
        monitorThread?.start()
    }

    deinit {
        running = false
        monitorThread?.cancel()
        if kq >= 0 { close(kq) }
    }

    func watchPID(_ pid: Int32, tty: String, onExit: @escaping (Int32) -> Void) {
        guard kq >= 0 else { return }

        pidLock.lock()
        // Guard against unbounded growth
        if watchedPIDs.count >= Self.maxWatchedPIDs {
            pidLock.unlock()
            os_log("Max watched PIDs (%d) reached, skipping PID %d", log: logger, type: .info, Self.maxWatchedPIDs, pid)
            return
        }
        pidLock.unlock()

        // Register EVFILT_PROC + NOTE_EXIT
        var event = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        let result = kevent(kq, &event, 1, nil, 0, nil)
        if result < 0 {
            os_log("Failed to register kqueue for PID %d: errno %d", log: logger, type: .error, pid, errno)
            return
        }

        pidLock.lock()
        watchedPIDs[pid] = (tty: tty, callback: onExit)
        pidLock.unlock()
    }

    func unwatchPID(_ pid: Int32) {
        guard kq >= 0 else { return }
        var event = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_DELETE),
            fflags: 0,
            data: 0,
            udata: nil
        )
        kevent(kq, &event, 1, nil, 0, nil)

        pidLock.lock()
        watchedPIDs.removeValue(forKey: pid)
        pidLock.unlock()
    }

    private func monitorLoop() {
        var event = kevent()
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        while running && !Thread.current.isCancelled {
            let n = kevent(kq, nil, 0, &event, 1, &timeout)
            if n > 0 && event.filter == Int16(EVFILT_PROC) {
                let pid = Int32(event.ident)
                let exitStatus = Int32(event.data)

                pidLock.lock()
                let entry = watchedPIDs.removeValue(forKey: pid)
                pidLock.unlock()

                if let entry = entry {
                    let cb = entry.callback
                    DispatchQueue.main.async { cb(exitStatus) }
                }
            }
        }
    }

    // Result of a batched ps scan
    struct ScanResult {
        var processes: [String: ProcessInfo] = [:]  // tty -> non-shell/non-claude process
        var claudeTTYs: Set<String> = []            // TTYs running claude
        var shellPIDs: [String: Int32] = [:]        // tty -> shell PID (for CWD detection)
    }

    // Ignore these — they're not user-initiated long-running commands
    private static let ignoredProcesses: Set<String> = [
        // System/session
        "login", "ps", "lsof", "top", "htop", "caffeinate", "open",
        // Short-lived utilities
        "git", "cat", "head", "tail", "less", "more", "vim", "vi", "nano",
        "grep", "rg", "find", "ls", "wc", "sort", "uniq", "sed", "awk",
        "tee", "xargs", "cut", "tr", "which", "env", "printenv", "echo",
        "mkdir", "rm", "cp", "mv", "chmod", "chown", "ln", "touch",
        // Package managers (the runner, not the actual build)
        "npm", "npx",
        // Prompt/theme background daemons
        "gitstatusd-darwin-arm64", "gitstatusd",
        // IDE/tool infrastructure (Claude subprocesses)
        "sourcekit-lsp", "uv",
    ]

    // Batched process discovery: single ps call, filter by known TTYs
    // Uses `args` for full command display (e.g. "make build" instead of "make")
    func discoverProcesses(ttys: [String]) -> ScanResult {
        guard !ttys.isEmpty else { return ScanResult() }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // pid, tty, etime for timing, stat for state (foreground detection), args for full command
        process.arguments = ["-eo", "pid,tty,etime,stat,args"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            os_log("ps command failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            return ScanResult()
        }
        // Read pipe BEFORE waitUntilExit to avoid deadlock when pipe buffer fills
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return ScanResult() }

        // Build set of short TTY names (e.g. "ttys001" from "/dev/ttys001")
        // ps output shows "ttys001", iTerm reports "/dev/ttys001"
        var ttyShortMap: [String: String] = [:]
        for tty in ttys {
            let short = tty.replacingOccurrences(of: "/dev/", with: "")
            ttyShortMap[short] = tty
        }

        var result = ScanResult()
        let lines = output.components(separatedBy: "\n")
        for line in lines.dropFirst() {  // skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split: pid tty etime stat args...
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 5 else { continue }

            let pidStr = String(parts[0])
            let ttyShort = String(parts[1])
            let etime = String(parts[2])
            let stat = String(parts[3])
            let args = String(parts[4])

            guard let pid = Int(pidStr) else { continue }
            guard let fullTTY = ttyShortMap[ttyShort] else { continue }

            // Extract base command name from args
            let firstArg = args.split(separator: " ").first.map(String.init) ?? args
            let baseName = (firstArg as NSString).lastPathComponent.lowercased()

            // Detect Claude process
            if baseName == "claude" || args.lowercased().contains("/claude") {
                result.claudeTTYs.insert(fullTTY)
                continue
            }

            // Track shell PIDs for CWD detection — keep FIRST (login shell has real CWD)
            if baseName == "zsh" || baseName == "bash" || baseName == "fish" || baseName == "sh" ||
               baseName == "-zsh" || baseName == "-bash" || baseName == "-fish" || baseName == "-sh" {
                if result.shellPIDs[fullTTY] == nil {
                    result.shellPIDs[fullTTY] = Int32(pid)
                }
                continue
            }

            // Skip system/utility processes
            if Self.ignoredProcesses.contains(baseName) { continue }

            // Only track foreground processes (stat contains "+" for foreground)
            let isForeground = stat.contains("+")
            guard isForeground else { continue }

            let startTime = parseElapsedTime(etime)

            // Keep the most recent foreground process per TTY
            if let existing = result.processes[fullTTY], existing.startTime > startTime { continue }

            // Build display name from args
            let displayName = buildDisplayName(args: args, baseName: baseName)

            result.processes[fullTTY] = ProcessInfo(
                name: displayName,
                pid: pid,
                startTime: startTime,
                exitCode: nil
            )
        }
        return result
    }

    // Build a readable display name from ps args
    private func buildDisplayName(args: String, baseName: String) -> String {
        let runners: Set<String> = ["node", "python", "python3", "ruby", "perl", "java"]
        let argParts = args.split(separator: " ", omittingEmptySubsequences: true)

        // If the command is a runner (node, python), use the script name instead
        if runners.contains(baseName) && argParts.count >= 2 {
            let scriptPath = String(argParts[1])
            let scriptName = (scriptPath as NSString).lastPathComponent
            // Collect remaining args for context
            if argParts.count >= 3 {
                let rest = argParts[2...].joined(separator: " ")
                return "\(scriptName) \(rest.prefix(30))"
            }
            return scriptName
        }

        // For direct commands: "make build", "bazel build", etc.
        if argParts.count >= 2 {
            let cmd = (String(argParts[0]) as NSString).lastPathComponent
            let rest = argParts[1...].joined(separator: " ")
            return "\(cmd) \(rest.prefix(40))"
        }

        return baseName
    }

    // Batched CWD detection: single lsof call for all shell PIDs
    func detectCWDs(shellPIDs: [String: Int32]) -> [String: String] {
        guard !shellPIDs.isEmpty else { return [:] }

        // Build PID list and PID->TTY reverse map
        var pidToTTY: [Int32: String] = [:]
        let pidList = shellPIDs.map { tty, pid -> String in
            pidToTTY[pid] = tty
            return "\(pid)"
        }.joined(separator: ",")

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-F", "pn", "-p", pidList]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            os_log("lsof command failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        // Parse lsof -F pn output: lines starting with 'p' = PID, 'n' = name (path)
        var result: [String: String] = [:]
        var currentPID: Int32 = 0
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if let tty = pidToTTY[currentPID], !path.isEmpty {
                    result[tty] = path
                }
            }
        }
        return result
    }

    // Parse ps elapsed time format: [[dd-]hh:]mm:ss
    private func parseElapsedTime(_ etime: String) -> Date {
        var totalSeconds = 0
        let cleaned = etime.trimmingCharacters(in: .whitespaces)

        // Handle dd-hh:mm:ss or hh:mm:ss or mm:ss
        var parts = cleaned
        var days = 0
        if let dashIdx = parts.firstIndex(of: "-") {
            days = Int(parts[parts.startIndex..<dashIdx]) ?? 0
            parts = String(parts[parts.index(after: dashIdx)...])
        }

        let timeParts = parts.split(separator: ":").map { Int($0) ?? 0 }
        if timeParts.count == 3 {
            totalSeconds = days * 86400 + timeParts[0] * 3600 + timeParts[1] * 60 + timeParts[2]
        } else if timeParts.count == 2 {
            totalSeconds = days * 86400 + timeParts[0] * 60 + timeParts[1]
        }

        // Guard against negative/unreasonable values (clock skew)
        if totalSeconds < 0 { totalSeconds = 0 }

        return Date().addingTimeInterval(-Double(totalSeconds))
    }
}
