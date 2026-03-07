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
    // e.g. /Users/foo/rubrik/claude-sidebar/ClaudeSidebar.app → /Users/foo/rubrik/claude-sidebar
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

// MARK: - Data Models

struct HookState: Codable {
    let repo: Int
    let state: String
    let session_id: String
    let cwd: String
    let tty: String?
    let timestamp: Double
}

enum RepoState: Int, Comparable {
    case inactive = 0
    case idle = 1
    case working = 2
    case alert = 3
    static func < (lhs: RepoState, rhs: RepoState) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: NSColor {
        switch self {
        case .inactive: return NSColor(white: 1.0, alpha: 0.1)
        case .idle: return Theme.green
        case .working: return Theme.blue
        case .alert: return Theme.red
        }
    }
}

struct SessionInfo {
    let windowId: Int
    let tabIndex: Int
    let sessionId: String
    let name: String
    let tty: String
    let hasClaude: Bool
    let repoNum: Int?
    var state: RepoState  // per-session state
}

struct RepoInfo {
    var sessions: [SessionInfo] = []
    var branch: String?

    // Derived: highest priority state across all sessions
    var state: RepoState {
        sessions.map { $0.state }.max() ?? .inactive
    }
}

// MARK: - State Reader (hooks-based)

struct HookStates {
    var byRepo: [Int: String] = [:]       // repo num → highest priority state
    var byTTY: [String: String] = [:]     // tty path → state (per-session)
    var byTTYRepo: [String: Int] = [:]    // tty path → repo num (for session matching)
}

class StateReader {
    private let stateDir = "/tmp/claude-sidebar"

    func readStates() -> HookStates {
        var result = HookStates()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return result }

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let hookState = try? JSONDecoder().decode(HookState.self, from: data) else { continue }
            if Date().timeIntervalSince1970 - hookState.timestamp > (appConfig.staleTimeout ?? 1800) {
                try? fm.removeItem(atPath: path)
                continue
            }
            let repo = hookState.repo
            let state = hookState.state

            // Per-TTY state and repo mapping for individual session matching
            if let tty = hookState.tty, !tty.isEmpty {
                result.byTTY[tty] = state
                result.byTTYRepo[tty] = repo
            }

            // Per-repo: keep highest priority
            if let existing = result.byRepo[repo] {
                if existing == "alert" { continue }
                if existing == "working" && state != "alert" { continue }
            }
            result.byRepo[repo] = state
        }
        return result
    }
}

// MARK: - iTerm2 Scanner

class ITermScanner {
    private let stateReader = StateReader()
    private var branchCache: [Int: (String, Date)] = [:]
    private var ttyRepoCache: [String: Int?] = [:]

    func readHookStates() -> HookStates {
        return stateReader.readStates()
    }

    func scan() -> [Int: RepoInfo] {
        var repos: [Int: RepoInfo] = [:]
        for repo in appConfig.repos {
            repos[repo.num] = RepoInfo()
        }

        let hookStates = stateReader.readStates()
        let sessions = queryITerm(hookStates: hookStates)
        for session in sessions {
            guard let num = session.repoNum else { continue }
            repos[num]?.sessions.append(session)
        }

        // Cached branch lookup
        let cacheTTL = appConfig.branchCacheTTL ?? 10.0
        for repo in appConfig.repos {
            let i = repo.num
            if let cached = branchCache[i], Date().timeIntervalSince(cached.1) < cacheTTL {
                repos[i]?.branch = cached.0
            } else {
                let b = getBranch(repoPath: repo.expandedPath)
                repos[i]?.branch = b
                if let b = b { branchCache[i] = (b, Date()) }
            }
        }

        return repos
    }

    private func queryITerm(hookStates: HookStates) -> [SessionInfo] {
        let script = """
        tell application "System Events"
            if not (exists process "iTerm2") then return ""
        end tell
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                set wID to id of w
                set tIndex to 0
                repeat with t in tabs of w
                    set tIndex to tIndex + 1
                    repeat with s in sessions of t
                        set sName to name of s
                        set sTTY to tty of s
                        set sID to unique ID of s
                        set output to output & wID & "\\t" & tIndex & "\\t" & sID & "\\t" & sName & "\\t" & sTTY & "\\n"
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = result.stringValue else { return [] }

        var sessions: [SessionInfo] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            let name = parts[3]
            let tty = parts[4]

            // Detect Claude: check session title OR hook state for this TTY
            let hasClaude = name.lowercased().contains("claude") || hookStates.byTTY[tty] != nil

            // Detect repo: check title for folder name, then hook state TTY mapping, then lsof fallback
            let repoNum = detectRepoNum(name: name, tty: tty, hookStates: hookStates)

            sessions.append(SessionInfo(
                windowId: Int(parts[0]) ?? 0, tabIndex: Int(parts[1]) ?? 0,
                sessionId: parts[2], name: name, tty: tty,
                hasClaude: hasClaude, repoNum: repoNum, state: .inactive
            ))
        }
        return sessions
    }

    private func detectRepoNum(name: String, tty: String, hookStates: HookStates) -> Int? {
        // 1. Check session title for repo folder name
        for repo in appConfig.repos {
            let folderName = URL(fileURLWithPath: repo.expandedPath).lastPathComponent
            if name.contains(folderName) { return repo.num }
        }
        // 2. Check hook state TTY → repo mapping (fast, from /tmp/claude-sidebar/)
        if let hookRepo = hookStates.byTTYRepo[tty] { return hookRepo }
        // 3. Fallback: lsof to check cwd of processes on the TTY
        if let cached = ttyRepoCache[tty] { return cached }
        let result = lsofDetectRepo(tty: tty)
        ttyRepoCache[tty] = result
        return result
    }

    private func lsofDetectRepo(tty: String) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "lsof -t \(tty) 2>/dev/null | head -5 | xargs -I{} lsof -p {} -Fn 2>/dev/null | head -20"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for repo in appConfig.repos {
                let folderName = URL(fileURLWithPath: repo.expandedPath).lastPathComponent
                if output.contains(folderName) { return repo.num }
            }
        }
        return nil
    }

    private func getBranch(repoPath: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "branch", "--show-current"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func focusSession(_ session: SessionInfo) {
        // Select exact session by unique ID (handles split panes correctly)
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                if id of w is \(session.windowId) then
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique ID of s is "\(session.sessionId)" then
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
        }
    }

    func openNewSession(repoNum: Int) {
        let repoPath = appConfig.repos.first { $0.num == repoNum }?.expandedPath
            ?? "\(NSHomeDirectory())/rubrik/sdmain-\(repoNum)"
        let script = """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "cd \(repoPath)/polaris && source .buildenv/bin/activate && cd \(repoPath) && claude"
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - Theme

struct Theme {
    static let bg = NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 0.92)
    static let bgSolid = NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 0.98)
    static let border = NSColor(white: 1.0, alpha: 0.08)
    static let textDim = NSColor(white: 1.0, alpha: 0.25)
    static let textMid = NSColor(white: 1.0, alpha: 0.5)
    static let textBright = NSColor(white: 1.0, alpha: 0.9)
    static let green = NSColor(red: 80/255, green: 250/255, blue: 123/255, alpha: 1.0)
    static let red = NSColor(red: 255/255, green: 85/255, blue: 85/255, alpha: 1.0)
    static let blue = NSColor(red: 139/255, green: 233/255, blue: 253/255, alpha: 1.0)
    static let hover = NSColor(white: 1.0, alpha: 0.08)
    static let selected = NSColor(white: 1.0, alpha: 0.12)
}

// MARK: - Repo Button

class RepoButton: NSView {
    let repoNum: Int
    var state: RepoState = .inactive { didSet { updateAppearance() } }
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let accentBar = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(num: Int) {
        self.repoNum = num
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        label.stringValue = "\(repoNum)"
        label.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        label.textColor = Theme.textDim
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 1.5

        label.translatesAutoresizingMaskIntoConstraints = false
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            label.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        layer?.removeAnimation(forKey: "alertPulse")

        switch state {
        case .inactive:
            label.textColor = Theme.textDim
            accentBar.layer?.backgroundColor = NSColor.clear.cgColor
        case .idle:
            label.textColor = Theme.textBright
            accentBar.layer?.backgroundColor = Theme.green.cgColor
        case .working:
            label.textColor = Theme.blue
            accentBar.layer?.backgroundColor = Theme.blue.cgColor
        case .alert:
            label.textColor = Theme.red
            accentBar.layer?.backgroundColor = Theme.red.cgColor
            wantsLayer = true
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = NSColor(red: 1, green: 0.33, blue: 0.33, alpha: 0.12).cgColor
            anim.toValue = NSColor(red: 1, green: 0.33, blue: 0.33, alpha: 0.03).cgColor
            anim.duration = 1.0
            anim.autoreverses = true
            anim.repeatCount = .infinity
            layer?.add(anim, forKey: "alertPulse")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.selected.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        } else if isHovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }

    override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?(repoNum) }
}

// MARK: - Sub Panel Item

class SubPanelItem: NSView {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(session: SessionInfo) {
        super.init(frame: .zero)
        wantsLayer = true

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = session.state.color.cgColor

        let nameText = session.hasClaude ? "Claude" : "shell"
        let statusLabel = NSTextField(labelWithString: nameText)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = session.hasClaude ? Theme.textBright : Theme.textDim
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false

        let iconText: String
        if session.hasClaude {
            switch session.state {
            case .working: iconText = "\u{26A1}"
            case .alert: iconText = "\u{23F3}"
            case .idle: iconText = "\u{2714}"
            case .inactive: iconText = ""
            }
        } else {
            iconText = ""
        }

        let iconLabel = NSTextField(labelWithString: iconText)
        iconLabel.font = .systemFont(ofSize: 11)
        iconLabel.textColor = session.state.color
        iconLabel.isBezeled = false
        iconLabel.drawsBackground = false
        iconLabel.isEditable = false
        iconLabel.isSelectable = false

        for v in [dot, statusLabel, iconLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.hover.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Sub Panel

class SubPanel: NSView {
    private let headerLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(wrappingLabelWithString: "")
    private let plusButton = NSTextField(labelWithString: "+")
    private let itemsContainer = NSStackView()
    let scanner: ITermScanner
    private var trackingArea: NSTrackingArea?
    private var currentRepoNum: Int = 0

    init(scanner: ITermScanner) {
        self.scanner = scanner
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.backgroundColor = Theme.bgSolid.cgColor
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = Theme.textBright
        headerLabel.isBezeled = false
        headerLabel.drawsBackground = false
        headerLabel.isEditable = false

        branchLabel.font = .systemFont(ofSize: 10)
        branchLabel.textColor = Theme.textMid
        branchLabel.maximumNumberOfLines = 1
        branchLabel.lineBreakMode = .byTruncatingMiddle

        plusButton.font = .systemFont(ofSize: 14, weight: .medium)
        plusButton.textColor = NSColor(white: 1.0, alpha: 0.6)
        plusButton.isBezeled = false
        plusButton.drawsBackground = false
        plusButton.isEditable = false
        plusButton.isSelectable = false

        itemsContainer.orientation = .vertical
        itemsContainer.spacing = 0
        itemsContainer.alignment = .leading

        // Header group: name + branch stacked
        let headerGroup = NSStackView()
        headerGroup.orientation = .vertical
        headerGroup.spacing = 2
        headerGroup.alignment = .leading
        headerGroup.addArrangedSubview(headerLabel)
        headerGroup.addArrangedSubview(branchLabel)

        // Top row: headerGroup left, + button right
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.distribution = .fill
        topRow.spacing = 8
        topRow.addArrangedSubview(headerGroup)
        topRow.addArrangedSubview(plusButton)

        // Make headerGroup expand, plusButton stays fixed
        headerGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        plusButton.setContentHuggingPriority(.required, for: .horizontal)
        plusButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let sep = NSBox()
        sep.boxType = .separator

        for v in [topRow, sep, itemsContainer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 240),

            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            sep.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),

            itemsContainer.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            itemsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            itemsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            itemsContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

        isHidden = true
    }

    func show(repoNum: Int, info: RepoInfo) {
        currentRepoNum = repoNum
        headerLabel.stringValue = "sdmain-\(repoNum)"

        if let branch = info.branch, !branch.isEmpty {
            branchLabel.stringValue = "\u{2387} \(branch)"
        } else {
            branchLabel.stringValue = ""
        }

        itemsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Sort: Claude sessions first, sorted by state priority (alert > working > idle)
        let sorted = info.sessions.sorted { a, b in
            if a.hasClaude != b.hasClaude { return a.hasClaude }
            return a.state > b.state
        }

        if sorted.isEmpty {
            let empty = NSTextField(labelWithString: "  No active sessions")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = Theme.textDim
            empty.isBezeled = false
            empty.drawsBackground = false
            empty.isEditable = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                empty.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
                empty.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
                wrapper.widthAnchor.constraint(equalToConstant: 240),
            ])
            itemsContainer.addArrangedSubview(wrapper)
        } else {
            for session in sorted {
                let item = SubPanelItem(session: session)
                item.translatesAutoresizingMaskIntoConstraints = false
                item.widthAnchor.constraint(equalToConstant: 240).isActive = true
                item.onClick = { [weak self] in self?.scanner.focusSession(session) }
                itemsContainer.addArrangedSubview(item)
            }
        }

        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Convert plusButton frame from its superview's coordinate space to SubPanel's
        let plusFrameInSelf = plusButton.superview?.convert(plusButton.frame, to: self) ?? plusButton.frame
        if plusFrameInSelf.insetBy(dx: -8, dy: -8).contains(loc) {
            scanner.openNewSession(repoNum: currentRepoNum)
        }
    }
}

// MARK: - Status Bar Manager

class StatusBarManager {
    private var statusItem: NSStatusItem?
    var onOpenSettings: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let img = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Claude Sidebar") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "CS"
            }
            button.toolTip = "Claude Sidebar"
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Claude Sidebar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Hook Installer

class HookInstaller {
    static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

    static let hookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"]

    static func hookScriptPath() -> String {
        return AppConfig.installDir + "/hooks/sidebar-state.sh"
    }

    static func checkHooksInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        let scriptPath = hookScriptPath()
        for event in hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let found = entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String) == scriptPath
                }
            }
            if !found { return false }
        }
        return true
    }

    static func generateInstallPrompt() -> String {
        let scriptPath = hookScriptPath()

        var prompt = "Add the following hooks to my ~/.claude/settings.json (merge into existing hooks, preserve all existing settings and hooks, do not remove anything):\n\n"
        for event in hookEvents {
            prompt += "Event: \(event)\n"
            if event == "Notification" {
                prompt += "  matcher: \"permission_prompt|elicitation_dialog|idle_prompt\"\n"
            }
            prompt += "  command: \"\(scriptPath)\"\n"
            prompt += "  async: true, timeout: 5\n\n"
        }
        prompt += "If any of these hook entries already exist, skip them."
        return prompt
    }

    static func missingEvents() -> [String] {
        var existingHooks: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = json["hooks"] as? [String: Any] {
            existingHooks = hooks
        }

        let scriptPath = hookScriptPath()
        var missing: [String] = []
        for event in hookEvents {
            let entries = existingHooks[event] as? [[String: Any]] ?? []
            let found = entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in (h["command"] as? String) == scriptPath }
            }
            if !found { missing.append(event) }
        }
        return missing
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private var window: NSWindow?
    private var repoList: [(num: Int, path: String)] = []
    private var pollIntervalStepper: NSStepper!
    private var pollIntervalLabel: NSTextField!
    private var staleTimeoutStepper: NSStepper!
    private var staleTimeoutLabel: NSTextField!
    private var branchCacheStepper: NSStepper!
    private var branchCacheLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var tableView: NSTableView!
    private var hookStatusLabel: NSTextField!
    private var installHooksButton: NSButton!

    var onSave: ((AppConfig) -> Void)?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Load current config into editable list
        repoList = appConfig.repos.map { (num: $0.num, path: $0.path) }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Claude Sidebar Settings"
        win.center()
        win.isReleasedWhenClosed = false

        let contentView = NSView(frame: win.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        win.contentView = contentView

        var yOffset: CGFloat = 520

        // === Section A: Repositories ===
        yOffset -= 30
        let repoHeader = makeLabel("Repositories", bold: true)
        repoHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(repoHeader)

        yOffset -= 160
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: yOffset, width: 440, height: 150))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        let numCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("num"))
        numCol.title = "#"
        numCol.width = 30
        numCol.isEditable = false
        tableView.addTableColumn(numCol)

        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathCol.title = "Path"
        pathCol.width = 340
        pathCol.isEditable = false
        tableView.addTableColumn(pathCol)

        let removeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        removeCol.title = ""
        removeCol.width = 40
        removeCol.isEditable = false
        tableView.addTableColumn(removeCol)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        yOffset -= 32
        let addButton = NSButton(title: "Add Repository...", target: self, action: #selector(addRepo))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 20, y: yOffset, width: 150, height: 24)
        contentView.addSubview(addButton)

        // === Section B: Settings ===
        yOffset -= 40
        let settingsHeader = makeLabel("Settings", bold: true)
        settingsHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(settingsHeader)

        // Poll interval
        yOffset -= 28
        let pollLabel = makeLabel("Poll interval (seconds):")
        pollLabel.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(pollLabel)

        pollIntervalStepper = NSStepper()
        pollIntervalStepper.minValue = 1
        pollIntervalStepper.maxValue = 10
        pollIntervalStepper.increment = 1
        pollIntervalStepper.doubleValue = appConfig.pollInterval ?? 3.0
        pollIntervalStepper.target = self
        pollIntervalStepper.action = #selector(stepperChanged)
        pollIntervalStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(pollIntervalStepper)

        pollIntervalLabel = makeLabel("\(Int(pollIntervalStepper.doubleValue))")
        pollIntervalLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        pollIntervalLabel.alignment = .right
        contentView.addSubview(pollIntervalLabel)

        // Stale timeout
        yOffset -= 28
        let staleLabel = makeLabel("Stale timeout (minutes):")
        staleLabel.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(staleLabel)

        staleTimeoutStepper = NSStepper()
        staleTimeoutStepper.minValue = 5
        staleTimeoutStepper.maxValue = 60
        staleTimeoutStepper.increment = 5
        staleTimeoutStepper.doubleValue = (appConfig.staleTimeout ?? 1800) / 60.0
        staleTimeoutStepper.target = self
        staleTimeoutStepper.action = #selector(stepperChanged)
        staleTimeoutStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(staleTimeoutStepper)

        staleTimeoutLabel = makeLabel("\(Int(staleTimeoutStepper.doubleValue))")
        staleTimeoutLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        staleTimeoutLabel.alignment = .right
        contentView.addSubview(staleTimeoutLabel)

        // Branch cache TTL
        yOffset -= 28
        let cacheLabel = makeLabel("Branch cache TTL (seconds):")
        cacheLabel.frame = NSRect(x: 20, y: yOffset, width: 220, height: 20)
        contentView.addSubview(cacheLabel)

        branchCacheStepper = NSStepper()
        branchCacheStepper.minValue = 5
        branchCacheStepper.maxValue = 30
        branchCacheStepper.increment = 5
        branchCacheStepper.doubleValue = appConfig.branchCacheTTL ?? 10.0
        branchCacheStepper.target = self
        branchCacheStepper.action = #selector(stepperChanged)
        branchCacheStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(branchCacheStepper)

        branchCacheLabel = makeLabel("\(Int(branchCacheStepper.doubleValue))")
        branchCacheLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        branchCacheLabel.alignment = .right
        contentView.addSubview(branchCacheLabel)

        // Launch at login
        yOffset -= 30
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        launchAtLoginCheckbox.state = (appConfig.launchAtLogin ?? false) ? .on : .off
        launchAtLoginCheckbox.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(launchAtLoginCheckbox)

        // === Section C: Claude Hooks ===
        yOffset -= 40
        let hookHeader = makeLabel("Claude Hooks", bold: true)
        hookHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(hookHeader)

        yOffset -= 28
        hookStatusLabel = makeLabel("")
        hookStatusLabel.frame = NSRect(x: 20, y: yOffset, width: 300, height: 20)
        contentView.addSubview(hookStatusLabel)

        installHooksButton = NSButton(title: "Install Hooks", target: self, action: #selector(installHooksTapped))
        installHooksButton.bezelStyle = .rounded
        installHooksButton.frame = NSRect(x: 340, y: yOffset - 2, width: 120, height: 24)
        contentView.addSubview(installHooksButton)

        updateHookStatus()

        // === Bottom bar ===
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 380, y: 12, width: 80, height: 28)
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 290, y: 12, width: 80, height: 28)
        contentView.addSubview(cancelButton)

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func updateHookStatus() {
        if HookInstaller.checkHooksInstalled() {
            hookStatusLabel.stringValue = "\u{2705} Hooks installed"
        } else {
            hookStatusLabel.stringValue = "\u{26A0}\u{FE0F} Hooks not configured"
        }
        installHooksButton.title = "Copy Install Prompt"
        installHooksButton.isEnabled = true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return repoList.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < repoList.count else { return nil }
        let repo = repoList[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        if id == "num" {
            let cell = NSTextField(labelWithString: "\(repo.num)")
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .center
            return cell
        } else if id == "path" {
            let cell = NSTextField(labelWithString: repo.path)
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingMiddle
            return cell
        } else if id == "remove" {
            let btn = NSButton(title: "\u{2715}", target: self, action: #selector(removeRepo(_:)))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 12)
            btn.tag = row
            return btn
        }
        return nil
    }

    // MARK: - Actions

    @objc private func addRepo() {
        if repoList.count >= 8 {
            let alert = NSAlert()
            alert.messageText = "Maximum 8 repositories"
            alert.informativeText = "You can have at most 8 repositories configured."
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Select a repository directory (must contain 'sdmain' in name)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let folderName = url.lastPathComponent
        guard folderName.contains("sdmain") else {
            let alert = NSAlert()
            alert.messageText = "Invalid Repository"
            alert.informativeText = "The selected directory must contain 'sdmain' in its name."
            alert.runModal()
            return
        }

        // Auto-assign next available number
        let usedNums = Set(repoList.map { $0.num })
        var nextNum = 1
        while usedNums.contains(nextNum) { nextNum += 1 }

        // Use ~ shorthand if under home directory
        let home = NSHomeDirectory()
        let displayPath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path

        repoList.append((num: nextNum, path: displayPath))
        repoList.sort { $0.num < $1.num }
        tableView.reloadData()
    }

    @objc private func removeRepo(_ sender: NSButton) {
        let row = sender.tag
        guard row < repoList.count else { return }
        if repoList.count <= 1 {
            let alert = NSAlert()
            alert.messageText = "Cannot Remove"
            alert.informativeText = "At least one repository is required."
            alert.runModal()
            return
        }
        repoList.remove(at: row)
        tableView.reloadData()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if sender === pollIntervalStepper {
            pollIntervalLabel.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === staleTimeoutStepper {
            staleTimeoutLabel.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === branchCacheStepper {
            branchCacheLabel.stringValue = "\(Int(sender.doubleValue))"
        }
    }

    @objc private func installHooksTapped() {
        let prompt = HookInstaller.generateInstallPrompt()

        let missing = HookInstaller.missingEvents()
        let statusText = missing.isEmpty
            ? "All hooks are already installed."
            : "Missing hooks for: \(missing.joined(separator: ", "))"

        let alert = NSAlert()
        alert.messageText = "Copy Hook Install Prompt"
        alert.informativeText = "\(statusText)\n\nClick \"Copy to Clipboard\" to get a prompt you can paste into any Claude Code session. Claude will safely merge the hooks into your existing ~/.claude/settings.json."
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            hookStatusLabel.stringValue = "\u{1F4CB} Prompt copied \u{2014} paste into Claude Code"
        }
    }

    @objc private func saveSettings() {
        let newConfig = AppConfig(
            repos: repoList.map { RepoConfig(num: $0.num, path: $0.path) },
            pollInterval: pollIntervalStepper.doubleValue,
            branchCacheTTL: branchCacheStepper.doubleValue,
            staleTimeout: staleTimeoutStepper.doubleValue * 60,
            launchAtLogin: launchAtLoginCheckbox.state == .on
        )
        newConfig.save()
        onSave?(newConfig)
        window?.close()
    }

    @objc private func cancelSettings() {
        window?.close()
    }
}

// MARK: - Sidebar Controller

class SidebarController {
    private let window: NSPanel
    private let contentView: NSView
    private let mainBar: NSStackView
    private let subPanel: SubPanel
    private let scanner = ITermScanner()
    private var repoButtons: [Int: RepoButton] = [:]
    private var selectedRepo: Int? = nil
    private var pollTimer: Timer?
    private var windowWatchTimer: Timer?
    private var darwinObserverRegistered = false
    private var lastITermWindowCount = -1
    private var repos: [Int: RepoInfo] = [:]
    private var mouseMonitor: Any?

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 210),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        contentView = NSView()
        contentView.wantsLayer = true
        window.contentView = contentView

        subPanel = SubPanel(scanner: scanner)
        subPanel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subPanel)

        let barBg = NSView()
        barBg.wantsLayer = true
        barBg.layer?.cornerRadius = 12
        barBg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        barBg.layer?.backgroundColor = Theme.bg.cgColor
        barBg.layer?.borderColor = Theme.border.cgColor
        barBg.layer?.borderWidth = 1
        barBg.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(barBg)

        mainBar = NSStackView()
        mainBar.orientation = .vertical
        mainBar.spacing = 2
        mainBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainBar)

        for repo in appConfig.repos {
            let btn = RepoButton(num: repo.num)
            btn.onClick = { [weak self] num in self?.toggleRepo(num) }
            repoButtons[repo.num] = btn
            mainBar.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            barBg.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            barBg.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            barBg.widthAnchor.constraint(equalToConstant: 52),
            barBg.topAnchor.constraint(equalTo: mainBar.topAnchor, constant: -6),
            barBg.bottomAnchor.constraint(equalTo: mainBar.bottomAnchor, constant: 6),
            mainBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            mainBar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            subPanel.trailingAnchor.constraint(equalTo: barBg.leadingAnchor, constant: -1),
            subPanel.topAnchor.constraint(equalTo: barBg.topAnchor),
        ])

        positionWindow()
        setupGlobalClickMonitor()
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = NSSize(width: 300, height: 210)
        let x = screenFrame.maxX - windowSize.width
        let y = screenFrame.midY - windowSize.height / 2
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: windowSize), display: true)
    }

    private func setupGlobalClickMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self, self.selectedRepo != nil else { return }
            self.closeSubPanel()
        }
    }

    func start() {
        window.orderFront(nil)
        startPollTimer()
        startWindowWatcher()
        startDarwinObserver()
        poll()
    }

    // Slow poll: iTerm session scanning + branch detection
    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: appConfig.pollInterval ?? 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // Lightweight window-count watcher: triggers full poll only when iTerm windows change
    private func startWindowWatcher() {
        windowWatchTimer?.invalidate()
        windowWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkITermWindowCount()
        }
    }

    private func checkITermWindowCount() {
        let count = itermWindowCount()
        if count != lastITermWindowCount {
            lastITermWindowCount = count
            poll()
        }
    }

    private func itermWindowCount() -> Int {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return windowList.filter { ($0[kCGWindowOwnerName as String] as? String) == "iTerm2" }.count
    }

    // Darwin notification observer: instant wake-up when hook fires
    private func startDarwinObserver() {
        guard !darwinObserverRegistered else { return }
        darwinObserverRegistered = true

        // Claude hook events — full poll to catch new/closed terminals alongside state changes
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let sidebar = Unmanaged<SidebarController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { sidebar.poll() }
            },
            "com.claudesidebar.update" as CFString,
            nil,
            .deliverImmediately
        )

        // iTerm activation/deactivation — catch tab opens/closes when user switches to iTerm
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.googlecode.iterm2" else { return }
            self?.poll()
        }
        ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.googlecode.iterm2" else { return }
            // Slight delay — iTerm needs a moment to finalize tab close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.poll() }
        }
    }

    func reload() {
        for btn in repoButtons.values {
            btn.removeFromSuperview()
        }
        repoButtons.removeAll()
        selectedRepo = nil
        subPanel.hide()

        for repo in appConfig.repos {
            let btn = RepoButton(num: repo.num)
            btn.onClick = { [weak self] num in self?.toggleRepo(num) }
            repoButtons[repo.num] = btn
            mainBar.addArrangedSubview(btn)
        }

        startPollTimer()
        startWindowWatcher()
        startDarwinObserver()
        poll()
    }

    // Fast path: re-read hook state files, update button colors + session-level states
    private func updateStates() {
        let hookStates = scanner.readHookStates()
        for (num, btn) in repoButtons {
            // Button state: hook state takes priority, then iTerm Claude detection, then inactive
            if let hs = hookStates.byRepo[num] {
                switch hs {
                case "alert": btn.state = .alert
                case "working": btn.state = .working
                default: btn.state = .idle
                }
            } else if let info = repos[num], info.sessions.contains(where: { $0.hasClaude }) {
                btn.state = .idle
            } else {
                btn.state = .inactive
            }

            // Update per-session states in cached repos so sub-panel dots reflect changes
            if var info = repos[num] {
                for i in 0..<info.sessions.count {
                    if info.sessions[i].hasClaude {
                        // Claude detected in iTerm name — apply per-TTY or per-repo hook state
                        if let ttyState = hookStates.byTTY[info.sessions[i].tty] {
                            info.sessions[i].state = stateFromString(ttyState)
                        } else if let repoState = hookStates.byRepo[num] {
                            info.sessions[i].state = stateFromString(repoState)
                        } else {
                            info.sessions[i].state = .idle
                        }
                    } else {
                        info.sessions[i].state = .inactive
                    }
                }
                repos[num] = info
            }
        }
        if let sel = selectedRepo, let info = repos[sel] {
            subPanel.show(repoNum: sel, info: info)
        }
    }

    private func stateFromString(_ s: String) -> RepoState {
        switch s {
        case "alert": return .alert
        case "working": return .working
        default: return .idle
        }
    }

    // Full poll: iTerm sessions + branches, then apply hook states
    private func poll() {
        repos = scanner.scan()
        updateStates()
    }

    private func toggleRepo(_ num: Int) {
        if selectedRepo == num {
            closeSubPanel()
        } else {
            if let prev = selectedRepo {
                repoButtons[prev]?.isSelected = false
            }
            selectedRepo = num
            repoButtons[num]?.isSelected = true
            if let info = repos[num] {
                subPanel.show(repoNum: num, info: info)
            }
        }
    }

    private func closeSubPanel() {
        if let prev = selectedRepo {
            repoButtons[prev]?.isSelected = false
        }
        subPanel.hide()
        selectedRepo = nil
    }

}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var sidebar: SidebarController?
    let statusBar = StatusBarManager()
    let settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: "/tmp/claude-sidebar", withIntermediateDirectories: true)

        // Setup status bar icon
        statusBar.onOpenSettings = { [weak self] in
            self?.settingsController.showWindow()
        }
        statusBar.setup()

        // Setup settings save callback
        settingsController.onSave = { [weak self] newConfig in
            appConfig = newConfig
            self?.sidebar?.reload()
        }

        sidebar = SidebarController()
        sidebar?.start()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
