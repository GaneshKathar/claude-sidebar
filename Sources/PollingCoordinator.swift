import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "PollingCoordinator")

// MARK: - Polling Delegate

protocol PollingDelegate: AnyObject {
    var windows: [TerminalWindow] { get set }
    var windowButtons: [Int: WindowButton] { get }
    var expandedWindows: Set<Int> { get set }
    func updateUI()
    func collapseSidebar()
}

// MARK: - Polling Coordinator (extracted from SidebarController — SRP)

class PollingCoordinator {
    private let scanner: TerminalScanner
    private let processMonitor: ProcessMonitor
    weak var delegate: PollingDelegate?

    // Timers
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var processTickTimer: Timer?
    private var windowWatchTimer: Timer?
    private var darwinObserverRegistered = false
    private var lastTerminalWindowCount = -1

    // Observer tokens
    private var wsActivateObserver: NSObjectProtocol?
    private var wsDeactivateObserver: NSObjectProtocol?

    // State
    var watchedClaudePIDs: Set<Int32> = []
    var fullPollInFlight = false
    var pendingInstantUpdate = false
    private var currentTickInterval: TimeInterval = 0

    init(scanner: TerminalScanner, processMonitor: ProcessMonitor) {
        self.scanner = scanner
        self.processMonitor = processMonitor
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        windowWatchTimer?.invalidate()
        processTickTimer?.invalidate()

        if darwinObserverRegistered {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName("com.claudesidebar.update" as CFString),
                nil
            )
        }

        let ws = NSWorkspace.shared.notificationCenter
        if let obs = wsActivateObserver { ws.removeObserver(obs) }
        if let obs = wsDeactivateObserver { ws.removeObserver(obs) }
    }

    // MARK: - Timer Management

    func startTimers() {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        windowWatchTimer?.invalidate()

        fastTimer = Timer.scheduledTimer(withTimeInterval: Layout.fastPollInterval, repeats: true) { [weak self] _ in
            self?.fastPoll()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: appConfig.pollInterval ?? 30.0, repeats: true) { [weak self] _ in
            self?.fullPoll()
        }
        windowWatchTimer = Timer.scheduledTimer(withTimeInterval: Layout.windowCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTerminalWindowCounts()
        }
    }

    // MARK: - Window Count Watching

    private func checkTerminalWindowCounts() {
        let count = terminalWindowCount()
        if count != lastTerminalWindowCount {
            lastTerminalWindowCount = count
            fullPoll()
        }
    }

    private func terminalWindowCount() -> Int {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        return windowList.filter { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return TerminalRegistry.shared.isKnownTerminal(owner.lowercased())
        }.count
    }

    // MARK: - Darwin Observer

    func startDarwinObserver() {
        guard !darwinObserverRegistered else { return }
        darwinObserverRegistered = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let coordinator = Unmanaged<PollingCoordinator>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { coordinator.instantUpdate() }
            },
            "com.claudesidebar.update" as CFString,
            nil,
            .deliverImmediately
        )

        let ws = NSWorkspace.shared.notificationCenter

        if let obs = wsActivateObserver { ws.removeObserver(obs) }
        if let obs = wsDeactivateObserver { ws.removeObserver(obs) }

        wsActivateObserver = ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  TerminalRegistry.shared.isKnownTerminal((app.localizedName ?? "").lowercased()) else { return }
            self?.fullPoll()
        }
        wsDeactivateObserver = ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  TerminalRegistry.shared.isKnownTerminal((app.localizedName ?? "").lowercased()) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.fullPoll() }
        }
    }

    // MARK: - Poll Methods

    func instantUpdate() {
        guard let delegate = delegate else { return }
        if fullPollInFlight {
            pendingInstantUpdate = true
            return
        }
        let hookStates = scanner.readHookStates()
        for wi in 0..<delegate.windows.count {
            for ti in 0..<delegate.windows[wi].tabs.count {
                let tty = delegate.windows[wi].tabs[ti].tty
                let hasClaude = delegate.windows[wi].tabs[ti].hasClaude || hookStates.byTTY[tty] != nil
                delegate.windows[wi].tabs[ti].hasClaude = hasClaude
                if hasClaude {
                    if let ttyState = hookStates.byTTY[tty] {
                        delegate.windows[wi].tabs[ti].claudeState = SessionState.fromString(ttyState)
                    } else {
                        delegate.windows[wi].tabs[ti].claudeState = .idle
                    }
                }
            }
        }
        delegate.updateUI()
    }

    func fastPoll() {
        guard let delegate = delegate else { return }
        let ttys = delegate.windows.flatMap { $0.tabs.map { $0.tty } }
        guard !ttys.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let scanResult = self.processMonitor.discoverProcesses(ttys: ttys)
            let cwds = self.processMonitor.detectCWDs(shellPIDs: scanResult.shellPIDs)

            var branches: [String: String] = [:]
            for (tty, cwd) in cwds {
                if let branch = self.scanner.getBranch(cwd: cwd) {
                    branches[tty] = branch
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let delegate = self.delegate else { return }
                for wi in 0..<delegate.windows.count {
                    for ti in 0..<delegate.windows[wi].tabs.count {
                        let tty = delegate.windows[wi].tabs[ti].tty

                        if scanResult.claudeTTYs.contains(tty) {
                            delegate.windows[wi].tabs[ti].hasClaude = true
                            if delegate.windows[wi].tabs[ti].claudeState == .inactive {
                                delegate.windows[wi].tabs[ti].claudeState = .idle
                            }
                            if let claudePID = scanResult.claudePIDs[tty],
                               !self.watchedClaudePIDs.contains(claudePID) {
                                self.watchedClaudePIDs.insert(claudePID)
                                self.processMonitor.watchPID(claudePID, tty: tty) { [weak self] _ in
                                    self?.handleClaudeExit(tty: tty, pid: claudePID)
                                }
                            }
                        } else if delegate.windows[wi].tabs[ti].hasClaude {
                            delegate.windows[wi].tabs[ti].hasClaude = false
                            delegate.windows[wi].tabs[ti].claudeState = .inactive
                        }

                        if let cwd = cwds[tty] {
                            delegate.windows[wi].tabs[ti].cwd = cwd
                        }

                        if let branch = branches[tty] {
                            delegate.windows[wi].tabs[ti].gitBranch = branch
                        }

                        if let proc = scanResult.processes[tty] {
                            if delegate.windows[wi].tabs[ti].processInfo == nil ||
                               delegate.windows[wi].tabs[ti].processInfo?.pid != proc.pid {
                                delegate.windows[wi].tabs[ti].processInfo = proc
                                self.processMonitor.watchPID(Int32(proc.pid), tty: tty) { [weak self] exitCode in
                                    self?.handleProcessExit(tty: tty, exitCode: exitCode)
                                }
                            }
                        } else if delegate.windows[wi].tabs[ti].processInfo?.pid == -1 {
                            delegate.windows[wi].tabs[ti].processInfo = nil
                        }
                    }
                }
                delegate.updateUI()
            }
        }
    }

    func fullPoll() {
        guard !fullPollInFlight else { return }
        fullPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let newWindows = self.scanner.scan()
            DispatchQueue.main.async { self.applyFullPollResults(newWindows) }
        }
    }

    func applyFullPollResults(_ newWindows: [TerminalWindow]) {
        guard let delegate = delegate else {
            fullPollInFlight = false
            return
        }
        defer {
            fullPollInFlight = false
            if pendingInstantUpdate {
                pendingInstantUpdate = false
                instantUpdate()
            }
        }

        if !newWindows.isEmpty {
            var merged = newWindows
            for wi in 0..<merged.count {
                for ti in 0..<merged[wi].tabs.count {
                    let tty = merged[wi].tabs[ti].tty
                    if let oldWindow = delegate.windows.first(where: { $0.windowId == merged[wi].windowId }),
                       let oldTab = oldWindow.tabs.first(where: { $0.tty == tty }) {
                        if let old = oldTab.processInfo, old.pid > 0, old.exitCode == nil,
                           (merged[wi].tabs[ti].processInfo?.pid ?? -1) <= 0 {
                            merged[wi].tabs[ti].processInfo = old
                        }
                        if merged[wi].tabs[ti].cwd == nil, let oldCwd = oldTab.cwd {
                            merged[wi].tabs[ti].cwd = oldCwd
                        }
                        if merged[wi].tabs[ti].gitBranch == nil, let oldBranch = oldTab.gitBranch {
                            merged[wi].tabs[ti].gitBranch = oldBranch
                        }
                        if oldTab.hasClaude && !merged[wi].tabs[ti].hasClaude {
                            merged[wi].tabs[ti].hasClaude = true
                            merged[wi].tabs[ti].claudeState = oldTab.claudeState
                        }
                    }
                }
            }
            delegate.windows = merged

            for w in delegate.windows where w.hasActiveSession {
                delegate.expandedWindows.insert(w.windowId)
            }
        }
        delegate.updateUI()
    }

    // MARK: - Process Exit Handlers

    func handleClaudeExit(tty: String, pid: Int32) {
        guard let delegate = delegate else { return }
        watchedClaudePIDs.remove(pid)
        for wi in 0..<delegate.windows.count {
            for ti in 0..<delegate.windows[wi].tabs.count {
                if delegate.windows[wi].tabs[ti].tty == tty {
                    delegate.windows[wi].tabs[ti].hasClaude = false
                    delegate.windows[wi].tabs[ti].claudeState = .inactive
                }
            }
        }
        delegate.updateUI()
    }

    func handleProcessExit(tty: String, exitCode: Int32) {
        guard let delegate = delegate else { return }
        for wi in 0..<delegate.windows.count {
            for ti in 0..<delegate.windows[wi].tabs.count {
                if delegate.windows[wi].tabs[ti].tty == tty {
                    delegate.windows[wi].tabs[ti].processInfo?.exitCode = Int(exitCode)
                }
            }
        }
        delegate.updateUI()

        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.processAutoClearDelay) { [weak self] in
            guard let self = self, let delegate = self.delegate else { return }
            for wi in 0..<delegate.windows.count {
                for ti in 0..<delegate.windows[wi].tabs.count {
                    if delegate.windows[wi].tabs[ti].tty == tty,
                       delegate.windows[wi].tabs[ti].processInfo?.exitCode != nil {
                        delegate.windows[wi].tabs[ti].processInfo = nil
                    }
                }
            }
            delegate.updateUI()
        }
    }

    // MARK: - Process Duration Tick Timer

    private func optimalTickInterval() -> TimeInterval {
        guard let delegate = delegate else { return 0 }
        var shortest: TimeInterval = .greatestFiniteMagnitude
        for tab in delegate.windows.flatMap({ $0.tabs }) {
            guard let proc = tab.processInfo, proc.exitCode == nil else { continue }
            shortest = min(shortest, proc.duration)
        }
        guard shortest < .greatestFiniteMagnitude else { return 0 }
        return shortest < 3600 ? 1.0 : 60.0
    }

    func updateProcessTickTimer() {
        let interval = optimalTickInterval()

        if interval == 0 {
            processTickTimer?.invalidate()
            processTickTimer = nil
            currentTickInterval = 0
            return
        }

        if processTickTimer == nil || currentTickInterval != interval {
            processTickTimer?.invalidate()
            currentTickInterval = interval
            processTickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.tickProcessDurations()
            }
        }
    }

    private func tickProcessDurations() {
        guard let delegate = delegate else { return }
        let interval = optimalTickInterval()

        if interval == 0 {
            processTickTimer?.invalidate()
            processTickTimer = nil
            currentTickInterval = 0
            return
        }

        if interval != currentTickInterval {
            updateProcessTickTimer()
        }

        for (_, btn) in delegate.windowButtons {
            if btn.windowInfo.tabs.contains(where: { $0.processInfo != nil && $0.processInfo?.exitCode == nil }) {
                btn.update(windowInfo: btn.windowInfo)
            }
        }
    }
}
