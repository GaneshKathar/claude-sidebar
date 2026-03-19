import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "ITerm2Adapter")

// MARK: - iTerm2 Adapter (full native support via AppleScript)

class ITerm2Adapter: TerminalAdapter {
    let info = TerminalInfo(
        identifier: "iterm2",
        displayName: "iTerm2",
        scriptName: "iTerm2",
        bundleIdentifier: "com.googlecode.iterm2",
        keywords: ["iterm2"]
    )

    var capabilities: TerminalCapabilities {
        [.nativeEnumeration, .nativeFocus, .nativeCreateTab, .nativeCreateWindow, .nativeOpenWithCWD, .nativeCWDFromSession]
    }

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == info.bundleIdentifier }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        if let sid = focus?.iterm_session_id, !sid.isEmpty { return true }
        if let tp = focus?.term_program?.lowercased(), tp.contains("iterm") { return true }
        return processAncestry.contains { $0.contains("iterm2") }
    }

    // MARK: - Enumeration (AppleScript)

    func enumerateSessions(hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow] {
        guard isAvailable() else { return [] }

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

        let cwdResolver = TerminalRegistry.shared.cwdResolver
        var windowMap: [Int: TerminalWindow] = [:]
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

            let hasClaude = hookStates.byTTY[tty] != nil || psInfo.claudeTTYs.contains(tty)

            var claudeState: SessionState = .inactive
            if hasClaude {
                if let ttyState = hookStates.byTTY[tty] {
                    claudeState = SessionState.fromString(ttyState)
                } else {
                    claudeState = .idle
                }
            }

            var cwd: String? = nil
            if hookStates.byTTY[tty] != nil {
                cwd = cwdResolver.readCWDFromHookState(tty: tty)
            }
            if cwd == nil {
                cwd = parseCWD(sessionName: name)
            }

            let tab = TerminalTab(
                tabIndex: tabIndex,
                sessionId: sessionId,
                name: name,
                tty: tty,
                windowId: windowId,
                cwd: cwd,
                hasClaude: hasClaude,
                claudeState: claudeState,
                appName: info.displayName,
                terminalType: info.identifier
            )

            if windowMap[windowId] == nil {
                windowMap[windowId] = TerminalWindow(
                    windowId: windowId,
                    windowName: windowName,
                    displayLabel: "",
                    tabs: [tab],
                    terminalType: info.identifier
                )
                windowOrder.append(windowId)
            } else {
                windowMap[windowId]?.tabs.append(tab)
            }
        }

        let showAll = appConfig.showAllTerminalWindows ?? false

        return windowOrder.compactMap { wid -> TerminalWindow? in
            guard var win = windowMap[wid] else { return nil }
            if showAll {
                win.tabs = win.tabs.map { tab -> TerminalTab in
                    var t = tab
                    t.alwaysShow = true
                    return t
                }
                return win.tabs.isEmpty ? nil : win
            } else {
                win.tabs = win.tabs.filter { $0.hasClaude }
                return win.tabs.isEmpty ? nil : win
            }
        }
    }

    // MARK: - Focus

    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool {
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
                return false
            }
            return true
        }
        return false
    }

    // MARK: - Creation

    func createTab(windowId: Int) -> Bool {
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
                return false
            }
            return true
        }
        return false
    }

    func createWindow() -> Bool {
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
                return false
            }
            return true
        }
        return false
    }

    func openWithCWD(path: String, command: String?) -> Bool {
        let escapedPath = escapeForAppleScript(path)
        let cdCommand = "cd \\\"\(escapedPath)\\\""
        let resolvedCommand = command ?? (appConfig.openCommand ?? ((appConfig.autoStartClaude ?? false) ? "claude" : nil))
        let fullCommand = resolvedCommand.flatMap { $0.isEmpty ? nil : $0 }.map { "\(cdCommand) && \($0)" } ?? cdCommand
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
                os_log("openWithCWD AppleScript error: %{public}@", log: logger, type: .error, error.description)
                return false
            }
            return true
        }
        return false
    }

    // MARK: - CWD Parsing

    func parseCWD(sessionName: String) -> String? {
        var s = sessionName
        if let devRange = s.range(of: "/dev/", options: .backwards) {
            s = String(s[s.startIndex..<devRange.lowerBound])
        }
        if let colonIdx = s.firstIndex(of: ":") {
            let afterColon = s[s.index(after: colonIdx)...]
            if afterColon.hasPrefix("~") || afterColon.hasPrefix("/") {
                s = String(afterColon)
            }
        }
        var chars = CharacterSet.whitespaces
        chars.insert(charactersIn: "\u{2014}\u{2013}-")
        let trimmed = s.trimmingCharacters(in: chars)
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + trimmed.dropFirst(1)
        } else if trimmed == "~" {
            return NSHomeDirectory()
        } else if trimmed.hasPrefix("/") {
            return trimmed
        }
        return nil
    }

    // MARK: - Helpers


    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
