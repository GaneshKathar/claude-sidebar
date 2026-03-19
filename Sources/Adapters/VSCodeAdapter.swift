import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "VSCodeAdapter")

// MARK: - VS Code Adapter

class VSCodeAdapter: TerminalAdapter {
    let info = TerminalInfo(
        identifier: "vscode",
        displayName: "VS Code",
        scriptName: "Visual Studio Code",
        bundleIdentifier: "com.microsoft.VSCode",
        keywords: ["code"]
    )

    var capabilities: TerminalCapabilities { [.nativeFocus] }

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.microsoft.VSCode" }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        if focus?.term_program?.lowercased() == "vscode" { return true }
        return processAncestry.contains { $0.contains("code") }
    }

    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool {
        // Activate VS Code first
        let activateScript = """
        tell application "Visual Studio Code"
            activate
        end tell
        """
        if let as_ = NSAppleScript(source: activateScript) {
            var err: NSDictionary?
            as_.executeAndReturnError(&err)
        }

        // Try extension socket for terminal focus
        guard let sockPath = findVSCodeSocket() else {
            os_log("focusVSCode: extension socket not found", log: logger, type: .info)
            return true  // At least we activated VS Code
        }

        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.3)
            self.focusVSCodeTerminal(tty: sessionId, sockPath: sockPath)
        }
        return true
    }

    func isPluginConfigured() -> Bool {
        FileManager.default.fileExists(atPath: "/tmp/vscode-sidebar.sock")
    }

    var setupInstructions: String? {
        "Install the claude-sidebar-focus VS Code extension for terminal focus support."
    }

    private func findVSCodeSocket() -> String? {
        guard let content = try? String(contentsOfFile: "/tmp/vscode-sidebar.sock", encoding: .utf8) else { return nil }
        let sockPath = content.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.fileExists(atPath: sockPath) ? sockPath : nil
    }

    private func focusVSCodeTerminal(tty: String, sockPath: String) {
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
            os_log("focusVSCode: connect failed errno=%d", log: logger, type: .error, errno)
            return
        }
        let request = ["method": "focusByTTY", "tty": tty]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else { return }
        let msg = line + "\n"
        _ = msg.withCString { send(sockFd, $0, strlen($0), 0) }
        var buf = [CChar](repeating: 0, count: 1024)
        _ = recv(sockFd, &buf, 1023, 0)
    }
}
