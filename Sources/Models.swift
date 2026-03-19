import AppKit
import Foundation
import os.log

private let configLogger = OSLog(subsystem: "com.claudesidebar", category: "AppConfig")

// MARK: - Config

struct RepoConfig: Codable {
    let num: Int
    let path: String
    var label: String?           // badge character (emoji or short text)
    var title: String?           // custom display name shown in expanded header

    var displayLabel: String {   // falls back to "\(num)"
        label ?? "\(num)"
    }

    var expandedPath: String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + path.dropFirst(1)
        }
        return path
    }
}

struct AppConfig: Codable {
    var repos: [RepoConfig]
    var pollInterval: Double? = 30.0
    var branchCacheTTL: Double?
    var staleTimeout: Double?
    var launchAtLogin: Bool?
    var fontScale: Double? = 1.0
    var minimalView: Bool? = false
    var autoStartClaude: Bool? = false
    var openCommand: String?
    var showAllTerminalWindows: Bool? = false
    var colorActive: String?
    var colorIdle: String?
    var colorWorking: String?
    var colorAlert: String?
    var colorRunning: String?

    // Memberwise init (needed because custom init(from:) suppresses synthesized one)
    init(repos: [RepoConfig], pollInterval: Double? = 30.0, branchCacheTTL: Double? = nil,
         staleTimeout: Double? = nil, launchAtLogin: Bool? = nil, fontScale: Double? = 1.0,
         minimalView: Bool? = false, autoStartClaude: Bool? = false, openCommand: String? = nil,
         showAllTerminalWindows: Bool? = false, colorActive: String? = nil, colorIdle: String? = nil,
         colorWorking: String? = nil, colorAlert: String? = nil, colorRunning: String? = nil) {
        self.repos = repos
        self.pollInterval = pollInterval
        self.branchCacheTTL = branchCacheTTL
        self.staleTimeout = staleTimeout
        self.launchAtLogin = launchAtLogin
        self.fontScale = fontScale
        self.minimalView = minimalView
        self.autoStartClaude = autoStartClaude
        self.openCommand = openCommand
        self.showAllTerminalWindows = showAllTerminalWindows
        self.colorActive = colorActive
        self.colorIdle = colorIdle
        self.colorWorking = colorWorking
        self.colorAlert = colorAlert
        self.colorRunning = colorRunning
    }

    // Backward compat: accept old "showAllITermWindows" key in JSON
    enum CodingKeys: String, CodingKey {
        case repos, pollInterval, branchCacheTTL, staleTimeout, launchAtLogin
        case fontScale, minimalView, autoStartClaude, openCommand
        case showAllTerminalWindows, colorActive, colorIdle, colorWorking, colorAlert, colorRunning
    }
    private enum LegacyKeys: String, CodingKey {
        case showAllITermWindows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decode([RepoConfig].self, forKey: .repos)
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval)
        branchCacheTTL = try c.decodeIfPresent(Double.self, forKey: .branchCacheTTL)
        staleTimeout = try c.decodeIfPresent(Double.self, forKey: .staleTimeout)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale)
        minimalView = try c.decodeIfPresent(Bool.self, forKey: .minimalView)
        autoStartClaude = try c.decodeIfPresent(Bool.self, forKey: .autoStartClaude)
        openCommand = try c.decodeIfPresent(String.self, forKey: .openCommand)
        colorActive = try c.decodeIfPresent(String.self, forKey: .colorActive)
        colorIdle = try c.decodeIfPresent(String.self, forKey: .colorIdle)
        colorWorking = try c.decodeIfPresent(String.self, forKey: .colorWorking)
        colorAlert = try c.decodeIfPresent(String.self, forKey: .colorAlert)
        colorRunning = try c.decodeIfPresent(String.self, forKey: .colorRunning)
        // New key takes priority; fall back to legacy key
        showAllTerminalWindows = try c.decodeIfPresent(Bool.self, forKey: .showAllTerminalWindows)
        if showAllTerminalWindows == nil {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            showAllTerminalWindows = try legacy.decodeIfPresent(Bool.self, forKey: .showAllITermWindows)
        }
    }

    // Resolve install dir from the app bundle's location
    // e.g. /Users/foo/rubrik/claude-sidebar/ClaudeSidebar.app -> /Users/foo/rubrik/claude-sidebar
    static let installDir: String = {
        let bundlePath = Bundle.main.bundlePath  // .../ClaudeSidebar.app
        return (bundlePath as NSString).deletingLastPathComponent
    }()
    static var configPath: String { installDir + "/config.json" }

    static func configFileExists() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    static func load() -> AppConfig {
        let paths = [configPath]

        for path in paths {
            if let data = FileManager.default.contents(atPath: path),
               let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return config
            }
        }

        return AppConfig(
            repos: (1...4).map { RepoConfig(num: $0, path: "~/rubrik/sdmain-\($0)") },
            pollInterval: 30.0,
            branchCacheTTL: 10.0,
            staleTimeout: 1800,
            launchAtLogin: false
        )
    }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: AppConfig.installDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: AppConfig.configPath), options: .atomic)
        } catch {
            os_log("Failed to save config: %{public}@", log: configLogger, type: .error, error.localizedDescription)
        }
    }

    // BFS from home directory, max depth 5, find sdmain* dirs with .git
    static func detectRepos() -> [RepoConfig] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let skipDirs: Set<String> = [
            "Library", "Applications", "node_modules", ".cache", ".Trash",
            "Pictures", "Music", "Movies"
        ]

        var found: [String] = []

        // BFS: (path, depth)
        var queue: [(String, Int)] = [(home, 0)]
        var head = 0

        while head < queue.count {
            let (dir, depth) = queue[head]
            head += 1
            guard depth < 5 else { continue }

            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                // Skip hidden dirs and known-uninteresting dirs
                if entry.hasPrefix(".") { continue }
                if depth == 0 && skipDirs.contains(entry) { continue }

                let fullPath = dir + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

                if entry.hasPrefix("sdmain") {
                    // Check for .git inside
                    if fm.fileExists(atPath: fullPath + "/.git") {
                        found.append(fullPath)
                    }
                    // Don't descend into matched sdmain dirs
                    continue
                }

                queue.append((fullPath, depth + 1))
            }
        }

        // Sort lexicographically, assign serial numbers
        found.sort()
        return found.enumerated().map { idx, path in
            let displayPath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            return RepoConfig(num: idx + 1, path: displayPath)
        }
    }
}

var appConfig = AppConfig.load()

// MARK: - Hook State

struct HookState: Codable {
    let repo: Int
    let state: String
    let session_id: String
    let cwd: String
    let tty: String?
    let timestamp: Double
}

// Written by sidebar-state.sh at SessionStart — terminal identity for window focusing.
// Persists after claude exits so the sidebar can always focus the right window.
struct TerminalFocus: Codable {
    let tty: String
    let term_program: String?       // TERM_PROGRAM: "iTerm.app", "vscode", "ghostty", etc.
    let iterm_session_id: String?   // iTerm2 session UUID (extracted from ITERM_SESSION_ID)
    let cmux_workspace_id: String?  // CMUX_WORKSPACE_ID
    let cmux_socket_path: String?   // CMUX_SOCKET_PATH
    let cmux_surface_id: String?    // CMUX_SURFACE_ID
    let kitty_window_id: String?    // KITTY_WINDOW_ID
    let kitty_listen_on: String?    // KITTY_LISTEN_ON
    let timestamp: Double
    let extra: [String: String]?    // Additional terminal-specific env vars

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tty = try c.decode(String.self, forKey: .tty)
        term_program = try c.decodeIfPresent(String.self, forKey: .term_program)
        iterm_session_id = try c.decodeIfPresent(String.self, forKey: .iterm_session_id)
        cmux_workspace_id = try c.decodeIfPresent(String.self, forKey: .cmux_workspace_id)
        cmux_socket_path = try c.decodeIfPresent(String.self, forKey: .cmux_socket_path)
        cmux_surface_id = try c.decodeIfPresent(String.self, forKey: .cmux_surface_id)
        kitty_window_id = try c.decodeIfPresent(String.self, forKey: .kitty_window_id)
        kitty_listen_on = try c.decodeIfPresent(String.self, forKey: .kitty_listen_on)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra)
    }
}

struct HookStates {
    var byRepo: [Int: String] = [:]            // repo num -> highest priority state
    var byTTY: [String: String] = [:]          // tty path -> state (most recent session)
    var byTTYRepo: [String: Int] = [:]         // tty path -> repo num (for session matching)
    var byTTYTimestamp: [String: Double] = [:] // tty path -> timestamp (for recency tracking)
}

// MARK: - Session State (renamed from RepoState)

enum SessionState: Int, Comparable {
    case inactive = 0
    case active = 1      // Claude session started, not yet processing
    case idle = 2        // Claude done, waiting for input
    case working = 3     // Claude processing / tool use
    case alert = 4       // Needs permission / error
    static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: NSColor {
        switch self {
        case .inactive: return NSColor(white: 1.0, alpha: 0.1)
        case .active: return Theme.active
        case .idle: return Theme.idle
        case .working: return Theme.working
        case .alert: return Theme.alert
        }
    }

    static func fromString(_ s: String) -> SessionState {
        switch s {
        case "alert": return .alert
        case "working": return .working
        case "active": return .active
        case "idle": return .idle
        default: return .inactive
        }
    }
}

// MARK: - SessionState Color Extensions

extension SessionState {
    var accentColor: NSColor {
        switch self {
        case .working: return Theme.working
        case .alert:   return Theme.alert
        case .active:  return Theme.active
        case .idle:    return Theme.idle
        case .inactive: return NSColor(hexString: "#7B8FA1")!
        }
    }

    var badgeBackground: NSColor {
        switch self {
        case .working: return Theme.working.withAlphaComponent(0.16)
        case .alert:   return Theme.alert.withAlphaComponent(0.16)
        case .active:  return Theme.active.withAlphaComponent(0.12)
        case .idle:    return Theme.idle.withAlphaComponent(0.14)
        case .inactive: return NSColor(white: 1.0, alpha: 0.04)
        }
    }

    var badgeTextColor: NSColor {
        switch self {
        case .working: return Theme.working
        case .alert:   return Theme.alert
        case .active:  return Theme.active
        case .idle:    return Theme.idle
        case .inactive: return NSColor(white: 1.0, alpha: 0.45)
        }
    }
}

extension TerminalTab {
    /// Color for collapsed/minimal bar segments
    var segmentColor: NSColor {
        if hasClaude {
            switch claudeState {
            case .working: return Theme.working
            case .alert:   return Theme.alert
            case .active:  return Theme.active
            case .idle, .inactive: return Theme.idle
            }
        }
        if let proc = processInfo {
            switch proc.state {
            case .running: return Theme.running
            case .success: return Theme.idle
            case .error:   return Theme.alert
            }
        }
        return Theme.active
    }
}

// MARK: - Process Info

enum ProcessState {
    case running
    case success
    case error

    var color: NSColor {
        switch self {
        case .running: return Theme.running
        case .success: return Theme.idle
        case .error: return Theme.alert
        }
    }
}

struct ProcessInfo {
    var name: String       // "make build"
    var pid: Int
    var startTime: Date
    var exitCode: Int?     // nil = running

    var state: ProcessState {
        if let code = exitCode {
            return code == 0 ? .success : .error
        }
        return .running
    }

    var duration: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    var durationString: String {
        let secs = Int(duration)
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let remainSecs = secs % 60
        if mins < 60 { return "\(mins)m \(remainSecs)s" }
        let hrs = mins / 60
        let remainMins = mins % 60
        return "\(hrs)h \(remainMins)m"
    }
}

// MARK: - Process Scan Result (top-level for protocol compatibility)

struct ProcessScanResult {
    var processes: [String: ProcessInfo] = [:]  // tty -> non-shell/non-claude process
    var claudeTTYs: Set<String> = []            // TTYs running claude
    var claudePIDs: [String: Int32] = [:]       // tty -> claude PID (for kqueue watching)
    var shellPIDs: [String: Int32] = [:]        // tty -> shell PID (for CWD detection)
}
typealias ProcessMonitorScanResult = ProcessScanResult

// MARK: - Window-Centric Models

struct TerminalTab {
    var tabIndex: Int
    var sessionId: String
    var name: String
    var tty: String
    var windowId: Int
    var cwd: String?
    var gitBranch: String?
    var hasClaude: Bool
    var claudeState: SessionState
    var processInfo: ProcessInfo?
    var appName: String?   // terminal app display name, set at scan time
    var alwaysShow: Bool = false  // true when showAllTerminalWindows is on
    var terminalType: String? = nil  // "iterm2", "ghostty", "kitty", etc.

    // Overall tab state: Claude state takes priority, then process state.
    // .inactive is repo-level only (placeholder) — tabs are always at least .active.
    var state: SessionState {
        if hasClaude && claudeState != .inactive {
            return claudeState
        }
        if let proc = processInfo {
            switch proc.state {
            case .running: return .working
            case .error: return .alert
            case .success: return .idle
            }
        }
        if hasClaude { return .active }
        return .active  // non-Claude idle → slate, distinct from Claude idle (teal)
    }

    // Whether this tab has any interesting activity (Claude or process)
    var hasActivity: Bool {
        hasClaude || processInfo != nil || alwaysShow
    }
}
typealias ITermTabInfo = TerminalTab

struct TerminalWindow {
    var windowId: Int
    var windowName: String
    var displayLabel: String  // "1","2" for repo windows, "5","6" for others
    var displayPath: String? = nil  // short path shown below name in expanded box
    var tabs: [TerminalTab]
    var matchedRepoNum: Int?     // set during scan, nil for non-repo windows
    var isPlaceholder: Bool = false  // true for repos with no active window
    var terminalType: String? = nil  // "iterm2", "ghostty", "kitty", etc.

    // Highest state across tabs
    var state: SessionState {
        tabs.map { $0.state }.max() ?? .inactive
    }

    // Any Claude or process tab
    var hasActiveSession: Bool {
        tabs.contains { $0.hasActivity }
    }

    // Tabs with activity (for collapsed bar segments)
    var activeTabs: [TerminalTab] {
        tabs.filter { $0.hasActivity }
    }

    // Create a placeholder for a configured repo with no active terminal window
    static func placeholder(for repo: RepoConfig) -> TerminalWindow {
        TerminalWindow(
            windowId: -repo.num,   // negative to avoid collision with real windows
            windowName: repo.title ?? (repo.expandedPath as NSString).lastPathComponent,
            displayLabel: repo.displayLabel,
            displayPath: nil,
            tabs: [],
            matchedRepoNum: repo.num,
            isPlaceholder: true
        )
    }
}
typealias ITermWindowInfo = TerminalWindow
