import AppKit
import Foundation

// MARK: - Flipped View (content starts from top)

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sidebar Controller (Window-Centric)

class SidebarController {
    private let window: NSPanel
    private let contentView: FlippedView
    private let scrollView: NSScrollView
    private let docView: FlippedView
    private let windowStack: NSStackView
    private let scanner = ITermScanner()
    private let processMonitor = ProcessMonitor()

    private var windowButtons: [Int: WindowButton] = [:]
    private var windows: [ITermWindowInfo] = []
    private var expandedWindows: Set<Int> = []

    // Timers
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var darwinObserverRegistered = false
    private var lastITermWindowCount = -1
    private var windowWatchTimer: Timer?

    // Width state
    private let collapsedWidth: CGFloat = 62
    private let expandedWidth: CGFloat = 300
    private var isSidebarExpanded = false
    private var isAnimating = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    // Header/Footer views
    private let headerView = FlippedView()
    private let footerView = FlippedView()
    private let logoView = NSView()
    private let titleLabel = NSTextField(labelWithString: "iTerm Sidebar")
    // section label removed per user request

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 62, height: 500),
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

        // Main content view — flipped so y=0 is at top
        contentView = FlippedView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.backgroundColor = Theme.bg.cgColor
        contentView.layer?.borderColor = Theme.border.cgColor
        contentView.layer?.borderWidth = 1
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // --- Scroll view (frame-based, resized manually) ---
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        contentView.addSubview(scrollView)

        docView = FlippedView()
        scrollView.documentView = docView

        windowStack = NSStackView()
        windowStack.orientation = .vertical
        windowStack.spacing = 4
        windowStack.alignment = .leading
        windowStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(windowStack)

        NSLayoutConstraint.activate([
            windowStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 4),
            windowStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 4),
            windowStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -4),
            windowStack.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -4),
        ])

        // --- Header ---
        setupHeader()
        contentView.addSubview(headerView)

        // (section label removed)

        // --- Footer ---
        setupFooter()
        contentView.addSubview(footerView)

        positionWindow()
        layoutSubviews()
        setupHoverTracking()
    }

    // MARK: - Layout (frame-based, called on resize)

    private func layoutSubviews() {
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        let headerH: CGFloat = 44
        let footerH: CGFloat = isSidebarExpanded ? 44 : 0

        headerView.frame = NSRect(x: 0, y: 0, width: w, height: headerH)

        // Center logo in collapsed, left-align in expanded
        if isSidebarExpanded {
            logoView.frame = NSRect(x: 17, y: 8, width: 28, height: 28)
        } else {
            logoView.frame = NSRect(x: (w - 28) / 2, y: 8, width: 28, height: 28)
        }

        let scrollTop = headerH + 4
        let scrollH = h - scrollTop - footerH
        scrollView.frame = NSRect(x: 0, y: scrollTop, width: w, height: max(scrollH, 0))

        footerView.frame = NSRect(x: 0, y: h - footerH, width: w, height: footerH)
        footerView.isHidden = !isSidebarExpanded

        // Document view width must match scroll view clip bounds
        let clipW = scrollView.contentView.bounds.width
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(docView.frame.height, scrollH))

        // After stack layout, resize docView to fit content
        windowStack.layoutSubtreeIfNeeded()
        let contentHeight = windowStack.fittingSize.height + 8
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(contentHeight, scrollH))
    }

    // MARK: - Header

    private func setupHeader() {
        headerView.wantsLayer = true

        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 6
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(red: 99/255, green: 102/255, blue: 241/255, alpha: 1).cgColor,
            NSColor(red: 139/255, green: 92/255, blue: 246/255, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        gradient.cornerRadius = 6
        logoView.layer?.addSublayer(gradient)
        logoView.frame = NSRect(x: 17, y: 8, width: 28, height: 28)
        headerView.addSubview(logoView)

        let logoText = NSTextField(labelWithString: "iT")
        logoText.font = .systemFont(ofSize: 13, weight: .semibold)
        logoText.textColor = .white
        logoText.alignment = .center
        logoText.isBezeled = false
        logoText.drawsBackground = false
        logoText.isEditable = false
        logoText.isSelectable = false
        logoText.frame = NSRect(x: 0, y: 3, width: 28, height: 22)
        logoView.addSubview(logoText)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.8)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.alphaValue = 0
        titleLabel.frame = NSRect(x: 55, y: 12, width: 200, height: 20)
        headerView.addSubview(titleLabel)

        let headerBorder = NSView()
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = Theme.border.cgColor
        headerBorder.frame = NSRect(x: 0, y: 43, width: 300, height: 1)
        headerBorder.autoresizingMask = [.width]
        headerView.addSubview(headerBorder)
    }

    // MARK: - Footer

    private func setupFooter() {
        footerView.wantsLayer = true
        footerView.isHidden = true

        let footerBorder = NSView()
        footerBorder.wantsLayer = true
        footerBorder.layer?.backgroundColor = Theme.border.cgColor
        footerBorder.frame = NSRect(x: 0, y: 0, width: 300, height: 1)
        footerBorder.autoresizingMask = [.width]
        footerView.addSubview(footerBorder)

        let newWindowBtn = makeFooterButton(title: "+ New Window")
        newWindowBtn.frame = NSRect(x: 8, y: 6, width: 130, height: 32)
        newWindowBtn.target = self
        newWindowBtn.action = #selector(newWindowTapped)
        footerView.addSubview(newWindowBtn)

        let settingsBtn = makeFooterButton(title: "\u{2699} Settings")
        settingsBtn.frame = NSRect(x: 146, y: 6, width: 130, height: 32)
        footerView.addSubview(settingsBtn)
    }

    private func makeFooterButton(title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.layer?.borderColor = Theme.border.cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        btn.font = .systemFont(ofSize: 11)
        btn.contentTintColor = NSColor(white: 1.0, alpha: 0.4)
        return btn
    }

    @objc private func newWindowTapped() {
        scanner.createWindow()
    }

    // MARK: - Position

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let h = sf.height * 0.7
        let x = sf.maxX - collapsedWidth
        let y = sf.midY - h / 2
        window.setFrame(NSRect(x: x, y: y, width: collapsedWidth, height: h), display: true)
    }

    // MARK: - Hover Expand/Collapse

    private func setupHoverTracking() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.checkMousePosition()
            return event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkMousePosition()
        }
    }

    private func checkMousePosition() {
        guard !isAnimating else { return }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame

        // Expand hit zone a few pixels beyond the window edges for easier targeting
        let hitZone = NSRect(x: frame.origin.x - 4, y: frame.origin.y - 4,
                             width: frame.width + 8, height: frame.height + 8)

        if hitZone.contains(mouse) && !isSidebarExpanded {
            expandSidebar()
        } else if !hitZone.contains(mouse) && isSidebarExpanded {
            collapseSidebar()
        }
    }

    private func expandSidebar() {
        guard !isSidebarExpanded, !isAnimating else { return }
        isSidebarExpanded = true
        isAnimating = true

        let frame = window.frame
        let rightEdge = frame.maxX
        let newFrame = NSRect(
            x: rightEdge - expandedWidth,
            y: frame.origin.y,
            width: expandedWidth,
            height: frame.height
        )

        // Switch buttons to expanded BEFORE animation so layout is ready
        for (_, btn) in windowButtons {
            btn.isExpanded = true
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 1
            // sectionLabel removed
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false
            self.footerView.isHidden = false
            self.layoutSubviews()
        })
    }

    private func collapseSidebar() {
        guard isSidebarExpanded, !isAnimating else { return }
        isSidebarExpanded = false
        isAnimating = true

        let frame = window.frame
        let rightEdge = frame.maxX
        let newFrame = NSRect(
            x: rightEdge - collapsedWidth,
            y: frame.origin.y,
            width: collapsedWidth,
            height: frame.height
        )

        footerView.isHidden = true

        // Switch buttons to collapsed BEFORE animation
        for (_, btn) in windowButtons {
            btn.isExpanded = false
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 0
            // sectionLabel removed
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false
            self.layoutSubviews()
        })
    }

    // MARK: - Start / Reload

    func start() {
        window.orderFront(nil)
        startTimers()
        startDarwinObserver()
        fullPoll()
        fastPoll()  // detect processes immediately, don't wait 5s
    }

    func reload() {
        windowButtons.values.forEach { $0.removeFromSuperview() }
        windowButtons.removeAll()
        expandedWindows.removeAll()
        startTimers()
        startDarwinObserver()
        fullPoll()
    }

    // MARK: - Three-Tier Polling

    private func startTimers() {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        windowWatchTimer?.invalidate()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fastPoll()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: appConfig.pollInterval ?? 30.0, repeats: true) { [weak self] _ in
            self?.fullPoll()
        }
        windowWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkITermWindowCount()
        }
    }

    private func checkITermWindowCount() {
        let count = itermWindowCount()
        if count != lastITermWindowCount {
            lastITermWindowCount = count
            fullPoll()
        }
    }

    private func itermWindowCount() -> Int {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return windowList.filter { ($0[kCGWindowOwnerName as String] as? String) == "iTerm2" }.count
    }

    private func startDarwinObserver() {
        guard !darwinObserverRegistered else { return }
        darwinObserverRegistered = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let sidebar = Unmanaged<SidebarController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { sidebar.instantUpdate() }
            },
            "com.claudesidebar.update" as CFString,
            nil,
            .deliverImmediately
        )

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.googlecode.iterm2" else { return }
            self?.fullPoll()
        }
        ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.googlecode.iterm2" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.fullPoll() }
        }
    }

    // MARK: - Poll Methods

    private func instantUpdate() {
        let hookStates = scanner.readHookStates()
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                let tty = windows[wi].tabs[ti].tty
                let hasClaude = windows[wi].tabs[ti].hasClaude || hookStates.byTTY[tty] != nil
                windows[wi].tabs[ti].hasClaude = hasClaude
                if hasClaude {
                    if let ttyState = hookStates.byTTY[tty] {
                        windows[wi].tabs[ti].claudeState = SessionState.fromString(ttyState)
                    } else {
                        windows[wi].tabs[ti].claudeState = .idle
                    }
                }
            }
        }
        updateUI()
    }

    private func fastPoll() {
        let ttys = windows.flatMap { $0.tabs.map { $0.tty } }
        guard !ttys.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let scanResult = self.processMonitor.discoverProcesses(ttys: ttys)

            // Batch CWD detection from shell PIDs
            let cwds = self.processMonitor.detectCWDs(shellPIDs: scanResult.shellPIDs)

            // Batch branch detection from CWDs
            var branches: [String: String] = [:]
            for (tty, cwd) in cwds {
                if let branch = self.scanner.getBranchCached(cwd: cwd) {
                    branches[tty] = branch
                }
            }

            DispatchQueue.main.async {
                for wi in 0..<self.windows.count {
                    for ti in 0..<self.windows[wi].tabs.count {
                        let tty = self.windows[wi].tabs[ti].tty

                        // Update Claude detection from process scan
                        if scanResult.claudeTTYs.contains(tty) {
                            self.windows[wi].tabs[ti].hasClaude = true
                            if self.windows[wi].tabs[ti].claudeState == .inactive {
                                self.windows[wi].tabs[ti].claudeState = .idle
                            }
                        }

                        // Update CWD from shell process
                        if let cwd = cwds[tty] {
                            self.windows[wi].tabs[ti].cwd = cwd
                        }

                        // Update branch
                        if let branch = branches[tty] {
                            self.windows[wi].tabs[ti].gitBranch = branch
                        }

                        // Update non-Claude process info
                        if let proc = scanResult.processes[tty] {
                            if self.windows[wi].tabs[ti].processInfo == nil ||
                               self.windows[wi].tabs[ti].processInfo?.pid != proc.pid {
                                self.windows[wi].tabs[ti].processInfo = proc
                                self.processMonitor.watchPID(Int32(proc.pid), tty: tty) { [weak self] exitCode in
                                    self?.handleProcessExit(tty: tty, exitCode: exitCode)
                                }
                            }
                        }
                    }
                }
                self.updateUI()
            }
        }
    }

    private var fullPollInFlight = false
    private func fullPoll() {
        guard !fullPollInFlight else { return }
        fullPollInFlight = true

        let newWindows = scanner.scan()
        fullPollInFlight = false

        if !newWindows.isEmpty {
            var merged = newWindows
            for wi in 0..<merged.count {
                for ti in 0..<merged[wi].tabs.count {
                    let tty = merged[wi].tabs[ti].tty
                    if let oldWindow = windows.first(where: { $0.windowId == merged[wi].windowId }),
                       let oldTab = oldWindow.tabs.first(where: { $0.tty == tty }) {
                        // Preserve fastPoll data when fullPoll scan returns nil/weaker values
                        if merged[wi].tabs[ti].processInfo == nil {
                            merged[wi].tabs[ti].processInfo = oldTab.processInfo
                        }
                        if merged[wi].tabs[ti].cwd == nil, let oldCwd = oldTab.cwd {
                            merged[wi].tabs[ti].cwd = oldCwd
                        }
                        if merged[wi].tabs[ti].gitBranch == nil, let oldBranch = oldTab.gitBranch {
                            merged[wi].tabs[ti].gitBranch = oldBranch
                        }
                        // Preserve Claude detection from ps scan
                        if oldTab.hasClaude && !merged[wi].tabs[ti].hasClaude {
                            merged[wi].tabs[ti].hasClaude = true
                            merged[wi].tabs[ti].claudeState = oldTab.claudeState
                        }
                    }
                }
            }
            windows = merged

            for w in windows where w.hasActiveSession {
                expandedWindows.insert(w.windowId)
            }
        }
        updateUI()
    }

    private func handleProcessExit(tty: String, exitCode: Int32) {
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                if windows[wi].tabs[ti].tty == tty {
                    windows[wi].tabs[ti].processInfo?.exitCode = Int(exitCode)
                }
            }
        }
        updateUI()
    }

    // MARK: - UI Update

    private func updateUI() {
        let currentIds = Set(windows.map { $0.windowId })
        for (id, btn) in windowButtons where !currentIds.contains(id) {
            btn.removeFromSuperview()
            windowButtons.removeValue(forKey: id)
        }

        for win in windows {
            if let btn = windowButtons[win.windowId] {
                btn.update(windowInfo: win)
                btn.isExpanded = isSidebarExpanded
            } else {
                let btn = WindowButton(windowInfo: win)
                btn.isExpanded = isSidebarExpanded
                btn.onToggle = { [weak self] in
                    self?.toggleWindow(win.windowId)
                }
                btn.onNewTab = { [weak self] in
                    self?.scanner.createTab(windowId: win.windowId)
                }
                btn.onFocusTab = { [weak self] tab in
                    self?.scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
                }
                btn.translatesAutoresizingMaskIntoConstraints = false
                windowStack.addArrangedSubview(btn)
                btn.widthAnchor.constraint(equalTo: windowStack.widthAnchor).isActive = true
                windowButtons[win.windowId] = btn
            }
        }

        // Update document view height to fit content
        DispatchQueue.main.async { [weak self] in
            self?.layoutSubviews()
        }
    }

    private func toggleWindow(_ windowId: Int) {
        if expandedWindows.contains(windowId) {
            expandedWindows.remove(windowId)
        } else {
            expandedWindows.insert(windowId)
        }
        updateUI()
    }
}
