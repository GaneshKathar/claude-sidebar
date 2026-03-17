import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "ITermScanner")


// MARK: - iTerm2 Scanner (Window-Centric)

class ITermScanner {
    private let stateReader = StateReader()
    private var branchCache: [String: (String, Date)] = [:]  // cwd path -> (branch, time)
    private var cwdCache: [String: (String, Date)] = [:]     // tty -> (cwd, time)
    private var appleScriptInFlight = false
    private var labelCache: [Int: String] = [:]              // windowId -> stable label
    private var nextNonRepoNum = 0                             // initialized on first scan

    // Generic terminal support: stable IDs for non-iTerm windows
    private var genericWindowIds: [String: Int] = [:]           // terminalApp -> windowId
    private var genericWindowApps: [Int: String] = [:]          // windowId -> terminalApp display name
    private var genericWindowPIDs: [Int: Int32] = [:]           // windowId -> terminal app PID (for activation)
    private var genericWindowIdCounter = -10000

    // Terminal focus data written by the hook at SessionStart (one file per TTY)
    private var terminalFocusByTTY: [String: TerminalFocus] = [:]

    private static let maxCacheSize = 500
    private static let maxBranchWalkDepth = 50

    // Known terminal emulators: keyword in process name -> (displayName, scriptName for AppleScript)
    // internal so SidebarController can use the same list for cross-terminal window watching
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

    func readHookStates() -> HookStates {
        return stateReader.readStates()
    }

    func scan() -> [ITermWindowInfo] {
        guard !appleScriptInFlight else { return [] }
        appleScriptInFlight = true
        defer { appleScriptInFlight = false }

        let hookStates = stateReader.readStates()
        terminalFocusByTTY = stateReader.readFocusFiles()   // terminal identity per TTY

        let itermWindows = queryITerm(hookStates: hookStates)

        // Add sessions from other terminals not already tracked by iTerm
        let itermTTYs = Set(itermWindows.flatMap { $0.tabs.map { $0.tty } })
        let genericWindows = scanGenericTerminals(excludeTTYs: itermTTYs, hookStates: hookStates)

        // Resolve CWD and branch for all tabs
        var windows = itermWindows + genericWindows
        let cacheTTL = appConfig.branchCacheTTL ?? 10.0
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                let tab = windows[wi].tabs[ti]

                // CWD detection (cached 10s per TTY)
                if tab.cwd == nil {
                    if let cached = cwdCache[tab.tty], Date().timeIntervalSince(cached.1) < 10.0 {
                        windows[wi].tabs[ti].cwd = cached.0
                    } else {
                        if let cwd = detectCWD(tty: tab.tty) {
                            windows[wi].tabs[ti].cwd = cwd
                            cwdCache[tab.tty] = (cwd, Date())
                        }
                    }
                }

                // Branch lookup (cached per CWD path)
                if let cwd = windows[wi].tabs[ti].cwd {
                    if let cached = branchCache[cwd], Date().timeIntervalSince(cached.1) < cacheTTL {
                        windows[wi].tabs[ti].gitBranch = cached.0
                    } else {
                        if let branch = getBranch(cwd: cwd) {
                            windows[wi].tabs[ti].gitBranch = branch
                            branchCache[cwd] = (branch, Date())
                        }
                    }
                }
            }
        }

        trimCaches()
        return windows
    }

    // MARK: - Generic Terminal Scanner

    private struct GenericScanResult {
        var claudeTTYs: Set<String> = []
        var shellPIDs: [String: Int32] = [:]
        var pidToPPID: [Int32: Int32] = [:]
        var pidToComm: [Int32: String] = [:]
    }

    // Run ps -eo pid,ppid,tty,comm to find ALL Claude processes and build process tree
    private func scanAllClaudeProcesses() -> GenericScanResult {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,ppid,tty,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            os_log("scanAllClaudeProcesses ps failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            return GenericScanResult()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return GenericScanResult() }

        var result = GenericScanResult()
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

            // Strip leading dash from login shells (-zsh, -bash)
            let strippedComm = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
            let baseName = (strippedComm as NSString).lastPathComponent.lowercased()

            if baseName == "claude" {
                result.claudeTTYs.insert(fullTTY)
            } else if ["zsh", "bash", "fish", "sh"].contains(baseName) {
                if result.shellPIDs[fullTTY] == nil {
                    result.shellPIDs[fullTTY] = pid
                }
            }
        }
        return result
    }


    // Send workspace.select to the cmux socket to focus a specific tab.
    // Requires cmux to be in "Automation mode" (Settings → Socket Control).
    private func focusCmuxWorkspace(workspaceId: String, socketPath: String) {
        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else {
            os_log("focusCmuxWorkspace: socket() failed errno=%d", log: logger, type: .error, errno)
            return
        }
        defer { close(sockFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                guard let baseAddr = dst.baseAddress else { return }
                _ = strlcpy(baseAddr.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }

        let connectResult = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sockFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            os_log("focusCmuxWorkspace: connect failed errno=%d — enable Automation mode in cmux Settings → Socket Control", log: logger, type: .error, errno)
            return
        }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": "workspace.select",
            "params": ["workspace_id": workspaceId]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else { return }

        let msg = line + "\n"
        msg.withCString { send(sockFd, $0, strlen($0), 0) }

        // Read response
        var buf = [CChar](repeating: 0, count: 4096)
        let n = recv(sockFd, &buf, 4095, 0)
        let resp = n > 0 ? String(cString: buf) : "(no response)"
    }

    // Find the VS Code extension socket path from the indicator file it writes.
    private func findVSCodeSocket() -> String? {
        guard let content = try? String(contentsOfFile: "/tmp/vscode-sidebar.sock", encoding: .utf8) else { return nil }
        let sockPath = content.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.fileExists(atPath: sockPath) ? sockPath : nil
    }

    // Send focusByTTY to the VS Code extension socket.
    private func focusVSCodeTerminal(tty: String) {
        guard let sockPath = findVSCodeSocket() else {
            os_log("focusVSCodeTerminal: extension socket not found (install claude-sidebar-focus extension in VS Code)", log: logger, type: .info)
            return
        }

        // AppleScript activate is more reliable than NSRunningApplication.activate on macOS 14+
        let activateScript = """
        tell application "Visual Studio Code"
            activate
        end tell
        """
        if let as_ = NSAppleScript(source: activateScript) {
            var err: NSDictionary?
            as_.executeAndReturnError(&err)
        }
        // Give VS Code time to come to front before focusing the terminal inside it
        Thread.sleep(forTimeInterval: 0.3)

        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else { return }
        defer { close(sockFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        sockPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                guard let baseAddr = dst.baseAddress else { return }
                _ = strlcpy(baseAddr.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        let connected = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sockFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            os_log("focusVSCodeTerminal: connect failed errno=%d", log: logger, type: .error, errno)
            return
        }
        let request = ["method": "focusByTTY", "tty": tty]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else { return }
        let msg = line + "\n"
        msg.withCString { send(sockFd, $0, strlen($0), 0) }
        var buf = [CChar](repeating: 0, count: 1024)
        recv(sockFd, &buf, 1023, 0)
    }

    // Map TERM_PROGRAM env var value → display name
    private func appNameFromTermProgram(_ tp: String?) -> String? {
        guard let s = tp?.lowercased(), !s.isEmpty else { return nil }
        for m in Self.terminalAppMappings {
            if s.contains(m.keyword) { return m.displayName }
        }
        return nil
    }

    // Map display name → AppleScript-compatible app name
    private func scriptNameForApp(_ displayName: String) -> String {
        Self.terminalAppMappings.first { $0.displayName == displayName }?.scriptName ?? displayName
    }

    // Walk the process tree from the shell on this TTY to identify the terminal app.
    // Returns (displayName, terminalPID) — PID is used for direct activation.
    // Focus-file term_program is checked first (reliable through cmux/tmux layers).
    private func detectTerminalApp(for tty: String, psInfo: GenericScanResult) -> (name: String, pid: Int32?) {
        if let focus = terminalFocusByTTY[tty] {
            // cmux sessions: show "cmux" unless the terminal has its own focus mechanism
            // (VS Code uses its extension socket; iTerm2 uses AppleScript — cmux label is irrelevant for those)
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

    // Find the PID of a running terminal app by matching its name in NSWorkspace
    private func pidForTerminalApp(name: String, tty: String, psInfo: GenericScanResult) -> Int32? {
        let lower = name.lowercased()
        // Check process tree first
        if let shellPID = psInfo.shellPIDs[tty] {
            var pid = shellPID
            for _ in 0..<10 {
                guard let ppid = psInfo.pidToPPID[pid], ppid > 1,
                      let comm = psInfo.pidToComm[ppid] else { break }
                if (comm as NSString).lastPathComponent.lowercased().contains(lower) { return ppid }
                pid = ppid
            }
        }
        // Fall back to NSWorkspace running apps
        return NSWorkspace.shared.runningApplications
            .first { $0.localizedName?.lowercased().contains(lower) ?? false }
            .map { Int32($0.processIdentifier) }
    }

    // Find Claude sessions in terminals other than iTerm, return as virtual windows
    private func scanGenericTerminals(excludeTTYs: Set<String>, hookStates: HookStates) -> [ITermWindowInfo] {
        // ps scan first — needed for both Claude detection and terminal liveness check
        let psInfo = scanAllClaudeProcesses()

        // ps-detected Claude processes are always valid (process is running right now)
        var candidateTTYs = psInfo.claudeTTYs.subtracting(excludeTTYs)

        // Hook-state TTYs: only include if the terminal is still alive (shell or Claude running).
        // This ensures closed terminals disappear immediately instead of waiting for staleTimeout.
        for tty in hookStates.byTTY.keys where !excludeTTYs.contains(tty) {
            if psInfo.shellPIDs[tty] != nil || psInfo.claudeTTYs.contains(tty) {
                candidateTTYs.insert(tty)
            }
        }

        guard !candidateTTYs.isEmpty else { return [] }

        // Group TTYs by terminal app — key is display name, value also carries a representative PID
        var groups: [String: (ttys: [String], pid: Int32?)] = [:]
        for tty in candidateTTYs {
            let (name, pid) = detectTerminalApp(for: tty, psInfo: psInfo)
            if groups[name] == nil {
                groups[name] = (ttys: [], pid: pid)
            }
            groups[name]!.ttys.append(tty)
        }

        // Create one virtual window per terminal app
        var windows: [ITermWindowInfo] = []
        for (appName, group) in groups.sorted(by: { $0.key < $1.key }) {
            let ttys = group.ttys
            if genericWindowIds[appName] == nil {
                genericWindowIds[appName] = genericWindowIdCounter
                genericWindowApps[genericWindowIdCounter] = appName
                genericWindowIdCounter -= 1
            }
            let windowId = genericWindowIds[appName]!
            // Always refresh PID — the terminal may have restarted
            if let pid = group.pid {
                genericWindowPIDs[windowId] = pid
            }

            let tabs: [ITermTabInfo] = ttys.sorted().enumerated().map { idx, tty in
                let claudeRunning = psInfo.claudeTTYs.contains(tty)
                // If Claude is not currently running, show idle rather than a stale working/alert
                let state = claudeRunning
                    ? (hookStates.byTTY[tty].map { SessionState.fromString($0) } ?? .idle)
                    : .idle
                let cwd = readCWDFromHookState(tty: tty)
                return ITermTabInfo(
                    tabIndex: idx,
                    sessionId: tty,
                    name: (tty as NSString).lastPathComponent,
                    tty: tty,
                    windowId: windowId,
                    cwd: cwd,
                    gitBranch: nil,
                    hasClaude: claudeRunning,  // ps is ground truth; instantUpdate() handles new sessions via Darwin notification
                    claudeState: state,
                    processInfo: nil,
                    appName: appName
                )
            }

            // Repo matching: check if any tab's CWD is under a configured repo
            var matchedRepoNum: Int? = nil
            for tab in tabs {
                if let cwd = tab.cwd {
                    if let repo = appConfig.repos.first(where: { r in
                        let rp = r.expandedPath
                        return cwd == rp || cwd.hasPrefix(rp + "/")
                    }) {
                        matchedRepoNum = repo.num
                        break
                    }
                }
            }

            // Stable display label
            let displayLabel: String
            if let repoNum = matchedRepoNum,
               let repo = appConfig.repos.first(where: { $0.num == repoNum }) {
                displayLabel = repo.displayLabel
            } else if let cached = labelCache[windowId] {
                displayLabel = cached
            } else {
                let label = "\(nextNonRepoNum)"
                nextNonRepoNum += 1
                labelCache[windowId] = label
                displayLabel = label
            }

            windows.append(ITermWindowInfo(
                windowId: windowId,
                windowName: appName,
                displayLabel: displayLabel,
                tabs: tabs,
                matchedRepoNum: matchedRepoNum
            ))
        }
        return windows
    }

    // Trim caches to prevent unbounded growth
    private func trimCaches() {
        if branchCache.count > Self.maxCacheSize {
            // Remove oldest entries
            let sorted = branchCache.sorted { $0.value.1 < $1.value.1 }
            let toRemove = sorted.prefix(branchCache.count - Self.maxCacheSize / 2)
            for (key, _) in toRemove { branchCache.removeValue(forKey: key) }
        }
        if cwdCache.count > Self.maxCacheSize {
            let sorted = cwdCache.sorted { $0.value.1 < $1.value.1 }
            let toRemove = sorted.prefix(cwdCache.count - Self.maxCacheSize / 2)
            for (key, _) in toRemove { cwdCache.removeValue(forKey: key) }
        }
    }

    private func queryITerm(hookStates: HookStates) -> [ITermWindowInfo] {
        // Use NSWorkspace instead of System Events to check for iTerm2 — no Automation prompt needed
        let iTerm2Running = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
        guard iTerm2Running else { return [] }

        let script = """
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                set wID to id of w
                set wName to name of w
                set tIndex to 0
                repeat with t in tabs of w
                    set tIndex to tIndex + 1
                    repeat with s in sessions of t
                        set sName to name of s
                        set sTTY to tty of s
                        set sID to unique ID of s
                        set output to output & wID & "\\t" & wName & "\\t" & tIndex & "\\t" & sID & "\\t" & sName & "\\t" & sTTY & "\\n"
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            os_log("AppleScript query error: %{public}@", log: logger, type: .error, error.description)
            return []
        }
        guard let output = result.stringValue else { return [] }

        // Parse into window -> tab hierarchy
        var windowMap: [Int: ITermWindowInfo] = [:]  // ordered by first appearance
        var windowOrder: [Int] = []

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 6 else { continue }

            let windowId = Int(parts[0]) ?? 0
            let windowName = parts[1]
            let tabIndex = Int(parts[2]) ?? 0
            let sessionId = parts[3]
            let name = parts[4]
            let tty = parts[5]

            // Detect Claude: hook state (reliable) or title hint (refined by ps scan later)
            let hasClaude = hookStates.byTTY[tty] != nil || isClaudeInTitle(name)

            var claudeState: SessionState = .inactive
            if hasClaude {
                if let ttyState = hookStates.byTTY[tty] {
                    claudeState = SessionState.fromString(ttyState)
                } else {
                    claudeState = .idle
                }
            }

            // CWD: from hook state first, then parse from session name
            var cwd: String? = nil
            if hookStates.byTTY[tty] != nil {
                cwd = readCWDFromHookState(tty: tty)
            }
            if cwd == nil {
                cwd = parseCWDFromSessionName(name)
            }

            let tab = ITermTabInfo(
                tabIndex: tabIndex,
                sessionId: sessionId,
                name: name,
                tty: tty,
                windowId: windowId,
                cwd: cwd,
                gitBranch: nil,
                hasClaude: hasClaude,
                claudeState: claudeState,
                processInfo: nil,
                appName: "iTerm2"
            )

            if windowMap[windowId] == nil {
                windowMap[windowId] = ITermWindowInfo(
                    windowId: windowId,
                    windowName: windowName,
                    displayLabel: "",  // assigned after all tabs collected
                    tabs: [tab]
                )
                windowOrder.append(windowId)
            } else {
                windowMap[windowId]?.tabs.append(tab)
            }
        }

        // Assign display labels: repo-matched windows get "1","2",...
        // Others get sequential numbers continuing after repos (5,6,7...).
        // Labels are never pruned — once assigned, a number is consumed for the session.
        if nextNonRepoNum == 0 {
            nextNonRepoNum = 1
        }

        for wid in windowOrder {
            guard var win = windowMap[wid] else { continue }
            if let repo = matchWindowToRepo(win) {
                win.displayLabel = repo.displayLabel
                win.matchedRepoNum = repo.num
            } else if let cached = labelCache[wid] {
                win.displayLabel = cached
            } else {
                let label = "\(nextNonRepoNum)"
                nextNonRepoNum += 1
                win.displayLabel = label
                labelCache[wid] = label
            }
            windowMap[wid] = win
        }

        // Only return windows that have at least one Claude session — consistent with
        // generic terminal behaviour (Ghostty/VS Code are also Claude-only).
        return windowOrder.compactMap { wid -> ITermWindowInfo? in
            guard var win = windowMap[wid] else { return nil }
            win.tabs = win.tabs.filter { $0.hasClaude }
            return win.tabs.isEmpty ? nil : win
        }
    }

    // Detect "claude" as a process name in iTerm session title, not inside a path
    private func isClaudeInTitle(_ name: String) -> Bool {
        let lc = name.lowercased()
        guard let range = lc.range(of: "claude") else { return false }

        // Check character BEFORE "claude" — if it's "/" or a letter, it's part of a path/word
        if range.lowerBound > lc.startIndex {
            let before = lc[lc.index(before: range.lowerBound)]
            if before == "/" || before.isLetter { return false }
        }

        // Check character AFTER "claude" — if it's "-" or a letter, it's part of a compound word
        if range.upperBound < lc.endIndex {
            let after = lc[range.upperBound]
            if after == "-" || after.isLetter { return false }
        }

        return true
    }

    // Check if any tab in this window has a CWD matching a configured repo
    private func matchWindowToRepo(_ win: ITermWindowInfo) -> RepoConfig? {
        for tab in win.tabs {
            guard let cwd = tab.cwd else { continue }
            for repo in appConfig.repos {
                let repoPath = repo.expandedPath
                if cwd == repoPath || cwd.hasPrefix(repoPath + "/") {
                    return repo
                }
            }
        }
        return nil
    }

    // Parse CWD from iTerm session name like "user@host:~/path — /dev/ttyXXX" or just "~/path"
    private func parseCWDFromSessionName(_ name: String) -> String? {
        var s = name

        // Strip "/dev/ttyXXX" and everything around it (any dash variant)
        if let devRange = s.range(of: "/dev/", options: .backwards) {
            s = String(s[s.startIndex..<devRange.lowerBound])
        }

        // Strip "user@host:" prefix (e.g. "APAC-J9NF:~/rubrik/...")
        if let colonIdx = s.firstIndex(of: ":") {
            let afterColon = s[s.index(after: colonIdx)...]
            if afterColon.hasPrefix("~") || afterColon.hasPrefix("/") {
                s = String(afterColon)
            }
        }

        // Trim trailing spaces, dashes (em-dash, en-dash, hyphen), and other junk
        var chars = CharacterSet.whitespaces
        chars.insert(charactersIn: "\u{2014}\u{2013}-")
        let trimmed = s.trimmingCharacters(in: chars)

        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") {
            if trimmed.hasPrefix("~/") {
                return NSHomeDirectory() + trimmed.dropFirst(1)
            } else if trimmed == "~" {
                return NSHomeDirectory()
            }
            return trimmed
        }
        return nil
    }

    private func readCWDFromHookState(tty: String) -> String? {
        let fm = FileManager.default
        let stateDir = "/tmp/claude-sidebar"
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return nil }
        // A TTY can be recycled across sessions — keep only the most recent match
        var bestCWD: String? = nil
        var bestTimestamp: Double = 0
        for file in files where file.hasSuffix(".json") && !file.hasPrefix("focus") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let hookState = try? JSONDecoder().decode(HookState.self, from: data),
                  let hookTTY = hookState.tty, hookTTY == tty else { continue }
            if hookState.timestamp > bestTimestamp {
                bestTimestamp = hookState.timestamp
                bestCWD = hookState.cwd.isEmpty ? nil : hookState.cwd
            }
        }
        return bestCWD
    }

    func detectCWD(tty: String) -> String? {
        // Sanitize tty for shell command — only allow /dev/ttyXXX pattern
        guard tty.hasPrefix("/dev/") && !tty.contains(";") && !tty.contains("$") && !tty.contains("`") else {
            os_log("Invalid TTY format: %{public}@", log: logger, type: .error, tty)
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "lsof -a -d cwd +D /dev -F n -t \(tty) 2>/dev/null | head -1 | xargs -I{} lsof -a -d cwd -p {} -F n 2>/dev/null | grep ^n/ | head -1 | cut -c2-"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            os_log("detectCWD failed for tty %{public}@: %{public}@", log: logger, type: .error, tty, error.localizedDescription)
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == true ? nil : result
    }

    func getBranch(cwd: String) -> String? {
        // Walk up from CWD to find git repo, with depth limit
        var path = cwd
        let fm = FileManager.default
        var depth = 0
        while path != "/" && depth < Self.maxBranchWalkDepth {
            depth += 1
            if fm.fileExists(atPath: path + "/.git") {
                let pipe = Pipe()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", path, "branch", "--show-current"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    os_log("git branch failed for %{public}@: %{public}@", log: logger, type: .error, path, error.localizedDescription)
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    // Activate a terminal app (bring to front).
    // NSWorkspace.open(bundleURL) triggers macOS 15 App Management permission — avoid it.
    // Use activate(from:) on macOS 14+ (proper API, no extra permission needed),
    // then AppleScript as fallback when the app isn't found via NSWorkspace.
    private func activateApp(_ app: NSRunningApplication?, fallbackName: String) {
        if let app = app {
            if #available(macOS 14.0, *) {
                app.activate(from: NSRunningApplication.current, options: [])
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
            return
        }
        // App not found via NSWorkspace — use AppleScript
        let escaped = escapeForAppleScript(scriptNameForApp(fallbackName))
        let script = "tell application \"\(escaped)\" to activate"
        if let as_ = NSAppleScript(source: script) {
            var err: NSDictionary?
            as_.executeAndReturnError(&err)
            if let e = err {
                os_log("activateApp: error for '%{public}@': %{public}@", log: logger, type: .error, fallbackName, e.description)
            }
        }
    }

    // Escape string for use in AppleScript string literals
    private func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func focusSession(windowId: Int, sessionId: String) {
        // sessionId = iTerm session UUID (for iTerm windows) or TTY path (for generic windows)
        let tty = genericWindowApps[windowId] != nil ? sessionId : nil   // TTY for generic terminals

        // --- Generic (non-iTerm) terminal ---
        if let appName = genericWindowApps[windowId] {
            // Activate the terminal app — try PID cache, then NSWorkspace, then AppleScript
            let app: NSRunningApplication?
            if let pid = genericWindowPIDs[windowId] {
                app = NSRunningApplication(processIdentifier: pid)
            } else {
                // Use the mapping keyword (e.g. "code" for "VS Code") so NSWorkspace matches
                // the real process name ("Code") rather than our display name ("VS Code")
                let keyword = Self.terminalAppMappings
                    .first { $0.displayName == appName }?.keyword ?? appName.lowercased()
                app = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.lowercased().contains(keyword) ?? false
                }
            }
            // Read focus file fresh from disk — avoids data race with background scan thread
            let focusData = stateReader.readFocusFiles()
            if let focus = focusData[sessionId] {
                let term = focus.term_program?.lowercased() ?? ""

                if term == "vscode" {
                    activateApp(app, fallbackName: appName)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.focusVSCodeTerminal(tty: sessionId)
                    }
                    return
                }
                if let wsId = focus.cmux_workspace_id, !wsId.isEmpty,
                   let sockPath = focus.cmux_socket_path, !sockPath.isEmpty {
                    // Select workspace first, then bring the HOST terminal (Ghostty) to front.
                    // Use the host app name from term_program, not the display name "cmux".
                    focusCmuxWorkspace(workspaceId: wsId, socketPath: sockPath)
                    let hostName = appNameFromTermProgram(term) ?? appName
                    activateApp(app, fallbackName: hostName)
                    return
                }
            }

            // Fallback: activate app then use System Events window-title match
            activateApp(app, fallbackName: appName)
            if let app = app {
                let cwd = detectCWD(tty: sessionId)
                focusGenericWindow(app: app, tty: sessionId, cwd: cwd)
            }
            return
        }

        // --- iTerm2 tab (identified by session UUID) ---
        // Check focus file for iTerm session UUID (may differ from windowId-based lookup)
        let escapedSessionId = escapeForAppleScript(sessionId)
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                if id of w is \(windowId) then
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique ID of s is "\(escapedSessionId)" then
                                select s
                                select t
                            end if
                        end repeat
                    end repeat
                    set index of w to 1
                end if
            end repeat
            activate
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                os_log("focusSession AppleScript error: %{public}@", log: logger, type: .error, error.description)
            }
        }
    }

    // Use System Events AppleScript to raise the specific window inside a non-iTerm terminal.
    // Matches by window title containing the TTY name or CWD components.
    // Requires Accessibility permission (System Preferences → Privacy → Accessibility).
    private func focusGenericWindow(app: NSRunningApplication, tty: String, cwd: String?) {
        guard let appName = app.localizedName, !appName.isEmpty else { return }
        let escaped = escapeForAppleScript(appName)

        let ttyName = (tty as NSString).lastPathComponent
        var candidates: [String] = [ttyName]
        if let cwd = cwd {
            let home = NSHomeDirectory()
            let short = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            candidates.append(contentsOf: [(cwd as NSString).lastPathComponent, short, cwd])
        }

        let conditions = candidates
            .map { escapeForAppleScript($0) }
            .map { "wTitle contains \"\($0)\"" }
            .joined(separator: " or ")

        let script = """
        tell application "System Events"
            tell process "\(escaped)"
                set frontmost to true
                repeat with w in windows
                    set wTitle to title of w
                    if \(conditions) then
                        perform action "AXRaise" of w
                        exit repeat
                    end if
                end repeat
            end tell
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let e = error {
                os_log("focusGenericWindow error: %{public}@", log: logger, type: .error, e.description)
            }
        }
    }

    func createTab(windowId: Int) {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                if id of w is \(windowId) then
                    tell w to create tab with default profile
                end if
            end repeat
            activate
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                os_log("createTab AppleScript error: %{public}@", log: logger, type: .error, error.description)
            }
        }
    }

    func createWindow() {
        let script = """
        tell application "iTerm2"
            activate
            create window with default profile
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                os_log("createWindow AppleScript error: %{public}@", log: logger, type: .error, error.description)
            }
        }
    }

    func openWindowWithCWD(path: String, autoStartClaude: Bool = false) {
        let escapedPath = escapeForAppleScript(path)
        let cdCommand = "cd \\\"\(escapedPath)\\\""
        let fullCommand = autoStartClaude ? "\(cdCommand) && claude" : cdCommand
        let script = """
        tell application "iTerm2"
            activate
            set newWin to (create window with default profile)
            tell current session of newWin
                write text "\(fullCommand)"
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                os_log("openWindowWithCWD AppleScript error: %{public}@", log: logger, type: .error, error.description)
            }
        }
    }
}
