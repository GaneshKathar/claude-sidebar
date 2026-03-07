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
    private var nextLetterIdx = 0

    private static let maxCacheSize = 500
    private static let maxBranchWalkDepth = 50

    func readHookStates() -> HookStates {
        return stateReader.readStates()
    }

    func scan() -> [ITermWindowInfo] {
        guard !appleScriptInFlight else { return [] }
        appleScriptInFlight = true
        defer { appleScriptInFlight = false }

        let hookStates = stateReader.readStates()
        let rawWindows = queryITerm(hookStates: hookStates)

        // Resolve CWD and branch for tabs with activity
        var windows = rawWindows
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
        let script = """
        tell application "System Events"
            if not (exists process "iTerm2") then return ""
        end tell
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
                processInfo: nil
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
        // Others get sticky "A","B",... that persist until the app restarts.
        // Prune cached labels for windows that no longer exist.
        let currentIds = Set(windowOrder)
        labelCache = labelCache.filter { currentIds.contains($0.key) }

        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for wid in windowOrder {
            guard var win = windowMap[wid] else { continue }
            if let repoNum = matchWindowToRepo(win) {
                win.displayLabel = "\(repoNum)"
            } else if let cached = labelCache[wid] {
                win.displayLabel = cached
            } else {
                let letter = nextLetterIdx < letters.count
                    ? String(letters[letters.index(letters.startIndex, offsetBy: nextLetterIdx)])
                    : "\(nextLetterIdx)"
                win.displayLabel = letter
                labelCache[wid] = letter
                nextLetterIdx += 1
            }
            windowMap[wid] = win
        }

        return windowOrder.compactMap { windowMap[$0] }
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

    // Check if any Claude tab in this window has a CWD matching a configured repo
    private func matchWindowToRepo(_ win: ITermWindowInfo) -> Int? {
        for tab in win.tabs {
            guard let cwd = tab.cwd else { continue }
            for repo in appConfig.repos {
                let repoPath = repo.expandedPath
                if cwd == repoPath || cwd.hasPrefix(repoPath + "/") {
                    return repo.num
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
        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let hookState = try? JSONDecoder().decode(HookState.self, from: data) else { continue }
            if let hookTTY = hookState.tty, hookTTY == tty {
                return hookState.cwd.isEmpty ? nil : hookState.cwd
            }
        }
        return nil
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

    // Public cached branch lookup (called from SidebarController.fastPoll)
    func getBranchCached(cwd: String) -> String? {
        let cacheTTL = appConfig.branchCacheTTL ?? 10.0
        if let cached = branchCache[cwd], Date().timeIntervalSince(cached.1) < cacheTTL {
            return cached.0
        }
        if let branch = getBranch(cwd: cwd) {
            branchCache[cwd] = (branch, Date())
            return branch
        }
        return nil
    }

    private func getBranch(cwd: String) -> String? {
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

    // Escape string for use in AppleScript string literals
    private func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func focusSession(windowId: Int, sessionId: String) {
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
}
