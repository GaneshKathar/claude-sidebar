import AppKit
import Foundation

// MARK: - Config

struct RepoConfig: Codable {
    let num: Int
    let path: String

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

    // Resolve install dir from the app bundle's location
    // e.g. /Users/foo/rubrik/claude-sidebar/ClaudeSidebar.app -> /Users/foo/rubrik/claude-sidebar
    static let installDir: String = {
        let bundlePath = Bundle.main.bundlePath  // .../ClaudeSidebar.app
        return (bundlePath as NSString).deletingLastPathComponent
    }()
    static var configPath: String { installDir + "/config.json" }

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
        if let data = try? encoder.encode(self) {
            fm.createFile(atPath: AppConfig.configPath, contents: data)
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

struct HookStates {
    var byRepo: [Int: String] = [:]       // repo num -> highest priority state
    var byTTY: [String: String] = [:]     // tty path -> state (per-session)
    var byTTYRepo: [String: Int] = [:]    // tty path -> repo num (for session matching)
}

// MARK: - Session State (renamed from RepoState)

enum SessionState: Int, Comparable {
    case inactive = 0
    case idle = 1
    case working = 2
    case alert = 3
    static func < (lhs: SessionState, rhs: SessionState) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: NSColor {
        switch self {
        case .inactive: return NSColor(white: 1.0, alpha: 0.1)
        case .idle: return Theme.green
        case .working: return Theme.blue
        case .alert: return Theme.red
        }
    }

    static func fromString(_ s: String) -> SessionState {
        switch s {
        case "alert": return .alert
        case "working": return .working
        case "idle": return .idle
        default: return .inactive
        }
    }
}

// MARK: - Process Info

enum ProcessState {
    case running
    case success
    case error

    var color: NSColor {
        switch self {
        case .running: return Theme.yellow
        case .success: return Theme.green
        case .error: return Theme.red
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

// MARK: - Window-Centric Models

struct ITermTabInfo {
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

    // Overall tab state: Claude state takes priority, then process state
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
        return hasClaude ? .idle : .inactive
    }

    // Whether this tab has any interesting activity (Claude or process)
    var hasActivity: Bool {
        hasClaude || processInfo != nil
    }
}

struct ITermWindowInfo {
    var windowId: Int
    var windowName: String
    var displayLabel: String  // "1","2" for repo windows, "A","B" for others
    var tabs: [ITermTabInfo]

    // Highest state across tabs
    var state: SessionState {
        tabs.map { $0.state }.max() ?? .inactive
    }

    // Any Claude or process tab
    var hasActiveSession: Bool {
        tabs.contains { $0.hasActivity }
    }

    // Tabs with activity (for collapsed bar segments)
    var activeTabs: [ITermTabInfo] {
        tabs.filter { $0.hasActivity }
    }
}
