import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "KittyAdapter")

// MARK: - Kitty Adapter (via kitty @ IPC)

class KittyAdapter: TerminalAdapter {
    let info = TerminalInfo(
        identifier: "kitty",
        displayName: "Kitty",
        scriptName: "Kitty",
        bundleIdentifier: "net.kovidgoyal.kitty",
        keywords: ["kitty"]
    )

    var capabilities: TerminalCapabilities {
        [.nativeEnumeration, .nativeFocus, .nativeOpenWithCWD]
    }

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "net.kovidgoyal.kitty" }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        if let tp = focus?.term_program?.lowercased(), tp == "kitty" || tp.contains("kitty") { return true }
        if let kid = focus?.kitty_window_id, !kid.isEmpty { return true }
        return processAncestry.contains { $0.contains("kitty") }
    }

    func enumerateSessions(hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow] {
        // Use kitty @ ls to enumerate windows/tabs
        guard let json = runKittyCommand(["@", "ls"]) else { return [] }
        guard let data = json.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var windows: [TerminalWindow] = []
        for osWindow in osWindows {
            guard let wid = osWindow["id"] as? Int,
                  let tabs = osWindow["tabs"] as? [[String: Any]] else { continue }
            var termTabs: [TerminalTab] = []
            for (tabIdx, tab) in tabs.enumerated() {
                guard let kittyWindows = tab["windows"] as? [[String: Any]] else { continue }
                for kw in kittyWindows {
                    guard let pid = kw["pid"] as? Int else { continue }
                    let cwd = kw["cwd"] as? String
                    let title = kw["title"] as? String ?? ""
                    let tty = "/dev/ttys\(String(format: "%03d", pid % 1000))" // approximate
                    let hasClaude = hookStates.byTTY[tty] != nil
                    let state: SessionState = hasClaude
                        ? (hookStates.byTTY[tty].map { SessionState.fromString($0) } ?? .idle)
                        : .inactive
                    termTabs.append(TerminalTab(
                        tabIndex: tabIdx,
                        sessionId: "\(kw["id"] ?? 0)",
                        name: title,
                        tty: tty,
                        windowId: wid,
                        cwd: cwd,
                        hasClaude: hasClaude,
                        claudeState: state,
                        appName: "Kitty",
                        terminalType: "kitty"
                    ))
                }
            }
            if !termTabs.isEmpty {
                windows.append(TerminalWindow(
                    windowId: wid,
                    windowName: "Kitty",
                    displayLabel: "",
                    tabs: termTabs,
                    terminalType: "kitty"
                ))
            }
        }
        return windows
    }

    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool {
        let result = runKittyCommand(["@", "focus-window", "--match", "id:\(sessionId)"])
        return result != nil
    }

    func openWithCWD(path: String, command: String?) -> Bool {
        let result = runKittyCommand(["@", "launch", "--type=os-window", "--cwd=\(path)"])
        return result != nil
    }

    func isPluginConfigured() -> Bool {
        // Test if kitty @ ls succeeds (requires allow_remote_control)
        return runKittyCommand(["@", "ls"]) != nil
    }

    var setupInstructions: String? {
        "Add 'allow_remote_control yes' to ~/.config/kitty/kitty.conf for full integration."
    }

    private func runKittyCommand(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/kitty")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Try homebrew path
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/kitty")
            do { try process.run() } catch { return nil }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
