import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "TerminalScanner")


// MARK: - Terminal Scanner (100% terminal-agnostic orchestrator)

class TerminalScanner: TerminalScanning {
    private let stateReader: StateReading = StateReader()
    private let registry = TerminalRegistry.shared
    let cwdResolver = CWDResolver()
    let branchResolver = BranchResolver()
    private var scanInFlight = false
    private var labelCache: [Int: String] = [:]
    private var nextNonRepoNum = 0

    // Generic terminal support: stable IDs for non-enumerated windows
    private var genericWindowIds: [String: Int] = [:]
    var genericWindowApps: [Int: String] = [:]
    var genericWindowPIDs: [Int: Int32] = [:]
    private var genericWindowIdCounter = -10000

    // Terminal focus data written by the hook at SessionStart (one file per TTY)
    private var terminalFocusByTTY: [String: TerminalFocus] = [:]

    // Session ID → tab cache for focus routing (rebuilt each scan)
    private var sessionIdToTab: [String: TerminalTab] = [:]

    func readHookStates() -> HookStates {
        return stateReader.readStates()
    }

    // MARK: - Scan (orchestrates adapters)

    func scan() -> [TerminalWindow] {
        guard !scanInFlight else { return [] }
        scanInFlight = true
        defer { scanInFlight = false }

        let hookStates = stateReader.readStates()
        terminalFocusByTTY = stateReader.readFocusFiles()
        let psInfo = registry.detector.scanProcesses()

        // Step 1: Call enumerateSessions() on all adapters with nativeEnumeration
        var adapterWindows: [TerminalWindow] = []
        var claimedTTYs = Set<String>()
        for adapter in registry.enumeratingAdapters() {
            let wins = adapter.enumerateSessions(hookStates: hookStates, psInfo: psInfo)
            for win in wins {
                for tab in win.tabs where !tab.tty.isEmpty {
                    claimedTTYs.insert(tab.tty)
                }
            }
            adapterWindows.append(contentsOf: wins)
        }

        // Step 2: For remaining TTYs (hook+ps discovered), create generic windows
        let genericWindows = scanUnenumeratedSessions(excludeTTYs: claimedTTYs, hookStates: hookStates, psInfo: psInfo)

        // Step 3: Resolve CWD and branch for all tabs
        var windows = adapterWindows + genericWindows
        let cacheTTL = appConfig.branchCacheTTL ?? 10.0
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                if windows[wi].tabs[ti].cwd == nil {
                    if let cwd = cwdResolver.resolveCWD(tty: windows[wi].tabs[ti].tty) {
                        windows[wi].tabs[ti].cwd = cwd
                    }
                }
                if let cwd = windows[wi].tabs[ti].cwd {
                    if let branch = branchResolver.resolveBranch(cwd: cwd, cacheTTL: cacheTTL) {
                        windows[wi].tabs[ti].gitBranch = branch
                    }
                }
            }
        }

        cwdResolver.trimCache()
        branchResolver.trimCache()

        // Build sessionId→tab cache for focus routing
        var tabCache: [String: TerminalTab] = [:]
        for win in windows {
            for tab in win.tabs {
                tabCache[tab.sessionId] = tab
            }
        }
        sessionIdToTab = tabCache

        return windows
    }

    // MARK: - Unenumerated Session Discovery (terminal-agnostic)

    /// Find Claude sessions on TTYs not claimed by any adapter's nativeEnumeration.
    /// Groups them by terminal app identity into virtual windows.
    private func scanUnenumeratedSessions(excludeTTYs: Set<String>, hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow] {
        var candidateTTYs = psInfo.claudeTTYs.subtracting(excludeTTYs)

        // Hook-state TTYs: only include if terminal is still alive
        for tty in hookStates.byTTY.keys where !excludeTTYs.contains(tty) {
            if psInfo.shellPIDs[tty] != nil || psInfo.claudeTTYs.contains(tty) {
                candidateTTYs.insert(tty)
            }
        }

        // Filter out TTYs claimed by enumerating adapters even if not assigned to a specific tab
        // (e.g., cmux split panes without focus files yet). Prevents duplicates.
        let enumerating = registry.enumeratingAdapters()
        if !enumerating.isEmpty {
            candidateTTYs = candidateTTYs.filter { tty in
                let focus = self.terminalFocusByTTY[tty]
                let ancestry = registry.detector.processAncestry(for: tty, psInfo: psInfo)
                return !enumerating.contains { $0.claimsSession(tty: tty, focus: focus, processAncestry: ancestry) }
            }
        }

        guard !candidateTTYs.isEmpty else { return [] }

        // Group TTYs by terminal app
        var groups: [String: (ttys: [String], pid: Int32?)] = [:]
        for tty in candidateTTYs {
            let (name, pid) = registry.detector.detectTerminalApp(for: tty, psInfo: psInfo, focusByTTY: terminalFocusByTTY)
            if groups[name] == nil {
                groups[name] = (ttys: [], pid: pid)
            }
            groups[name]!.ttys.append(tty)
        }

        // Create one virtual window per terminal app
        var windows: [TerminalWindow] = []
        for (appName, group) in groups.sorted(by: { $0.key < $1.key }) {
            let ttys = group.ttys
            if genericWindowIds[appName] == nil {
                genericWindowIds[appName] = genericWindowIdCounter
                genericWindowApps[genericWindowIdCounter] = appName
                genericWindowIdCounter -= 1
            }
            let windowId = genericWindowIds[appName]!
            if let pid = group.pid {
                genericWindowPIDs[windowId] = pid
            }

            let tabs: [TerminalTab] = ttys.sorted().enumerated().map { idx, tty in
                let claudeRunning = psInfo.claudeTTYs.contains(tty)
                let state = claudeRunning
                    ? (hookStates.byTTY[tty].map { SessionState.fromString($0) } ?? .idle)
                    : .idle
                let cwd = cwdResolver.readCWDFromHookState(tty: tty)
                return TerminalTab(
                    tabIndex: idx,
                    sessionId: tty,
                    name: (tty as NSString).lastPathComponent,
                    tty: tty,
                    windowId: windowId,
                    cwd: cwd,
                    hasClaude: claudeRunning,
                    claudeState: state,
                    appName: appName
                )
            }

            var matchedRepoNum: Int? = nil
            for tab in tabs {
                if let cwd = tab.cwd,
                   let repo = appConfig.repos.first(where: { r in
                       cwd == r.expandedPath || cwd.hasPrefix(r.expandedPath + "/")
                   }) {
                    matchedRepoNum = repo.num
                    break
                }
            }

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

            windows.append(TerminalWindow(
                windowId: windowId,
                windowName: appName,
                displayLabel: displayLabel,
                tabs: tabs,
                matchedRepoNum: matchedRepoNum
            ))
        }
        return windows
    }

    // MARK: - Focus (routed through adapters)

    func focusSession(windowId: Int, sessionId: String) {
        let freshFocus = stateReader.readFocusFiles()
        let psInfo = registry.detector.scanProcesses()

        // Try direct TTY lookup first (sessionId might be a TTY path)
        var focus = freshFocus[sessionId] ?? terminalFocusByTTY[sessionId]
        var lookupKey = sessionId

        // If sessionId is not a TTY (e.g., iTerm2 UUID or cmux surface UUID),
        // find the tab's actual TTY from stored windows for adapter routing
        if focus == nil, !sessionId.hasPrefix("/dev/") {
            if let tab = findTab(sessionId: sessionId) {
                if !tab.tty.isEmpty {
                    focus = freshFocus[tab.tty] ?? terminalFocusByTTY[tab.tty]
                    lookupKey = tab.tty
                }
            }
        }

        // Route through adapter that claims this session
        if let adapter = registry.adapterForTTY(lookupKey, focus: focus, psInfo: psInfo) {
            if adapter.focusSession(windowId: windowId, sessionId: sessionId, focus: focus) {
                return
            }
        }

        // Fallback: find adapter by terminalType from stored tab data
        if let tab = findTab(sessionId: sessionId),
           let termType = tab.terminalType,
           let adapter = registry.adapters.first(where: { $0.info.identifier == termType }) {
            if adapter.focusSession(windowId: windowId, sessionId: sessionId, focus: focus) {
                return
            }
        }

        // Last resort: activate the terminal app by PID or name
        if let appName = genericWindowApps[windowId] {
            activateApp(name: appName, windowId: windowId)
        }
    }

    /// Find a tab by sessionId from the last scan cache.
    private func findTab(sessionId: String) -> TerminalTab? {
        return sessionIdToTab[sessionId]
    }

    // MARK: - Creation (routed to first capable adapter)

    func openWindowWithCWD(path: String, command: String? = nil) {
        if let adapter = registry.adapters.first(where: { $0.capabilities.contains(.nativeOpenWithCWD) && $0.isAvailable() }) {
            _ = adapter.openWithCWD(path: path, command: command)
        }
    }

    func createTab(windowId: Int) {
        if let adapter = registry.adapters.first(where: { $0.capabilities.contains(.nativeCreateTab) && $0.isAvailable() }) {
            _ = adapter.createTab(windowId: windowId)
        }
    }

    func createWindow() {
        if let adapter = registry.adapters.first(where: { $0.capabilities.contains(.nativeCreateWindow) && $0.isAvailable() }) {
            _ = adapter.createWindow()
        }
    }

    // MARK: - Shared Helpers (terminal-agnostic)

    func getBranch(cwd: String) -> String? {
        branchResolver.getBranch(cwd: cwd)
    }

    /// Activate a terminal app by PID cache or NSWorkspace name lookup.
    private func activateApp(name: String, windowId: Int) {
        let app: NSRunningApplication?
        if let pid = genericWindowPIDs[windowId] {
            app = NSRunningApplication(processIdentifier: pid)
        } else {
            let keyword = TerminalDetector.terminalAppMappings
                .first { $0.displayName == name }?.keyword ?? name.lowercased()
            app = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased().contains(keyword) ?? false
            }
        }
        if let app = app {
            if #available(macOS 14.0, *) {
                app.activate(from: NSRunningApplication.current, options: [])
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
    }
}
typealias ITermScanner = TerminalScanner
