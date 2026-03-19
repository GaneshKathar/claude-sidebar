import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "CmuxAdapter")
private let cmuxBundleId = "com.cmuxterm.app"

// MARK: - cmux Adapter (surface-level enumeration + focus via socket API)

class CmuxAdapter: TerminalAdapter {
    let info = TerminalInfo(
        identifier: "cmux",
        displayName: "cmux",
        scriptName: "cmux",
        bundleIdentifier: cmuxBundleId,
        keywords: ["cmux"]
    )

    var capabilities: TerminalCapabilities { [.nativeEnumeration, .nativeFocus] }

    /// Maps surface UUID → (workspaceId, socketPath) for focus routing.
    private var surfaceWorkspaceMap: [String: (workspaceId: String, socketPath: String)] = [:]

    /// Cached TTY→surfaceId mapping. Persists across polls, builds up incrementally.
    private var ttyToSurfaceCache: [String: String] = [:]  // tty → surfaceId

    func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == cmuxBundleId }
    }

    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool {
        // Surface UUID from our enumeration — always claim
        if surfaceWorkspaceMap[tty] != nil { return true }

        // TTY-based: claim if focus has cmux workspace ID and no higher-priority terminal owns it
        guard let wsId = focus?.cmux_workspace_id, !wsId.isEmpty else { return false }
        let tp = focus?.term_program?.lowercased() ?? ""
        let ownFocus = tp == "vscode" || tp.contains("iterm")
        return !ownFocus
    }

    // MARK: - Enumeration (workspace.list + surface.list API)

    func enumerateSessions(hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow] {
        guard isAvailable(), appConfig.showAllTerminalWindows ?? false else { return [] }
        guard let socketPath = findSocketPath() else { return [] }

        // Ping pre-check — validate socket is responsive (~1ms)
        guard sendRequest(method: "system.ping", params: [:], socketPath: socketPath) != nil else {
            os_log("cmux socket not responding to ping", log: logger, type: .info)
            return []
        }

        guard let response = sendRequest(method: "workspace.list", params: [:], socketPath: socketPath),
              let result = response["result"] as? [String: Any],
              let workspaces = result["workspaces"] as? [[String: Any]] else {
            return []
        }

        // Build TTY→surfaceId mapping by reading CMUX_SURFACE_ID from child process env vars.
        // This is the authoritative source (~0.05ms total via sysctl KERN_PROCARGS2).
        let ttyToSurface = buildTTYSurfaceMap(psInfo: psInfo)

        // Invert: surfaceId → tty
        var ttyBySurfaceId: [String: String] = [:]
        for (tty, surfaceId) in ttyToSurface {
            ttyBySurfaceId[surfaceId] = tty
        }

        // Clear and rebuild surface→workspace map each scan
        var newSurfaceMap: [String: (workspaceId: String, socketPath: String)] = [:]
        var tabs: [TerminalTab] = []
        var tabIdx = 0

        for ws in workspaces {
            guard let wsId = ws["id"] as? String else { continue }
            let wsTitle = ws["title"] as? String ?? "Workspace"

            // Fetch surfaces for this workspace
            let surfaces = fetchSurfaces(workspaceId: wsId, socketPath: socketPath)

            if surfaces.isEmpty {
                // Fallback: no surfaces returned, show workspace as single tab
                tabs.append(TerminalTab(
                    tabIndex: tabIdx,
                    sessionId: wsId,
                    name: wsTitle,
                    tty: "",
                    windowId: -9000,
                    cwd: ws["current_directory"] as? String,
                    hasClaude: false,
                    claudeState: .inactive,
                    appName: "cmux",
                    alwaysShow: true,
                    terminalType: "cmux"
                ))
                tabIdx += 1
                continue
            }

            for surface in surfaces {
                guard let surfaceId = surface["id"] as? String else { continue }
                let surfaceTitle = surface["title"] as? String ?? wsTitle

                // Record surface→workspace mapping for focus routing
                newSurfaceMap[surfaceId] = (workspaceId: wsId, socketPath: socketPath)

                // Exact TTY lookup via sysctl-based mapping
                let tty = ttyBySurfaceId[surfaceId] ?? ""

                let (hasClaude, claudeState) = detectClaude(
                    tty: tty, hookStates: hookStates, psInfo: psInfo)

                let cwd = surface["current_directory"] as? String
                    ?? ws["current_directory"] as? String

                tabs.append(TerminalTab(
                    tabIndex: tabIdx,
                    sessionId: surfaceId,
                    name: surfaceTitle,
                    tty: tty,
                    windowId: -9000,
                    cwd: cwd,
                    hasClaude: hasClaude,
                    claudeState: claudeState,
                    appName: "cmux",
                    alwaysShow: true,
                    terminalType: "cmux"
                ))
                tabIdx += 1
            }
        }

        surfaceWorkspaceMap = newSurfaceMap

        guard !tabs.isEmpty else { return [] }

        return [TerminalWindow(
            windowId: -9000,
            windowName: "cmux",
            displayLabel: "",
            tabs: tabs,
            terminalType: "cmux"
        )]
    }

    // MARK: - TTY→Surface Mapping via sysctl

    /// Build TTY→surfaceId mapping by reading CMUX_SURFACE_ID from child process env vars.
    /// Uses sysctl KERN_PROCARGS2 to read env of non-shell child processes (gitstatusd, claude, etc.)
    /// since macOS restricts procargs for login shells. Results are cached across polls.
    private func buildTTYSurfaceMap(psInfo: PSScanResult) -> [String: String] {
        let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "csh", "tcsh", "dash", "ksh", "login"]

        // Group non-shell PIDs by TTY using pidToTTY from the existing ps scan
        var candidatesByTTY: [String: [Int32]] = [:]
        for (pid, comm) in psInfo.pidToComm {
            guard let tty = psInfo.pidToTTY[pid] else { continue }
            let name = (comm as NSString).lastPathComponent.lowercased()
            let stripped = name.hasPrefix("-") ? String(name.dropFirst()) : name
            if shellNames.contains(stripped) { continue }
            candidatesByTTY[tty, default: []].append(pid)
        }

        // For each TTY not already cached, try reading CMUX_SURFACE_ID from first readable process
        var result = ttyToSurfaceCache
        for (tty, pids) in candidatesByTTY {
            if result[tty] != nil { continue }
            for pid in pids {
                if let surfaceId = readCmuxSurfaceId(pid: pid) {
                    result[tty] = surfaceId
                    break
                }
            }
        }

        // Clean stale entries: remove TTYs whose shell is gone
        result = result.filter { tty, _ in psInfo.shellPIDs[tty] != nil }

        ttyToSurfaceCache = result
        return result
    }

    /// Read CMUX_SURFACE_ID from a process's environment via sysctl KERN_PROCARGS2.
    private func readCmuxSurfaceId(pid: Int32) -> String? {
        var size: Int = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        // Get buffer size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 100 else { return nil }

        // Read procargs
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        let data = Data(buf[0..<size])

        // Parse: argc (Int32) | exec_path\0 | padding\0s | argv[0]\0 ... argv[argc-1]\0 | env[0]\0 ...
        guard data.count >= 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }

        // Skip past exec path
        var pos = 4
        while pos < data.count && data[pos] != 0 { pos += 1 }
        // Skip null padding
        while pos < data.count && data[pos] == 0 { pos += 1 }
        // Skip argv strings
        var argSkipped = 0
        while pos < data.count && argSkipped < argc {
            while pos < data.count && data[pos] != 0 { pos += 1 }
            pos += 1
            argSkipped += 1
        }

        // Scan env vars for CMUX_SURFACE_ID=
        let target = "CMUX_SURFACE_ID=".utf8
        let targetBytes = Array(target)
        while pos < data.count {
            let start = pos
            while pos < data.count && data[pos] != 0 { pos += 1 }
            let envLen = pos - start
            pos += 1
            if envLen > targetBytes.count {
                let slice = Array(data[start..<(start + targetBytes.count)])
                if slice == targetBytes {
                    let valueStart = start + targetBytes.count
                    let valueEnd = start + envLen
                    if let value = String(bytes: data[valueStart..<valueEnd], encoding: .utf8), !value.isEmpty {
                        return value
                    }
                }
            }
            if envLen == 0 { break }
        }

        return nil
    }

    // MARK: - Surface Fetching

    /// Fetch surfaces for a workspace via surface.list API.
    private func fetchSurfaces(workspaceId: String, socketPath: String) -> [[String: Any]] {
        guard let response = sendRequest(
            method: "surface.list",
            params: ["workspace_id": workspaceId],
            socketPath: socketPath
        ),
        let result = response["result"] as? [String: Any],
        let surfaces = result["surfaces"] as? [[String: Any]] else {
            return []
        }
        return surfaces
    }

    // MARK: - Claude Detection

    /// Claude detection via hook state + process scan. No title heuristics needed —
    /// the Claude hook writes state keyed by TTY, and sysctl maps TTY→surface reliably.
    private func detectClaude(tty: String, hookStates: HookStates, psInfo: PSScanResult) -> (hasClaude: Bool, state: SessionState) {
        guard !tty.isEmpty else { return (false, .inactive) }
        let fromHook = hookStates.byTTY[tty] != nil
        let fromPS = psInfo.claudeTTYs.contains(tty)
        let hasClaude = fromHook || fromPS
        let state: SessionState = hasClaude
            ? (hookStates.byTTY[tty].map { SessionState.fromString($0) } ?? .idle)
            : .inactive
        return (hasClaude, state)
    }

    // MARK: - Focus (activate cmux + surface.focus or workspace.select)

    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool {
        // Case 1: Surface UUID from our enumeration
        if let mapping = surfaceWorkspaceMap[sessionId] {
            guard FileManager.default.fileExists(atPath: mapping.socketPath) else { return false }
            activateCmuxApp()
            return waitForFrontmost {
                // Select workspace first (required)
                let wsOk = self.sendRequest(method: "workspace.select",
                                            params: ["workspace_id": mapping.workspaceId],
                                            socketPath: mapping.socketPath) != nil
                // Try surface.focus as best-effort enhancement
                if wsOk {
                    self.sendRequest(method: "surface.focus",
                                     params: ["surface_id": sessionId],
                                     socketPath: mapping.socketPath)
                }
                return wsOk
            }
        }

        // Case 2: TTY path from generic scan → use workspace.select via focus data
        if sessionId.hasPrefix("/dev/") {
            guard let fWsId = focus?.cmux_workspace_id, !fWsId.isEmpty,
                  let fSockPath = focus?.cmux_socket_path, !fSockPath.isEmpty else { return false }
            guard FileManager.default.fileExists(atPath: fSockPath) else { return false }
            activateCmuxApp()
            return waitForFrontmost {
                self.sendRequest(method: "workspace.select",
                                 params: ["workspace_id": fWsId],
                                 socketPath: fSockPath) != nil
            }
        }

        // Case 3: Workspace UUID (legacy fallback) → use workspace.select
        guard let sockPath = findSocketPath() else { return false }
        guard FileManager.default.fileExists(atPath: sockPath) else { return false }
        activateCmuxApp()
        return waitForFrontmost {
            self.sendRequest(method: "workspace.select",
                             params: ["workspace_id": sessionId],
                             socketPath: sockPath) != nil
        }
    }

    /// Wait for cmux to become frontmost, then execute the focus action.
    private func waitForFrontmost(_ action: @escaping () -> Bool) -> Bool {
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<20 {
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.bundleIdentifier == cmuxBundleId { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            result = action()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3.0)
        return result
    }

    // MARK: - Socket Communication

    /// Find the cmux socket path (well-known locations).
    private func findSocketPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/Library/Application Support/cmux/cmux.sock",
            "/tmp/cmux.sock"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Send a JSON-RPC request to the cmux socket. Returns parsed response dict, or nil on failure.
    @discardableResult
    private func sendRequest(method: String, params: [String: Any], socketPath: String) -> [String: Any]? {
        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else { return nil }
        defer { close(sockFd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        socketPath.withCString { src in
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
        guard connected == 0 else { return nil }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else { return nil }

        let msg = line + "\n"
        _ = msg.withCString { send(sockFd, $0, strlen($0), 0) }

        // Read until newline or connection close (handles large surface.list responses)
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(sockFd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            accumulated.append(contentsOf: chunk[0..<n])
            // JSON-RPC responses are newline-delimited
            if chunk[0..<n].contains(UInt8(ascii: "\n")) { break }
            // Safety limit: 1MB
            if accumulated.count > 1_048_576 { break }
        }

        guard !accumulated.isEmpty else { return nil }

        // Trim to first newline (in case multiple messages arrived)
        let responseData: Data
        if let nlIndex = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
            responseData = accumulated[accumulated.startIndex..<nlIndex]
        } else {
            responseData = accumulated
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }

        if json["error"] != nil {
            let responseStr = String(data: responseData, encoding: .utf8) ?? "<undecodable>"
            os_log("cmux %{public}@ error: %{public}@", log: logger, type: .error, method, responseStr)
            return nil
        }
        return json
    }

    // MARK: - App Activation

    @discardableResult
    private func activateCmuxApp() -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == cmuxBundleId
        }) else { return false }
        if #available(macOS 14.0, *) {
            app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
        return true
    }
}
