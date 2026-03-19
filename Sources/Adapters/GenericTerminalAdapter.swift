import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "GenericTerminalAdapter")

// MARK: - Generic Terminal Adapter (parameterized catch-all)

class GenericTerminalAdapter: TerminalAdapter {
    let info: TerminalInfo
    var capabilities: TerminalCapabilities { [] }

    init(info: TerminalInfo) {
        self.info = info
    }

    func isAvailable() -> Bool {
        if let bundleId = info.bundleIdentifier {
            return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
        }
        return NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased().contains(info.keywords.first ?? "") ?? false
        }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        if let tp = focus?.term_program?.lowercased() {
            for kw in info.keywords {
                if tp.contains(kw) { return true }
            }
        }
        for ancestor in processAncestry {
            for kw in info.keywords {
                if ancestor.contains(kw) { return true }
            }
        }
        return false
    }

    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool {
        // Try to find and activate the app
        let app = findApp()
        activateApp(app)

        // Use System Events window-title match for precise focus
        if let app = app {
            return focusGenericWindow(app: app, tty: sessionId)
        }
        return false
    }

    func openWithCWD(path: String, command: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", info.scriptName, path]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func findApp() -> NSRunningApplication? {
        if let bundleId = info.bundleIdentifier {
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
        }
        let keyword = info.keywords.first ?? info.identifier
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased().contains(keyword) ?? false
        }
    }

    private func activateApp(_ app: NSRunningApplication?) {
        if let app = app {
            if #available(macOS 14.0, *) {
                app.activate(from: NSRunningApplication.current, options: [])
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
            return
        }
        let escaped = escapeForAppleScript(info.scriptName)
        let script = "tell application \"\(escaped)\" to activate"
        if let as_ = NSAppleScript(source: script) {
            var err: NSDictionary?
            as_.executeAndReturnError(&err)
        }
    }

    private func focusGenericWindow(app: NSRunningApplication, tty: String) -> Bool {
        guard let appName = app.localizedName, !appName.isEmpty else { return false }
        let escaped = escapeForAppleScript(appName)
        let ttyName = (tty as NSString).lastPathComponent

        let script = """
        tell application "System Events"
            tell process "\(escaped)"
                set frontmost to true
                repeat with w in windows
                    set wTitle to title of w
                    if wTitle contains "\(escapeForAppleScript(ttyName))" then
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
                return false
            }
            return true
        }
        return false
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
